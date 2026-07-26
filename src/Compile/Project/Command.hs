-----------------------------------------------------------------------------
-- `koka init` / `fetch` / `build` / `run` / `test` / `clean`.
--
-- This module owns everything project-shaped: finding the project root,
-- resolving dependencies, turning a manifest into compiler `Flags`, discovering
-- tests, and reporting.  Actually compiling is delegated to a callback so that
-- this module does not depend on the build driver.
-----------------------------------------------------------------------------
module Compile.Project.Command
  ( CompileFn
  , runProjectCommand
  , findProjectRoot
  ) where

import Control.Monad      ( when, unless, forM, forM_, filterM, foldM )
import Data.Char          ( toLower )
import Data.IORef
import Data.List          ( sort, isSuffixOf, isPrefixOf, isInfixOf, intercalate, nub )
import Data.Maybe         ( fromMaybe, catMaybes, isJust )
import System.Directory   ( doesDirectoryExist, doesFileExist, createDirectoryIfMissing
                          , getCurrentDirectory, canonicalizePath, listDirectory )
import System.Exit        ( ExitCode(..) )
import System.FilePath    ( (</>), (<.>), takeDirectory, takeBaseName, takeFileName
                          , takeExtension, isDrive, normalise, splitDirectories )
import System.IO          ( hPutStr, hPutStrLn, stderr, stdout )
import System.IO.Error    ( catchIOError )
import System.Process     ( readProcessWithExitCode )

import Platform.Config    ( version )
import Common.Syntax      ( Target(..) )
import Compile.Options
import Compile.Project.Manifest
import Compile.Project.Lock
import Compile.Project.Fetch
import Compile.Project.Cache
import Compile.Stats      ( statsGetLastExe )
import Compile.Project.Hash

-----------------------------------------------------------------------------
-- Commands
-----------------------------------------------------------------------------

-- | Compile (and possibly run) the given root files with the given flags.
-- Returns False on any error.
type CompileFn = Flags -> [FilePath] -> IO Bool

-----------------------------------------------------------------------------
-- Entry point
-----------------------------------------------------------------------------

runProjectCommand :: ProjectCmd -> Flags -> [String] -> CompileFn -> IO Bool
runProjectCommand cmd flags args compile
  = case cmd of
      ProjInit -> cmdInit flags args
      _        -> do mbRoot <- findProjectRoot
                     case mbRoot of
                       Nothing
                         -> failWith ("no " ++ manifestFileName
                                        ++ " found in this directory or any parent"
                                        ++ "\n(run `koka init` to create a project)")
                       Just dir -> withProject cmd flags args compile dir

failWith :: String -> IO Bool
failWith msg = do hPutStrLn stderr ("koka: " ++ msg)
                  return False

-- | Walk up from the current directory looking for a manifest.
findProjectRoot :: IO (Maybe FilePath)
findProjectRoot
  = do cwd <- getCurrentDirectory
       walk cwd
  where
    walk dir
      = do exist <- doesFileExist (dir </> manifestFileName)
           if exist then return (Just dir)
             else do let up = takeDirectory dir
                     if up == dir || null up then return Nothing else walk up

-----------------------------------------------------------------------------
-- init
-----------------------------------------------------------------------------

cmdInit :: Flags -> [String] -> IO Bool
cmdInit flags args
  = do cwd <- getCurrentDirectory
       let dir  = case args of
                    (a:_) | not ("-" `isPrefixOf` a) -> cwd </> a
                    _ -> cwd
           name = sanitize (takeFileName (normalise (dropTrailingSep dir)))
       exists <- doesFileExist (dir </> manifestFileName)
       if exists
         then failWith (manifestFileName ++ " already exists in " ++ dir)
         else do createDirectoryIfMissing True (dir </> "src")
                 createDirectoryIfMissing True (dir </> "test")
                 writeFile (dir </> manifestFileName) (defaultManifestText name version)
                 writeFile (dir </> "src" </> "main.kk") mainTemplate
                 writeFile (dir </> "test" </> "main-test.kk") testTemplate
                 writeFile (dir </> ".gitignore") gitignoreTemplate
                 putStrLn ("created project '" ++ name ++ "' in " ++ dir)
                 putStrLn "  koka.toml"
                 putStrLn "  src/main.kk"
                 putStrLn "  test/main-test.kk"
                 return True
  where
    dropTrailingSep p = case reverse p of
                          ('/':rest)  -> reverse rest
                          ('\\':rest) -> reverse rest
                          _           -> p
    sanitize s = case filter ok s of
                   [] -> "my-project"
                   n  -> n
    ok c = c `elem` "-_" || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')

