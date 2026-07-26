-----------------------------------------------------------------------------
-- The `koka.toml` project manifest.
--
-- The schema is intentionally small.  There is no registry, no publishing, no
-- version solving: a dependency is either a local path or a git repository
-- pinned to an exact commit.  That is enough to build the reference service
-- reproducibly, and it keeps `koka fetch --locked` honest.
-----------------------------------------------------------------------------
module Compile.Project.Manifest
  ( Manifest(..)
  , Dep(..)
  , DepSource(..)
  , Targets(..)
  , NativeDeps(..)
  , manifestFileName
  , readManifest
  , parseManifest
  , depSourceKey
  , checkKokaConstraint
  , parseVersion
  , compareVersions
  , defaultManifestText
  ) where

import Data.Char        ( isDigit, isSpace )
import Data.List        ( isPrefixOf, sortOn, intercalate )
import Data.Maybe       ( fromMaybe )
import System.Directory ( doesFileExist )
import System.FilePath  ( (</>), takeDirectory )

import Compile.Project.Toml

manifestFileName :: FilePath
manifestFileName = "koka.toml"

-----------------------------------------------------------------------------
-- Model
-----------------------------------------------------------------------------

data Manifest
  = Manifest
      { manRoot        :: FilePath      -- ^ directory containing koka.toml
      , manName        :: String
      , manVersion     :: String
      , manKoka        :: Maybe String  -- ^ compiler constraint, e.g. ">=3.2,<4"
      , manSourceDirs  :: [FilePath]
      , manDeps        :: [Dep]         -- ^ sorted by name for determinism
      , manNative      :: NativeDeps
      , manTargets     :: Targets
      }
  deriving (Eq, Show)

data Dep
  = Dep { depName   :: String
        , depSource :: DepSource
        }
  deriving (Eq, Show)

data DepSource
  = DepPath FilePath          -- ^ relative to the manifest directory
  | DepGit  { depGitUrl :: String, depGitRev :: String }
  deriving (Eq, Show)

data NativeDeps
  = NativeDeps { natPkgConfig :: [String]   -- ^ pkg-config module names
               , natLibs      :: [String]   -- ^ bare library names (-l...)
               , natIncludes  :: [FilePath] -- ^ extra include directories
               }
  deriving (Eq, Show)

data Targets
  = Targets { tgtMain     :: Maybe FilePath  -- ^ [targets.app] main
            , tgtTestDirs :: [FilePath]      -- ^ [targets.test] directories
            }
  deriving (Eq, Show)

-- | A stable identity string for a dependency source, used in the lockfile and
-- in cache keys.
depSourceKey :: DepSource -> String
depSourceKey (DepPath p)    = "path:" ++ normalizeSlashes p
depSourceKey (DepGit u r)   = "git:" ++ u ++ "#" ++ r

normalizeSlashes :: String -> String
normalizeSlashes = map (\c -> if c == '\\' then '/' else c)

-----------------------------------------------------------------------------
-- Reading
-----------------------------------------------------------------------------

-- | Read and validate a manifest.  @path@ is the manifest file itself.
readManifest :: FilePath -> IO (Either String Manifest)
readManifest path
  = do exist <- doesFileExist path
       if not exist
         then return (Left ("no " ++ manifestFileName ++ " found at " ++ path))
         else do content <- readFile path
                 return (parseManifest path content)

parseManifest :: FilePath -> String -> Either String Manifest
parseManifest path content
  = do tbl  <- parseToml path content
       name <- req tbl ["package","name"] "package.name"
       ver  <- req tbl ["package","version"] "package.version"
       let koka = tomlLookup tbl ["package","koka"] >>= tomlString
       srcs <- optStrings tbl ["sources","directories"] ["src"] "sources.directories"
       deps <- readDeps tbl
       nat  <- readNative tbl
       tgts <- readTargets tbl
       validateName name
       return Manifest { manRoot       = takeDirectory path
                       , manName       = name
                       , manVersion    = ver
                       , manKoka       = koka
                       , manSourceDirs = srcs
                       , manDeps       = sortOn depName deps
                       , manNative     = nat
                       , manTargets    = tgts
                       }
  where
    req t p label
      = case tomlLookup t p >>= tomlString of
          Just s | not (null s) -> Right s
          Just _  -> Left (path ++ ": " ++ label ++ " must not be empty")
          Nothing -> Left (path ++ ": missing required key " ++ label)

    optStrings t p def label
      = case tomlLookup t p of
          Nothing -> Right def
          Just v  -> case tomlStringList v of
                       Just ss -> Right ss
                       Nothing -> Left (path ++ ": " ++ label ++ " must be an array of strings")

    validateName n
      | all (\c -> c `elem` "-_" || c `elem` ['a'..'z'] || c `elem` ['A'..'Z'] || isDigit c) n = Right ()
      | otherwise = Left (path ++ ": package.name may only contain letters, digits, '-' and '_'")

    readDeps t
      = case tomlLookup t ["dependencies"] of
          Nothing -> Right []
          Just v  -> case tomlTable v of
                       Nothing  -> Left (path ++ ": [dependencies] must be a table")
                       Just tbl -> mapM readDep tbl

    readDep (name, val)
      = case tomlTable val of
          Nothing -> Left (path ++ ": dependency '" ++ name ++ "' must be a table like "
                             ++ "{ path = \"...\" } or { git = \"...\", rev = \"...\" }")
          Just d ->
            case (lookup "path" d, lookup "git" d, lookup "rev" d) of
              (Just p, Nothing, Nothing)
                -> case tomlString p of
                     Just s  -> Right (Dep name (DepPath s))
                     Nothing -> Left (path ++ ": dependency '" ++ name ++ "': path must be a string")
              (Nothing, Just g, Just r)
                -> case (tomlString g, tomlString r) of
                     (Just gu, Just rv)
                       | isFullRev rv -> Right (Dep name (DepGit gu rv))
                       | otherwise    -> Left (path ++ ": dependency '" ++ name ++ "': rev must be a full "
                                                 ++ "40-character git commit hash (no branches or tags)")
                     _ -> Left (path ++ ": dependency '" ++ name ++ "': git and rev must be strings")
              (Nothing, Just _, Nothing)
                -> Left (path ++ ": dependency '" ++ name ++ "': a git dependency must pin an exact 'rev'")
              (Just _, Just _, _)
                -> Left (path ++ ": dependency '" ++ name ++ "': cannot be both a path and a git dependency")
              _ -> Left (path ++ ": dependency '" ++ name ++ "': expected 'path', or 'git' with 'rev'")

    isFullRev r = length r == 40 && all isHexDigit' r
    isHexDigit' c = isDigit c || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')

    readNative t
      = do pc  <- optStrings t ["native","pkg-config"] [] "native.pkg-config"
           lbs <- optStrings t ["native","libs"] [] "native.libs"
           inc <- optStrings t ["native","include-dirs"] [] "native.include-dirs"
           return (NativeDeps pc lbs inc)

    readTargets t
      = do let mainv = tomlLookup t ["targets","app","main"] >>= tomlString
           tdirs <- optStrings t ["targets","test","directories"] ["test"] "targets.test.directories"
           return (Targets mainv tdirs)

