-----------------------------------------------------------------------------
-- The project build cache.
--
-- Koka already does fine-grained, per-module incremental compilation inside a
-- build directory.  What the project layer adds is a *content-addressed choice
-- of build directory*: everything that would invalidate the whole tree
-- (compiler version, target, profile, flags, lockfile, native settings) is
-- hashed into a cache key, and the key names the build directory.
--
-- Consequences:
--
--   * a no-op rebuild reuses the same directory and Koka's own up-to-date
--     checks make it cheap;
--   * changing the compiler version, a dependency commit, the build profile,
--     or a relevant flag selects a *different* directory, so a stale artifact
--     can never be picked up;
--   * a source edit keeps the same directory and is handled by the per-module
--     incremental build;
--   * a corrupt cache is detected through the stamp file and the directory is
--     discarded rather than half-used.
--
-- There is deliberately no remote or binary cache.
-----------------------------------------------------------------------------
module Compile.Project.Cache
  ( CacheKey(..)
  , cacheKeyHash
  , cacheKeyText
  , projectBuildRoot
  , cacheDirFor
  , validateCacheDir
  , writeCacheStamp
  , clearProjectArtifacts
  ) where

import Control.Monad      ( when, unless, forM )
import Data.List          ( sort, intercalate )
import System.Directory   ( doesDirectoryExist, doesFileExist, createDirectoryIfMissing
                          , removeDirectoryRecursive, listDirectory )
import System.FilePath    ( (</>) )
import System.IO          ( withFile, IOMode(..), hPutStr, hSetNewlineMode, noNewlineTranslation
                          , hSetEncoding, utf8 )
import System.IO.Error    ( catchIOError )

import Compile.Project.Hash

-- | Everything that invalidates a whole build tree.
data CacheKey
  = CacheKey
      { ckKokaVersion :: String
      , ckTarget      :: String   -- ^ backend, e.g. "c"
      , ckTargetOS    :: String
      , ckTargetArch  :: String
      , ckProfile     :: String   -- ^ "debug" | "release"
      , ckFlagsHash   :: String   -- ^ the compiler's own hash of build-relevant flags
      , ckLockHash    :: String   -- ^ hash of the rendered lockfile
      , ckSourceHash  :: String   -- ^ hash of the project's own sources
      , ckNativeHash  :: String   -- ^ hash of resolved native include/link settings
      }
  deriving (Eq, Show)

-- | Human readable, one setting per line.  This is what goes into the stamp
-- file, so a developer can see *why* the cache key changed.
cacheKeyText :: CacheKey -> String
cacheKeyText k
  = unlines
      [ "koka-version = " ++ ckKokaVersion k
      , "target       = " ++ ckTarget k
      , "target-os    = " ++ ckTargetOS k
      , "target-arch  = " ++ ckTargetArch k
      , "profile      = " ++ ckProfile k
      , "flags        = " ++ ckFlagsHash k
      , "lock         = " ++ ckLockHash k
      , "sources      = " ++ ckSourceHash k
      , "native       = " ++ ckNativeHash k
      ]

-- | The short tag used as the build directory name.
cacheKeyHash :: CacheKey -> String
cacheKeyHash k
  = take 16 (hashStrings
      [ ckKokaVersion k, ckTarget k, ckTargetOS k, ckTargetArch k
      , ckProfile k, ckFlagsHash k, ckLockHash k, ckSourceHash k, ckNativeHash k ])

-- | All project-generated artifacts live under here.
projectBuildRoot :: FilePath -> FilePath
projectBuildRoot projectDir = projectDir </> ".koka" </> "build"

cacheDirFor :: FilePath -> CacheKey -> FilePath
cacheDirFor projectDir k = projectBuildRoot projectDir </> cacheKeyHash k

stampFile :: FilePath -> FilePath
stampFile dir = dir </> "cache-key.txt"

-- | Check a cache directory before use.  If a directory exists but its stamp
-- is missing or does not match the key we are about to build under, the
-- directory is from an interrupted or corrupted run: remove it so the build
-- starts clean.  Returns True if a usable cache was kept.
validateCacheDir :: FilePath -> CacheKey -> IO Bool
validateCacheDir dir key
  = do exist <- doesDirectoryExist dir
       if not exist
         then do createDirectoryIfMissing True dir
                 return False
         else do stamp <- readFileOr (stampFile dir) ""
                 if stamp == cacheKeyText key
                   then return True
                   else do removeDirectoryRecursive dir `catchIOError` (\_ -> return ())
                           createDirectoryIfMissing True dir
                           return False

-- | Written only after a successful build, so an interrupted build leaves a
-- directory that fails validation next time.
writeCacheStamp :: FilePath -> CacheKey -> IO ()
writeCacheStamp dir key
  = do createDirectoryIfMissing True dir
       withFile (stampFile dir) WriteMode $ \h ->
         do hSetEncoding h utf8
            hSetNewlineMode h noNewlineTranslation
            hPutStr h (cacheKeyText key)

readFileOr :: FilePath -> String -> IO String
readFileOr p def
  = (do exist <- doesFileExist p
        if exist then readFile' p else return def)
      `catchIOError` (\_ -> return def)
  where
    -- force the contents so the handle is closed before we might delete the file
    readFile' f = do s <- readFile f
                     length s `seq` return s

-- | `koka clean`: remove generated project artifacts but keep fetched
-- dependencies, which are expensive to re-download and are pinned anyway.
clearProjectArtifacts :: FilePath -> IO [FilePath]
clearProjectArtifacts projectDir
  = do let root = projectBuildRoot projectDir
       exist <- doesDirectoryExist root
       if not exist
         then return []
         else do entries <- listDirectory root
                 forM (sort entries) $ \e ->
                   do let d = root </> e
                      removeDirectoryRecursive d `catchIOError` (\_ -> return ())
                      return d
