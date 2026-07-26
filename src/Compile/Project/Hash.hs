-----------------------------------------------------------------------------
-- Content hashing for lockfile checksums and build-cache keys.
--
-- Uses SHA-256 from `cryptohash-sha256`; this program does not implement
-- cryptographic primitives itself.
--
-- Tree hashes are deterministic: entries are visited in sorted order by
-- POSIX-normalised relative path, and each entry contributes its path, its
-- length, and its bytes.  No timestamps, no inode data, no ordering that
-- depends on the file system.
-----------------------------------------------------------------------------
module Compile.Project.Hash
  ( hashBytes
  , hashString
  , hashStrings
  , hashTree
  , hashFiles
  , isIgnoredEntry
  ) where

import qualified Crypto.Hash.SHA256 as SHA256
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import qualified Data.ByteString.Base16 as B16

import Control.Monad      ( forM, filterM )
import Data.List          ( sort, isSuffixOf )
import System.Directory   ( doesDirectoryExist, doesFileExist, listDirectory
                          , pathIsSymbolicLink )
import System.FilePath    ( (</>) )

-- | Hex-encoded SHA-256 of a byte string.
hashBytes :: BS.ByteString -> String
hashBytes = BC.unpack . B16.encode . SHA256.hash

hashString :: String -> String
hashString = hashBytes . BC.pack

-- | Hash a list of strings unambiguously: each item is prefixed with its
-- length so that @["ab","c"]@ and @["a","bc"]@ hash differently.
hashStrings :: [String] -> String
hashStrings ss
  = hashBytes (BS.concat [ BC.pack (show (length s) ++ ":" ++ s) | s <- ss ])

-- | Directory entries that never contribute to a content hash: version
-- control metadata, build output, and editor droppings.  Excluding these is
-- what makes a checksum stable across machines.
isIgnoredEntry :: FilePath -> Bool
isIgnoredEntry name
  = name `elem`
      [ ".git", ".hg", ".svn"
      , ".koka", "kkbuild", ".stack-work", "dist-newstyle", "result"
      , ".direnv", "node_modules", "__pycache__"
      ]
  || (".swp" `isSuffixOf` name)
  || (name == ".DS_Store")

-- | Deterministic hash of a directory tree.  Symlinks are hashed by their
-- presence and target-independent path only (we do not follow them), which
-- keeps the hash stable without chasing cycles.
hashTree :: FilePath -> IO String
hashTree root
  = do files <- collect ""
       hashFiles root (sort files)
  where
    collect rel
      = do let dir = if null rel then root else root </> rel
           entries <- listDirectory dir
           fmap concat $ forM (sort entries) $ \e ->
             if isIgnoredEntry e
               then return []
               else do let relPath = if null rel then e else rel ++ "/" ++ e
                       let full    = root </> relPath
                       isLink <- pathIsSymbolicLink full
                       if isLink
                         then return [relPath]
                         else do isDir <- doesDirectoryExist full
                                 if isDir then collect relPath else return [relPath]

-- | Hash an explicit, already-sorted list of paths relative to @root@.
hashFiles :: FilePath -> [FilePath] -> IO String
hashFiles root rels
  = do ctx <- foldMMaybe SHA256.init rels
       return (BC.unpack (B16.encode (SHA256.finalize ctx)))
  where
    foldMMaybe ctx [] = return ctx
    foldMMaybe ctx (rel:rest)
      = do let full = root </> rel
           isFile <- doesFileExist full
           bytes  <- if isFile then BS.readFile full else return BS.empty
           let ctx' = SHA256.updates ctx
                        [ BC.pack (show (length rel) ++ ":" ++ rel ++ ":")
                        , BC.pack (show (BS.length bytes) ++ ":")
                        , bytes ]
           foldMMaybe ctx' rest