-----------------------------------------------------------------------------
-- Compiler version constraints
-----------------------------------------------------------------------------

-- | Check a constraint like @">=3.2,<4"@ against the running compiler version.
-- Supported operators: @>=@, @>@, @<=@, @<@, @=@ (and a bare version, which
-- means @=@ on the given number of components).
checkKokaConstraint :: String -> String -> Either String ()
checkKokaConstraint constraint actual
  = mapM_ check (splitOn ',' constraint)
  where
    check raw
      = let c = trim raw
        in if null c then Right () else
           let (op,rest) = splitOp c
               want      = parseVersion (trim rest)
               have      = parseVersion actual
               cmp       = compareVersions have want
           in if satisfies op cmp
                then Right ()
                else Left ("this project requires koka " ++ trim constraint
                             ++ " but the compiler is " ++ actual)

    splitOp s
      | ">=" `isPrefixOf` s = (">=", drop 2 s)
      | "<=" `isPrefixOf` s = ("<=", drop 2 s)
      | "==" `isPrefixOf` s = ("=",  drop 2 s)
      | ">"  `isPrefixOf` s = (">",  drop 1 s)
      | "<"  `isPrefixOf` s = ("<",  drop 1 s)
      | "="  `isPrefixOf` s = ("=",  drop 1 s)
      | otherwise           = ("=",  s)

    satisfies op c
      = case op of
          ">=" -> c >= EQ
          ">"  -> c == GT
          "<=" -> c <= EQ
          "<"  -> c == LT
          _    -> c == EQ

-- | Split a dotted version into numeric components; non-numeric trailing parts
-- (like @-rc1@) are ignored.
parseVersion :: String -> [Int]
parseVersion s
  = map component (splitOn '.' s)
  where
    component p = case span isDigit p of
                    ("",_)  -> 0
                    (ds,_)  -> read ds

-- | Compare versions, padding the shorter one with zeros so that @3.2@ and
-- @3.2.7@ compare as equal on the components that were given.  The comparison
-- is truncated to the length of the constraint so that @">=3.2"@ accepts
-- @3.2.7@ and @"=3.2"@ accepts any @3.2.x@.
compareVersions :: [Int] -> [Int] -> Ordering
compareVersions have want
  = compare (take n (have ++ repeat 0)) (take n (want ++ repeat 0))
  where n = length want

splitOn :: Char -> String -> [String]
splitOn c s
  = case break (== c) s of
      (a,[])     -> [a]
      (a,_:rest) -> a : splitOn c rest

trim :: String -> String
trim = dropWhile isSpace . reverse . dropWhile isSpace . reverse

-----------------------------------------------------------------------------
-- Scaffolding
-----------------------------------------------------------------------------

-- | The manifest written by `koka init`.
defaultManifestText :: String -> String -> String
defaultManifestText name kokaVersion
  = unlines
      [ "[package]"
      , "name = " ++ show name
      , "version = \"0.1.0\""
      , "koka = " ++ show (">=" ++ majorMinor kokaVersion ++ ",<" ++ show (nextMajor kokaVersion))
      , ""
      , "[sources]"
      , "directories = [\"src\"]"
      , ""
      , "[dependencies]"
      , "# name = { path = \"../some-package\" }"
      , "# name = { git = \"ssh://git@github.com/you/repo.git\", rev = \"<40-char commit>\" }"
      , ""
      , "[targets.app]"
      , "main = \"src/main.kk\""
      , ""
      , "[targets.test]"
      , "directories = [\"test\"]"
      ]
  where
    majorMinor v = case parseVersion v of
                     (a:b:_) -> show a ++ "." ++ show b
                     (a:_)   -> show a ++ ".0"
                     _       -> "0.0"
    nextMajor v  = case parseVersion v of
                     (a:_) -> a + 1
                     _     -> 1
