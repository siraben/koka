-----------------------------------------------------------------------------
-- Dependency resolution and fetching.
--
-- There is no version solving here by design.  A dependency names either a
-- local directory or a git repository pinned to an exact 40-character commit,
-- so "resolution" is just: walk the manifests, detect cycles and conflicts,
-- and make sure every source tree is present on disk.
--
-- Git checkouts live in `<project>/.koka/deps/<name>-<short rev>` and are
-- treated as immutable once populated: a pinned commit cannot change, so a
-- present checkout is never re-fetched.
-----------------------------------------------------------------------------
module Compile.Project.Fetch
  ( ResolveOptions(..)
  , ResolvedDep(..)
  , Resolved(..)
  , defaultResolveOptions
  , resolveProject
  , depCheckoutDir
  ) where

import Control.Monad      ( when, unless, forM, foldM )
import Data.Char          ( isSpace )
import Data.List          ( sortOn, nub, sort, intercalate )
import Data.Maybe         ( fromMaybe, catMaybes )
import System.Directory   ( doesDirectoryExist, doesFileExist
                          , createDirectoryIfMissing, canonicalizePath
                          , removeDirectoryRecursive )
import System.Exit        ( ExitCode(..) )
import System.FilePath    ( (</>), takeDirectory, isAbsolute, normalise, splitDirectories )
import System.Process     ( readProcessWithExitCode )

import Compile.Project.Manifest
import Compile.Project.Lock
import Compile.Project.Hash

-----------------------------------------------------------------------------
-- Options
-----------------------------------------------------------------------------

data ResolveOptions
  = ResolveOptions
      { roLocked   :: Bool   -- ^ fail rather than write or update the lockfile
      , roOffline  :: Bool   -- ^ never touch the network
      , roVerbose  :: Bool
      , roChecksum :: Bool   -- ^ compute content checksums (off for speed in `run`)
      }

defaultResolveOptions :: ResolveOptions
defaultResolveOptions = ResolveOptions False False False True

-----------------------------------------------------------------------------
-- Result
-----------------------------------------------------------------------------

data ResolvedDep
  = ResolvedDep
      { rdName     :: String
      , rdSource   :: DepSource
      , rdDir      :: FilePath      -- ^ absolute path to the package root
      , rdManifest :: Manifest
      , rdChecksum :: String
      }

data Resolved
  = Resolved
      { resRoot     :: Manifest
      , resDeps     :: [ResolvedDep]   -- ^ topologically ordered, dependencies first
      , resLock     :: Lock
      , resChanged  :: Bool            -- ^ the lockfile needs to be written
      }

-----------------------------------------------------------------------------
-- Resolution
-----------------------------------------------------------------------------

-- | Resolve the whole dependency graph of the project rooted at @projectDir@.
resolveProject :: ResolveOptions -> FilePath -> String -> IO (Either String Resolved)
resolveProject opts projectDir kokaVersion
  = do mbMan <- readManifest (projectDir </> manifestFileName)
       case mbMan of
         Left err  -> return (Left err)
         Right man ->
           case checkCompiler man of
             Left err -> return (Left err)
             Right () ->
               do mbLock <- readLock (projectDir </> lockFileName)
                  case mbLock of
                    Left err -> return (Left err)
                    Right lk -> resolveWith opts projectDir man lk
  where
    checkCompiler man
      = case manKoka man of
          Nothing -> Right ()
          Just c  -> checkKokaConstraint c kokaVersion

