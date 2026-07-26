-----------------------------------------------------------------------------
-- Machine readable compiler statistics.
--
-- Collects wall-clock timings for the major compiler phases, plus the size of
-- the generated C and of the final executable, and emits them as JSON (or a
-- short human readable summary) when `--stats=json` / `--stats=text` is given.
--
-- The collector is a process-global IORef.  The build runs modules
-- concurrently across many threads and the phase functions are deep inside the
-- `Build` monad, so threading a handle through every signature buys nothing:
-- there is exactly one compilation per process invocation.  All updates go
-- through `atomicModifyIORef'`.
--
-- Note on interpreting the numbers: `phases` records the *sum* of per-module
-- wall-clock time in each phase.  Because modules are compiled concurrently
-- that sum can exceed `total_ms`.  `total_ms` is the only number that measures
-- elapsed time for the whole invocation.
-----------------------------------------------------------------------------
module Compile.Stats
  ( StatsFormat(..)
  , statsFormatFromString
  , statsEnable
  , statsIsEnabled
  , statsReset
  , statsTimePhase
  , statsAddPhase
  , statsSetTotal
  , statsRecordArtifacts
  , statsRecordExe
  , statsGetLastExe
  , statsCollect
  , statsToJson
  , statsToText
  , statsEmit
  ) where