mainTemplate :: String
mainTemplate
  = unlines
      [ "fun main()"
      , "  println(\"hello from koka\")"
      ]

testTemplate :: String
testTemplate
  = unlines
      [ "// Every .kk file under the test directories is compiled and run by"
      , "// `koka test`.  A non-zero exit status (or an uncaught exception)"
      , "// fails the test."
      , "fun main()"
      , "  println(\"ok\")"
      ]

gitignoreTemplate :: String
gitignoreTemplate
  = unlines
      [ "# koka project artifacts and fetched dependencies"
      , ".koka/"
      ]

-----------------------------------------------------------------------------
-- Everything that needs a resolved project
-----------------------------------------------------------------------------

withProject :: ProjectCmd -> Flags -> [String] -> CompileFn -> FilePath -> IO Bool
withProject ProjClean flags _ _ dir
  = do removed <- clearProjectArtifacts dir
       if null removed
         then putStrLn "nothing to clean"
         else mapM_ (\d -> putStrLn ("removed " ++ d)) removed
       return True

withProject cmd flags args compile dir
  = do let ropts = ResolveOptions { roLocked   = projectLocked flags
                                  , roOffline  = projectOffline flags
                                  , roVerbose  = verbose flags > 1
                                  , roChecksum = True }
       res <- resolveProject ropts dir version
       case res of
         Left err -> failWith err
         Right resolved ->
           do -- Write the lockfile unless we were told not to.
              when (resChanged resolved && not (projectLocked flags)) $
                do writeLock (dir </> lockFileName) (resLock resolved)
                   when (verbose flags > 0) $
                     putStrLn ("updated " ++ lockFileName)
              case cmd of
                ProjFetch -> do reportFetch flags resolved
                                return True
                _ -> buildish cmd flags args compile dir resolved

reportFetch :: Flags -> Resolved -> IO ()
reportFetch flags resolved
  = do let deps = resDeps resolved
       if null deps
         then putStrLn "no dependencies"
         else forM_ deps $ \d ->
                putStrLn ("  " ++ pad 20 (rdName d) ++ " " ++ depSourceKey (rdSource d))
       when (verbose flags > 0 && not (null deps)) $
         putStrLn (show (length deps) ++ " dependencies ready")
  where
    pad n s = s ++ replicate (n - length s) ' '

-----------------------------------------------------------------------------
-- build / run / test
-----------------------------------------------------------------------------

buildish :: ProjectCmd -> Flags -> [String] -> CompileFn -> FilePath -> Resolved -> IO Bool
buildish cmd flags args compile dir resolved
  = do let man = resRoot resolved
       -- native settings, merged over the whole graph
       nat <- resolveNative flags (mergeNative (manNative man : map (manNative . rdManifest) (resDeps resolved)))
       case nat of
         Left err -> failWith err
         Right native ->
           do srcHash <- hashSourceDirs dir (manSourceDirs man)
              let key = CacheKey
                          { ckKokaVersion = version
                          , ckTarget      = show (target flags)
                          , ckTargetOS    = targetOS flags
                          , ckTargetArch  = targetArch flags
                          , ckProfile     = buildProfile flags
                          , ckFlagsHash   = flagsHash flags
                          , ckLockHash    = hashString (renderLock (resLock resolved))
                          , ckSourceHash  = srcHash
                          , ckNativeHash  = hashStrings (nativeKeyParts native)
                          }
              let cdir = cacheDirFor dir key
              reused <- validateCacheDir cdir key
              when (verbose flags > 1) $
                putStrLn ((if reused then "reusing" else "fresh") ++ " build cache " ++ cdir)

              includes <- projectIncludes dir resolved
              let bflags = applyProject flags dir cdir includes native

              ok <- case cmd of
                      ProjTest -> runTests bflags compile dir man
                      ProjRun  -> runMain bflags{ evaluate = True } compile dir man
                      _        -> runMain bflags{ evaluate = False } compile dir man
              when ok $ writeCacheStamp cdir key
              return ok