resolveWith :: ResolveOptions -> FilePath -> Manifest -> Maybe Lock -> IO (Either String Resolved)
resolveWith opts projectDir root mbLock
  = do -- In --locked mode the lockfile must exist and cover the manifest.
       case (roLocked opts, mbLock) of
         (True, Nothing)
           -> return (Left (lockFileName ++ " not found, but --locked was given; "
                              ++ "run `koka fetch` first (without --locked) to create it"))
         (True, Just lk)
           -> case lockMatchesManifest projectDir root lk of
                Left err -> return (Left (lockFileName ++ " is out of date: " ++ err
                                            ++ "\n(--locked refuses to update it)"))
                Right () -> go (Just lk)
         (False, _) -> go mbLock
  where
    go lk
      = do result <- walk lk
           case result of
             Left err -> return (Left err)
             Right deps ->
               do let newLock = Lock lockFormatVersion (manName root)
                                     (fromMaybe "" (manKoka root))
                                     (sortOn lockName (map toEntry deps))
                  let changed = case lk of
                                  Nothing  -> True
                                  Just old -> renderLock old /= renderLock newLock
                  return (Right (Resolved root deps newLock changed))

    -- A path dependency is recorded *relative to the project root*, not as the
    -- manifest that happened to be walked first spelled it.  The same package
    -- is reachable by different relative paths from different packages, and
    -- recording one of those spellings made `--locked` reject a manifest that
    -- was perfectly consistent.  Project-relative is also machine independent,
    -- which an absolute path would not be.
    toEntry d = LockEntry { lockName     = rdName d
                          , lockSource   = case rdSource d of
                                             DepGit u r -> DepGit u r
                                             DepPath _  -> DepPath (relativeTo projectDir (rdDir d))
                          , lockChecksum = rdChecksum d
                          , lockDeps     = sort (map depName (manDeps (rdManifest d)))
                          }

    -- Depth-first walk with cycle detection.  `seen` maps a package name to
    -- the source it was first resolved from, so two different pins of the
    -- same name are reported instead of silently picking one.
    --
    -- `base` is the directory a path dependency is relative *to*: the project
    -- root for a direct dependency, and the dependency's own directory for a
    -- transitive one.  Resolving everything against the root would break as
    -- soon as two packages sit in different directories.
    walk lk
      = do res <- foldM (step lk projectDir []) (Right ([], [])) (manDeps root)
           return (fmap (reverse . fst) res)

    step _ _ _ acc@(Left _) _ = return acc
    step lk base stack (Right (done, seen)) dep
      = do let name = depName dep
           ident <- identityOf base dep
           if name `elem` stack
             then return (Left ("dependency cycle: "
                                  ++ intercalate " -> " (reverse (name:stack)) ))
             else case lookup name seen of
                    Just prev
                      | prev /= ident
                        -> return (Left ("dependency '" ++ name ++ "' is required twice as "
                                           ++ "different packages:\n  " ++ prev
                                           ++ "\n  " ++ ident))
                      | otherwise -> return (Right (done, seen))
                    Nothing
                      -> do mb <- materialize opts base projectDir lk dep
                            case mb of
                              Left err -> return (Left err)
                              Right rd ->
                                do inner <- foldM (step lk (rdDir rd) (name:stack))
                                                  (Right (done, (name, ident):seen))
                                                  (manDeps (rdManifest rd))
                                   return (fmap (\(d2,s2) -> (rd:d2, s2)) inner)

    -- Two packages are the same when they resolve to the same place, not when
    -- they are *written* the same way: `../bytes` from one package and
    -- `../../koka-packages/bytes` from another are one package, and treating
    -- them as a conflict would make any diamond in the graph unbuildable.
    identityOf base dep
      = case depSource dep of
          DepGit u r  -> return ("git:" ++ u ++ "#" ++ r)
          DepPath rel -> do let raw = if isAbsolute rel then rel else normalise (base </> rel)
                            exist <- doesDirectoryExist raw
                            canon <- if exist then canonicalizePath raw else return raw
                            return ("path:" ++ canon)

-----------------------------------------------------------------------------
-- Materialising one dependency
-----------------------------------------------------------------------------

