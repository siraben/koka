-----------------------------------------------------------------------------
-- The `koka.lock` deterministic lockfile.
--
-- Guarantees:
--
--   * entries are written in sorted order by package name;
--   * no timestamps or machine-specific absolute paths are recorded;
--   * regenerating the lockfile from an unchanged manifest and unchanged
--     dependency contents produces a byte-identical file;
--   * `--locked` refuses to update the lockfile, so a locked build cannot
--     silently move to a different commit;
--   * a malformed lockfile is reported as corruption with the offending key,
--     never silently ignored.
--
-- The file is written in the same restricted TOML that `Compile.Project.Toml`
-- reads, so it stays diff-friendly and needs no second parser.
-----------------------------------------------------------------------------
module Compile.Project.Lock
  ( Lock(..)
  , LockEntry(..)
  , lockFileName
  , lockFormatVersion
  , readLock
  , renderLock
  , writeLock
  , lockEntryFor
  , lockMatchesManifest
  ) where

import Data.List        ( sortOn, intercalate, sort )
import Data.Maybe       ( fromMaybe )
import System.Directory ( doesFileExist )
import System.IO        ( withFile, IOMode(..), hSetEncoding, utf8, hPutStr, hSetNewlineMode
                        , noNewlineTranslation )

import Compile.Project.Toml
import Compile.Project.Manifest

lockFileName :: FilePath
lockFileName = "koka.lock"

-- | Bumped whenever the on-disk shape changes.  A lockfile with a different
-- version is regenerated rather than misread.
lockFormatVersion :: Integer
lockFormatVersion = 1

-----------------------------------------------------------------------------
-- Model
-----------------------------------------------------------------------------

data Lock
  = Lock { lockVersion  :: Integer
         , lockRoot     :: String          -- ^ root package name
         , lockKoka     :: String          -- ^ compiler constraint copied from the manifest
         , lockEntries  :: [LockEntry]     -- ^ sorted by name
         }
  deriving (Eq, Show)

data LockEntry
  = LockEntry { lockName     :: String
              , lockSource   :: DepSource
              , lockChecksum :: String     -- ^ "sha256:<hex>", or "" when not computed
              , lockDeps     :: [String]   -- ^ names of this package's own dependencies, sorted
              }
  deriving (Eq, Show)

lockEntryFor :: Lock -> String -> Maybe LockEntry
lockEntryFor lk name = lookup name [ (lockName e, e) | e <- lockEntries lk ]

-----------------------------------------------------------------------------
-- Reading
-----------------------------------------------------------------------------

readLock :: FilePath -> IO (Either String (Maybe Lock))
readLock path
  = do exist <- doesFileExist path
       if not exist
         then return (Right Nothing)
         else do content <- readFile path
                 return (fmap Just (parseLock path content))