-- | Include path: the project's own source directories first, then each
-- dependency's, in dependency order.  Dependencies come last so a project can
-- shadow a module it also gets from a dependency.
projectIncludes :: FilePath -> Resolved -> IO [FilePath]
projectIncludes dir resolved
  = do own <- mapM (canonicalizePath . (dir </>)) (manSourceDirs (resRoot resolved))
       deps <- forM (resDeps resolved) $ \d ->
                 mapM (canonicalizePath . (rdDir d </>)) (manSourceDirs (rdManifest d))
       return (nub (own ++ concat deps))

applyProject :: Flags -> FilePath -> FilePath -> [FilePath] -> ResolvedNative -> Flags
applyProject flags projectDir cacheDir includes native
  = flags { includePath      = includePath flags ++ includes
          , buildDir         = cacheDir
          , outBuildDir      = ""     -- recomputed by the build driver from buildDir
          , ccompIncludeDirs = ccompIncludeDirs flags ++ rnIncludeDirs native
          , ccompCompileArgs = ccompCompileArgs flags ++ rnCFlags native
          , ccompLinkArgs    = ccompLinkArgs flags ++ rnLinkFlags native
          , ccompLinkSysLibs = ccompLinkSysLibs flags ++ rnLibs native
          }

-- | Build (and possibly run) the executable target.
runMain :: Flags -> CompileFn -> FilePath -> Manifest -> IO Bool
runMain flags compile dir man
  = case tgtMain (manTargets man) of
      Nothing
        -> failWith ("no executable target: add\n\n  [targets.app]\n  main = \"src/main.kk\"\n\nto "
                       ++ manifestFileName)
      Just m
        -> do let path = dir </> m
              exist <- doesFileExist path
              if not exist
                then failWith ("executable target " ++ m ++ " does not exist (" ++ path ++ ")")
                else compile flags [path]

-- | Discover and run tests.  Every `.kk` file under the configured test
-- directories is a test program: it is compiled and executed, and a non-zero
-- exit status fails it.  Files whose name starts with `_` are support modules
-- and are skipped.
runTests :: Flags -> CompileFn -> FilePath -> Manifest -> IO Bool
runTests flags compile dir man
  = do testDirs <- filterM doesDirectoryExist (map (dir </>) (tgtTestDirs (manTargets man)))
       files    <- fmap (sort . concat) (mapM findTests testDirs)
       if null files
         then do putStrLn "no tests found"
                 return True
         else do putStrLn ("running " ++ show (length files) ++ " test "
                            ++ (if length files == 1 then "program" else "programs"))
                 results <- forM files $ \f ->
                              do putStrLn ("test: " ++ relativeTo dir f)
                                 ok <- runOneTest flags compile f
                                 unless ok $
                                   hPutStrLn stderr ("FAILED: " ++ relativeTo dir f)
                                 return (f, ok)
                 let failed = [ f | (f,False) <- results ]
                 putStrLn ""
                 putStrLn (show (length results - length failed) ++ " passed, "
                             ++ show (length failed) ++ " failed")
                 forM_ failed $ \f -> putStrLn ("  failed: " ++ relativeTo dir f)
                 return (null failed)
  where
    findTests d
      = do entries <- listDirectory d
           fmap concat $ forM (sort entries) $ \e ->
             do let p = d </> e
                isDir <- doesDirectoryExist p
                if isDir
                  then if isIgnoredEntry e then return [] else findTests p
                  else return [ p | takeExtension e == ".kk", not ("_" `isPrefixOf` e) ]