-- | Express @target@ relative to @base@, using POSIX separators so the result
-- is identical on every platform.
relativeTo :: FilePath -> FilePath -> FilePath
relativeTo base target
  = let b = splitDirectories (normalise base)
        t = splitDirectories (normalise target)
        (_common, br, tr) = strip b t
        ups = replicate (length br) ".."
    in case ups ++ tr of
         [] -> "."
         ps -> intercalate "/" ps
  where
    strip (x:xs) (y:ys) | x == y = let (c,a,b') = strip xs ys in (x:c, a, b')
    strip xs ys = ([], xs, ys)

-- | Where a git dependency is checked out.
--
-- The directory name embeds a digest of the URL *and* the full revision, so
-- changing either produces a fresh checkout instead of mutating the old one.
-- Twelve characters of the revision alone was not enough: two pins sharing a
-- 12-character prefix -- including one naming a commit that does not exist --
-- resolved to the same directory, and the existing checkout was reused while
-- the lockfile recorded the new revision against the old commit's contents.
depCheckoutDir :: FilePath -> String -> String -> String -> FilePath
depCheckoutDir projectDir name url rev
  = projectDir </> ".koka" </> "deps" </> (name ++ "-" ++ take 16 (hashStrings [url, rev]))

-- `base` is what a relative path dependency is resolved against; `projectDir`
-- is still where git checkouts are stored, so a project has one dependency
-- cache no matter how deep the graph goes.
materialize :: ResolveOptions -> FilePath -> FilePath -> Maybe Lock -> Dep -> IO (Either String ResolvedDep)
materialize opts base projectDir mbLock dep
  = case depSource dep of
      DepPath rel
        -> do let dir = if isAbsolute rel then rel else normalise (base </> rel)
              exist <- doesDirectoryExist dir
              if not exist
                then return (Left ("path dependency '" ++ depName dep ++ "' not found: " ++ dir))
                else finish dir
      DepGit url rev
        -> do let dir = depCheckoutDir projectDir (depName dep) url rev
              -- A checkout is only reusable if it is a real worktree sitting at
              -- exactly the requested commit.  "contains a koka.toml" also
              -- accepted a directory left behind by an interrupted fetch.
              ok <- checkoutIsAt dir rev
              if ok
                then finish dir
                else if roOffline opts
                       then return (Left ("git dependency '" ++ depName dep
                                            ++ "' is not fetched and --offline was given"))
                       else do r <- gitFetchPinned (roVerbose opts) url rev dir
                               case r of
                                 Left err -> return (Left err)
                                 Right () -> finish dir
  where
    finish dir
      = do adir  <- canonicalizePath dir
           mbMan <- readManifest (adir </> manifestFileName)
           case mbMan of
             Left err  -> return (Left ("dependency '" ++ depName dep ++ "': " ++ err))
             Right man
               | manName man /= depName dep
                 -> return (Left ("dependency '" ++ depName dep ++ "' resolves to a package named '"
                                    ++ manName man ++ "' (" ++ adir ++ ")"))
               | otherwise
                 -> do sum' <- if roChecksum opts
                                 then do h <- hashTree adir
                                         return ("sha256:" ++ h)
                                 else return (recordedChecksum (depName dep))
                       case verify (depName dep) sum' of
                         Left err -> return (Left err)
                         Right () -> return (Right (ResolvedDep (depName dep) (depSource dep) adir man sum'))

    recordedChecksum name
      = case mbLock >>= \lk -> lockEntryFor lk name of
          Just e  -> lockChecksum e
          Nothing -> ""

    -- A recorded checksum that no longer matches means the dependency's
    -- contents changed underneath a pin.  For git that should be impossible;
    -- for a path dependency it is expected and only an error under --locked.
    --
    -- The comparison only applies when the lock entry describes the *same*
    -- source: if the manifest moved the pin to another commit, the recorded
    -- checksum belongs to the old commit and is simply superseded.
    verify name actual
      = case mbLock >>= \lk -> lockEntryFor lk name of
          Just e | lockSource e == depSource dep
                 , not (null (lockChecksum e)) && not (null actual)
                 , lockChecksum e /= actual
                 -> case depSource dep of
                      DepGit _ rev
                        -> Left ("checksum mismatch for git dependency '" ++ name ++ "' at " ++ rev
                                   ++ "\n  expected " ++ lockChecksum e
                                   ++ "\n  actual   " ++ actual
                                   ++ "\n  the checkout under .koka/deps is corrupt; remove it and re-run `koka fetch`")
                      DepPath p
                        | roLocked opts
                          -> Left ("path dependency '" ++ name ++ "' (" ++ p ++ ") changed since "
                                     ++ lockFileName ++ " was written"
                                     ++ "\n  expected " ++ lockChecksum e
                                     ++ "\n  actual   " ++ actual
                                     ++ "\n  run `koka fetch` to update the lockfile")
                        | otherwise -> Right ()
          _ -> Right ()

-----------------------------------------------------------------------------
-- git
-----------------------------------------------------------------------------

-- | Is `dir` a git worktree sitting at exactly `rev`?
--
-- "contains a koka.toml" was the old test, which also accepted a directory an
-- interrupted fetch had left behind, and -- once checkout directories were
-- keyed on a 12-character prefix -- a checkout of an entirely different
-- commit.  Asking git what it is actually at costs one process and removes
-- both.
checkoutIsAt :: FilePath -> String -> IO Bool
checkoutIsAt dir rev
  = do ok <- doesFileExist (dir </> manifestFileName)
       if not ok then return False
         else do (code,out,_) <- readProcessWithExitCode "git" ["-C",dir,"rev-parse","HEAD"] ""
                 return (code == ExitSuccess && trim out == rev)
  where
    trim = dropWhile isSpace . reverse . dropWhile isSpace . reverse

-- | Fetch exactly one commit into a fresh directory.  Tries a shallow fetch of
-- the pinned object first (supported by GitHub and any server with
-- `uploadpack.allowReachableSHA1InWant`), then falls back to a full fetch.
gitFetchPinned :: Bool -> String -> String -> FilePath -> IO (Either String ())
gitFetchPinned verbose url rev dir
  = do -- Never reuse a half-populated directory.
       exists <- doesDirectoryExist dir
       when exists $ removeDirectoryRecursive dir
       createDirectoryIfMissing True dir
       r <- steps [ ["init","-q",dir]
                  , ["-C",dir,"remote","add","origin",url]
                  ]
       case r of
         Left err -> return (Left err)
         Right () ->
           do shallow <- git ["-C",dir,"fetch","-q","--depth","1","origin",rev]
              deep <- case shallow of
                        Right () -> return (Right ())
                        Left _   -> git ["-C",dir,"fetch","-q","origin"]
              case deep of
                Left err -> return (Left (fetchFailed err))
                Right () ->
                  do co <- git ["-C",dir,"checkout","-q","--detach",rev]
                     case co of
                       Left err -> return (Left (fetchFailed err))
                       Right () -> do sub <- git ["-C",dir,"submodule","update","--init","--recursive","-q"]
                                      case sub of
                                        -- A checkout whose submodules did not
                                        -- arrive is incomplete, and because a
                                        -- checkout is trusted once it exists it
                                        -- would never be retried.  Remove it and
                                        -- report the failure.
                                        Left err -> do removeDirectoryRecursive dir
                                                       return (Left (fetchFailed err))
                                        Right () -> return (Right ())
  where
    fetchFailed err
      = "failed to fetch " ++ url ++ " at " ++ rev ++ "\n" ++ err

    steps [] = return (Right ())
    steps (a:as) = do r <- git a
                      case r of
                        Left err -> return (Left err)
                        Right () -> steps as

    git args
      = do when verbose $ putStrLn ("git " ++ unwords args)
           (code,out,err) <- readProcessWithExitCode "git" args ""
           case code of
             ExitSuccess -> return (Right ())
             _           -> return (Left (trimTrailing (out ++ err)))

    trimTrailing = reverse . dropWhile (`elem` " \n\r\t") . reverse