import Data.IORef
import Numeric           ( showHex )
import Data.List          ( sortOn, isSuffixOf, foldl', intercalate )
import Data.Time.Clock    ( getCurrentTime, diffUTCTime, UTCTime )
import Control.Exception  ( finally )
import Control.Monad      ( when, unless, forM, filterM )
import System.IO          ( hPutStrLn, stdout, withFile, IOMode(..) )
import System.IO.Error    ( catchIOError )
import System.IO.Unsafe   ( unsafePerformIO )
import System.Directory   ( doesDirectoryExist, doesFileExist, getFileSize
                          , listDirectory )
import System.FilePath    ( (</>) )
import qualified Data.Map.Strict as M

-----------------------------------------------------------------------------
-- Configuration
-----------------------------------------------------------------------------

data StatsFormat
  = StatsNone
  | StatsJson
  | StatsText
  deriving (Eq, Show)

-- | Parse the argument of `--stats=<fmt>`.  An empty argument means `json`
-- so that a bare `--stats` is useful.
statsFormatFromString :: String -> Maybe StatsFormat
statsFormatFromString s
  = case s of
      ""      -> Just StatsJson
      "json"  -> Just StatsJson
      "text"  -> Just StatsText
      "none"  -> Just StatsNone
      "off"   -> Just StatsNone
      _       -> Nothing

-----------------------------------------------------------------------------
-- The collector
-----------------------------------------------------------------------------

data Stats
  = Stats { statsPhases    :: !(M.Map String (Double,Int))  -- name -> (ms, count)
          , statsTotalMs   :: !(Maybe Double)
          , statsCFiles    :: !Int
          , statsCBytes    :: !Integer
          , statsExePath   :: !FilePath
          , statsExeBytes  :: !Integer
          }

statsNil :: Stats
statsNil = Stats M.empty Nothing 0 0 "" 0

{-# NOINLINE theStats #-}
theStats :: IORef Stats
theStats = unsafePerformIO (newIORef statsNil)

-- | The last executable the build linked.  Recorded unconditionally (not only
-- when statistics are enabled) because `koka test` needs it to run each test
-- program itself and inspect its exit status.
{-# NOINLINE theLastExe #-}
theLastExe :: IORef FilePath
theLastExe = unsafePerformIO (newIORef "")

statsGetLastExe :: IO FilePath
statsGetLastExe = readIORef theLastExe

{-# NOINLINE theEnabled #-}
theEnabled :: IORef Bool
theEnabled = unsafePerformIO (newIORef False)

statsEnable :: Bool -> IO ()
statsEnable b = writeIORef theEnabled b

statsIsEnabled :: IO Bool
statsIsEnabled = readIORef theEnabled

statsReset :: IO ()
statsReset = writeIORef theStats statsNil

-- | Add @ms@ milliseconds to the named phase bucket.
statsAddPhase :: String -> Double -> IO ()
statsAddPhase name ms
  = do enabled <- readIORef theEnabled
       when enabled $
         atomicModifyIORef' theStats $ \st ->
           let phases = M.insertWith (\(a,b) (c,d) -> (a+c,b+d)) name (ms,1) (statsPhases st)
           in (st{ statsPhases = phases }, ())

-- | Time an IO action into the named phase bucket.  The timing is recorded
-- even when the action throws, so a failed build still reports where the time
-- went.
statsTimePhase :: String -> IO a -> IO a
statsTimePhase name action
  = do enabled <- readIORef theEnabled
       if not enabled
         then action
         else do t0 <- getCurrentTime
                 action `finally` (do t1 <- getCurrentTime
                                      statsAddPhase name (elapsedMs t0 t1))

elapsedMs :: UTCTime -> UTCTime -> Double
elapsedMs t0 t1 = realToFrac (diffUTCTime t1 t0) * 1000.0

statsSetTotal :: Double -> IO ()
statsSetTotal ms
  = atomicModifyIORef' theStats $ \st -> (st{ statsTotalMs = Just ms }, ())

-----------------------------------------------------------------------------
-- Artifact sizes
-----------------------------------------------------------------------------

-- | Measure the generated C in @outdir@ (recursively) and the size of the
-- final executable at @exePath@ (which may be empty for a library build).
statsRecordArtifacts :: FilePath -> FilePath -> IO ()
statsRecordArtifacts outdir exePath
  = do enabled <- readIORef theEnabled
       when enabled $
         do (n,bytes) <- measureGeneratedC outdir
            atomicModifyIORef' theStats $ \st ->
              (st{ statsCFiles = n, statsCBytes = bytes }, ())
            unless (null exePath) (statsRecordExe exePath)

-- | Record the final executable.  The path is only known once an entry point
-- has actually been linked, which is later than when the build directory is
-- known, so it is recorded separately.
statsRecordExe :: FilePath -> IO ()
statsRecordExe exePath
  = do writeIORef theLastExe exePath
       enabled <- readIORef theEnabled
       when enabled $
         do bytes <- fileSizeOr0 exePath
            atomicModifyIORef' theStats $ \st ->
              (st{ statsExePath = exePath, statsExeBytes = bytes }, ())

-- | Sum the size of every generated .c/.h file under a directory.
measureGeneratedC :: FilePath -> IO (Int,Integer)
measureGeneratedC dir
  = do exist <- doesDirectoryExist dir
       if not exist then return (0,0) else go dir
  where
    go d = do entries <- listDirectory d `orElse` []
              results <- forM entries $ \e ->
                do let p = d </> e
                   isDir <- doesDirectoryExist p
                   if isDir
                     then go p
                     else if isGenC e
                            then do sz <- fileSizeOr0 p
                                    return (1,sz)
                            else return (0,0)
              return (foldl' (\(a,b) (c,d') -> (a+c,b+d')) (0,0) results)

    isGenC e = ".c" `isSuffixOf` e || ".h" `isSuffixOf` e

fileSizeOr0 :: FilePath -> IO Integer
fileSizeOr0 "" = return 0
fileSizeOr0 p
  = do exist <- doesFileExist p
       if exist then getFileSize p `orElse` 0 else return 0

-- | Measuring artifacts must never fail a build: a directory that disappeared
-- underneath us just contributes zero.
orElse :: IO a -> a -> IO a
orElse action def
  = action `catchIOError` (\_ -> return def)

-----------------------------------------------------------------------------
-- Rendering
-----------------------------------------------------------------------------

-- | Snapshot the collector.
statsCollect :: IO Stats
statsCollect = readIORef theStats

-- | Render as a single line of JSON.  Machine readable output should be one
-- object per line so that it can be piped straight into `jq`.
statsToJson :: String -> String -> Stats -> String
statsToJson kokaVersion targetName st
  = jobj
      [ ("koka_version", jstr kokaVersion)
      , ("target",       jstr targetName)
      , ("total_ms",     jnum (maybe 0 id (statsTotalMs st)))
      , ("phases",       jarr (map phaseJson (sortOn fst (M.toList (statsPhases st)))))
      , ("generated_c",  jobj [ ("files", show (statsCFiles st))
                              , ("bytes", show (statsCBytes st)) ])
      , ("executable",   jobj [ ("path",  jstr (statsExePath st))
                              , ("bytes", show (statsExeBytes st)) ])
      ]
  where
    phaseJson (name,(ms,n))
      = jobj [ ("name", jstr name), ("wall_ms", jnum ms), ("count", show n) ]

jobj :: [(String,String)] -> String
jobj kvs = "{" ++ intercalate "," [ jstr k ++ ":" ++ v | (k,v) <- kvs ] ++ "}"

jarr :: [String] -> String
jarr vs = "[" ++ intercalate "," vs ++ "]"

-- Every control character must be escaped, not just the five with short
-- forms: a path containing, say, a form feed produced output that standard
-- JSON parsers reject, which defeats the point of a machine-readable mode.
jstr :: String -> String
jstr s = '"' : concatMap esc s ++ "\""
  where
    esc '"'  = "\\\""
    esc '\\' = "\\\\"
    esc '\n' = "\\n"
    esc '\t' = "\\t"
    esc '\r' = "\\r"
    esc '\b' = "\\b"
    esc '\f' = "\\f"
    esc c
      | c < ' ' || c == '\DEL' = "\\u" ++ pad (showHex (fromEnum c) "")
      | otherwise             = [c]

    pad h = replicate (4 - length h) '0' ++ h

-- | Milliseconds with three decimals, never in exponent notation (some JSON
-- consumers are picky, and it reads better in a diff).
jnum :: Double -> String
jnum d
  = let neg    = d < 0
        scaled = round (abs d * 1000) :: Integer
        (i,f)  = scaled `divMod` 1000
        frac   = let s = show f in replicate (3 - length s) '0' ++ s
    in (if neg then "-" else "") ++ show i ++ "." ++ frac

statsToText :: String -> String -> Stats -> String
statsToText kokaVersion targetName st
  = unlines $
    [ "koka " ++ kokaVersion ++ " (" ++ targetName ++ ")"
    , "total          " ++ jnum (maybe 0 id (statsTotalMs st)) ++ "ms"
    ] ++
    [ "  " ++ pad 12 name ++ " " ++ jnum ms ++ "ms  (" ++ show n ++ " modules)"
    | (name,(ms,n)) <- sortOn fst (M.toList (statsPhases st)) ] ++
    [ "generated c    " ++ show (statsCFiles st) ++ " files, " ++ show (statsCBytes st) ++ " bytes" ] ++
    [ "executable     " ++ show (statsExeBytes st) ++ " bytes  " ++ statsExePath st
    | not (null (statsExePath st)) ]
  where
    pad n s  = s ++ replicate (n - length s) ' '

-- | Emit the collected statistics in the requested format.  An empty path
-- writes to stdout.
statsEmit :: StatsFormat -> FilePath -> String -> String -> IO ()
statsEmit StatsNone _ _ _ = return ()
statsEmit fmt path kokaVersion targetName
  = do st <- statsCollect
       let out = case fmt of
                   StatsJson -> statsToJson kokaVersion targetName st
                   StatsText -> init (statsToText kokaVersion targetName st)
                   StatsNone -> ""
       if null path
         then hPutStrLn stdout out
         else withFile path WriteMode (\h -> hPutStrLn h out)