parseLock :: FilePath -> String -> Either String Lock
parseLock path content
  = do tbl <- parseToml path content
       ver <- case tomlLookup tbl ["version"] of
                Just (TomlInt n) -> Right n
                Just _           -> corrupt "version must be an integer"
                Nothing          -> corrupt "missing 'version'"
       if ver /= lockFormatVersion
         then Left (path ++ ": lockfile format version " ++ show ver
                      ++ " is not supported (expected " ++ show lockFormatVersion
                      ++ "); delete it and run `koka fetch` to regenerate")
         else do
           root <- str tbl ["root"]
           koka <- Right (fromMaybe "" (tomlLookup tbl ["koka"] >>= tomlString))
           entries <- case tomlLookup tbl ["packages"] of
                        Nothing -> Right []
                        Just v  -> case tomlTable v of
                                     Nothing -> corrupt "[packages] must be a table"
                                     Just t  -> mapM parseEntry t
           return (Lock ver root koka (sortOn lockName entries))
  where
    corrupt msg = Left (path ++ ": corrupt lockfile: " ++ msg)

    str t p = case tomlLookup t p >>= tomlString of
                Just s  -> Right s
                Nothing -> corrupt ("missing or non-string '" ++ intercalate "." p ++ "'")

    parseEntry (name, val)
      = case tomlTable val of
          Nothing -> corrupt ("packages." ++ name ++ " must be a table")
          Just t  ->
            do kind <- case lookup "kind" t >>= tomlString of
                         Just k  -> Right k
                         Nothing -> corrupt ("packages." ++ name ++ " is missing 'kind'")
               src <- case kind of
                        "path" -> case lookup "path" t >>= tomlString of
                                    Just p  -> Right (DepPath p)
                                    Nothing -> corrupt ("packages." ++ name ++ " is missing 'path'")
                        "git"  -> case (lookup "url" t >>= tomlString, lookup "rev" t >>= tomlString) of
                                    (Just u, Just r) -> Right (DepGit u r)
                                    _ -> corrupt ("packages." ++ name ++ " is missing 'url' or 'rev'")
                        other  -> corrupt ("packages." ++ name ++ " has unknown kind '" ++ other ++ "'")
               let sum' = fromMaybe "" (lookup "checksum" t >>= tomlString)
               deps <- case lookup "dependencies" t of
                         Nothing -> Right []
                         Just v  -> case tomlStringList v of
                                      Just ds -> Right (sort ds)
                                      Nothing -> corrupt ("packages." ++ name ++ ".dependencies must be an array of strings")
               return (LockEntry name src sum' deps)

-----------------------------------------------------------------------------
-- Writing
-----------------------------------------------------------------------------

-- | Render deterministically.  Callers must not add anything time- or
-- machine-dependent here.
renderLock :: Lock -> String
renderLock lk
  = unlines $
      [ "# koka.lock -- generated by `koka fetch`; do not edit by hand."
      , "version = " ++ show (lockVersion lk)
      , "root = " ++ quoted (lockRoot lk)
      , "koka = " ++ quoted (lockKoka lk)
      ]
      ++ concatMap entryLines (sortOn lockName (lockEntries lk))
  where
    entryLines e
      = [ "" , "[packages." ++ e0 ++ "]" ]
        ++ sourceLines (lockSource e)
        ++ [ "checksum = " ++ quoted (lockChecksum e) | not (null (lockChecksum e)) ]
        ++ [ "dependencies = [" ++ intercalate ", " (map quoted (sort (lockDeps e))) ++ "]" ]
      where e0 = lockName e

    sourceLines (DepPath p)
      = [ "kind = \"path\"", "path = " ++ quoted p ]
    sourceLines (DepGit u r)
      = [ "kind = \"git\"", "url = " ++ quoted u, "rev = " ++ quoted r ]

quoted :: String -> String
quoted s = '"' : concatMap esc s ++ "\""
  where
    esc '"'  = "\\\""
    esc '\\' = "\\\\"
    esc '\n' = "\\n"
    esc '\t' = "\\t"
    esc '\r' = "\\r"
    esc c    = [c]

-- | Write with LF line endings on every platform so lockfiles are identical
-- across machines.
writeLock :: FilePath -> Lock -> IO ()
writeLock path lk
  = withFile path WriteMode $ \h ->
      do hSetEncoding h utf8
         hSetNewlineMode h noNewlineTranslation
         hPutStr h (renderLock lk)

-----------------------------------------------------------------------------
-- Consistency
-----------------------------------------------------------------------------

-- | Does the lockfile still describe this manifest's direct dependencies?
-- Returns a human readable reason when it does not.
lockMatchesManifest :: Manifest -> Lock -> Either String ()
lockMatchesManifest man lk
  = do if lockRoot lk /= manName man
         then Left ("lockfile is for package '" ++ lockRoot lk
                      ++ "' but the manifest declares '" ++ manName man ++ "'")
         else Right ()
       mapM_ checkDep (manDeps man)
  where
    checkDep d
      = case lockEntryFor lk (depName d) of
          Nothing -> Left ("dependency '" ++ depName d ++ "' is in " ++ manifestFileName
                             ++ " but not in " ++ lockFileName)
          Just e | lockSource e /= depSource d
                 -> Left ("dependency '" ++ depName d ++ "' changed in " ++ manifestFileName
                            ++ " (" ++ depSourceKey (depSource d) ++ ") but "
                            ++ lockFileName ++ " records " ++ depSourceKey (lockSource e))
                 | otherwise -> Right ()