-- | Build one test program and run it ourselves.
--
-- We do not use the compiler's own `--execute`, because a test runner has to
-- see how the program ended and `--execute` does not surface that.  Two things
-- count as a failure:
--
--   * a non-zero exit status (what the test framework uses to report
--     assertion failures);
--   * the runtime's `uncaught exception:` marker, because Koka's default
--     exception handler prints it and then exits *successfully* -- a crashed
--     test must never be reported as passing.
runOneTest :: Flags -> CompileFn -> FilePath -> IO Bool
runOneTest flags compile f
  = do built <- compile flags{ evaluate = False } [f]
       if not built
         then return False
         else do exe <- statsGetLastExe
                 if null exe
                   then do hPutStrLn stderr ("no executable was produced for " ++ f
                                               ++ " (does it define `main`?)")
                           return False
                   else do (code,out,err) <- readProcessWithExitCode exe [] ""
                           putStr out
                           hPutStr stderr err
                           let crashed = "uncaught exception:" `isInfixOf` (out ++ err)
                           when crashed $
                             hPutStrLn stderr "test ended with an uncaught exception"
                           return (code == ExitSuccess && not crashed)

relativeTo :: FilePath -> FilePath -> FilePath
relativeTo base p
  | (base ++ "/") `isPrefixOf` p = drop (length base + 1) p
  | otherwise                    = p

-----------------------------------------------------------------------------
-- Source hashing
-----------------------------------------------------------------------------

hashSourceDirs :: FilePath -> [FilePath] -> IO String
hashSourceDirs dir dirs
  = do present <- filterM doesDirectoryExist (map (dir </>) dirs)
       hs <- mapM hashTree present
       return (hashStrings hs)

-----------------------------------------------------------------------------
-- Native dependencies
-----------------------------------------------------------------------------

data ResolvedNative
  = ResolvedNative
      { rnCFlags     :: [String]
      , rnLinkFlags  :: [String]
      , rnIncludeDirs:: [FilePath]
      , rnLibs       :: [String]
      , rnSource     :: [String]   -- ^ what was asked for, for the cache key
      }

nativeKeyParts :: ResolvedNative -> [String]
nativeKeyParts n = rnSource n ++ rnCFlags n ++ rnLinkFlags n ++ rnIncludeDirs n ++ rnLibs n

mergeNative :: [NativeDeps] -> NativeDeps
mergeNative ns
  = NativeDeps { natPkgConfig = nub (concatMap natPkgConfig ns)
               , natLibs      = nub (concatMap natLibs ns)
               , natIncludes  = nub (concatMap natIncludes ns)
               }

-- | Ask pkg-config for the flags of each declared module.  A missing module is
-- a hard error with the module name, rather than a confusing link failure
-- later.
resolveNative :: Flags -> NativeDeps -> IO (Either String ResolvedNative)
resolveNative flags nd
  | null (natPkgConfig nd)
  = return (Right (ResolvedNative [] [] (natIncludes nd) (natLibs nd) (describe nd)))
  | otherwise
  = do (code,out,err) <- readProcessWithExitCode "pkg-config"
                            ("--cflags" : "--libs" : natPkgConfig nd) ""
                          `catchProc` (ExitFailure 127, "", "pkg-config not found")
       case code of
         ExitSuccess
           -> do let ws = words out
                     incs = [ drop 2 w | w <- ws, "-I" `isPrefixOf` w ]
                     cfl  = [ w | w <- ws, not ("-I" `isPrefixOf` w), not ("-l" `isPrefixOf` w)
                                , not ("-L" `isPrefixOf` w) ]
                     libs = [ drop 2 w | w <- ws, "-l" `isPrefixOf` w ]
                     lfl  = [ w | w <- ws, "-L" `isPrefixOf` w ]
                 return (Right (ResolvedNative cfl lfl (natIncludes nd ++ incs)
                                               (nub (natLibs nd ++ libs)) (describe nd)))
         _ -> return (Left ("pkg-config failed for [native] pkg-config = "
                              ++ show (natPkgConfig nd) ++ "\n" ++ trim (err ++ out)))
  where
    describe n = ("pkg-config:" : natPkgConfig n) ++ ("libs:" : natLibs n) ++ ("include:" : natIncludes n)
    trim = reverse . dropWhile (`elem` " \n\r\t") . reverse

-- | pkg-config may not be installed at all; treat that as a normal failure
-- with a clear message instead of an exception.
catchProc :: IO a -> a -> IO a
catchProc action def = action `catchIOError` (\_ -> return def)
