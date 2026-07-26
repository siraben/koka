-----------------------------------------------------------------------------
-- A deliberately small TOML reader for `koka.toml` project manifests.
--
-- Supports exactly the subset the manifest schema uses:
--
--   * comments (`# ...`)
--   * table headers `[a]` and `[a.b]`
--   * key/value pairs where a key is a bare word or a quoted string
--   * values: basic strings, integers, booleans, arrays, inline tables
--   * trailing commas in arrays and inline tables
--
-- Deliberately *not* supported (and rejected with a position): array-of-tables
-- (`[[x]]`), multi-line strings, literal strings, floats, dates, dotted keys
-- outside of table headers.  Keeping the reader small keeps manifest errors
-- easy to explain; the schema does not need the rest of TOML.
-----------------------------------------------------------------------------
module Compile.Project.Toml
  ( TomlValue(..)
  , TomlTable
  , parseToml
  , tomlLookup
  , tomlString
  , tomlStringList
  , tomlTable
  , tomlKeys
  ) where

import Data.Char        ( isAlphaNum, isDigit )
import Data.List        ( intercalate )
import Text.Parsec
import Text.Parsec.String ( Parser )

-----------------------------------------------------------------------------
-- Values
-----------------------------------------------------------------------------

data TomlValue
  = TomlString  String
  | TomlInt     Integer
  | TomlBool    Bool
  | TomlArray   [TomlValue]
  | TomlTableV  TomlTable
  deriving (Eq, Show)

-- | Key/value pairs in source order.  Order is preserved so that error
-- messages and any regenerated output follow the file.
type TomlTable = [(String, TomlValue)]

-----------------------------------------------------------------------------
-- Accessors
-----------------------------------------------------------------------------

-- | Look up a dotted path, e.g. @["package","name"]@.
tomlLookup :: TomlTable -> [String] -> Maybe TomlValue
tomlLookup tbl [] = Just (TomlTableV tbl)
tomlLookup tbl (k:ks)
  = case lookup k tbl of
      Nothing -> Nothing
      Just v | null ks -> Just v
      Just (TomlTableV t) -> tomlLookup t ks
      Just _ -> Nothing

tomlString :: TomlValue -> Maybe String
tomlString (TomlString s) = Just s
tomlString _              = Nothing

tomlStringList :: TomlValue -> Maybe [String]
tomlStringList (TomlArray vs) = mapM tomlString vs
tomlStringList _              = Nothing

tomlTable :: TomlValue -> Maybe TomlTable
tomlTable (TomlTableV t) = Just t
tomlTable _              = Nothing

tomlKeys :: TomlTable -> [String]
tomlKeys = map fst

-----------------------------------------------------------------------------
-- Parser
-----------------------------------------------------------------------------

-- | Parse a manifest.  On failure the message includes line and column.
parseToml :: FilePath -> String -> Either String TomlTable
parseToml fname input
  = case parse pDocument fname input of
      Left err  -> Left (show err)
      Right tbl -> Right tbl

pDocument :: Parser TomlTable
pDocument
  = do skipTrivia
       top     <- many (pPair <* skipTrivia)
       tables  <- many (pTableSection <* skipTrivia)
       eof
       return (top ++ mergeSections tables)

-- Table headers are dotted paths; nest them into a tree so that
-- `[targets.app]` becomes targets -> app -> {...}.
mergeSections :: [([String],TomlTable)] -> TomlTable
mergeSections = foldl insertSection []
  where
    insertSection acc (path,tbl) = insertAt acc path tbl

    insertAt acc [] tbl = acc ++ tbl
    insertAt acc [k] tbl
      = case lookup k acc of
          Just (TomlTableV existing) -> replace acc k (TomlTableV (existing ++ tbl))
          _                          -> acc ++ [(k, TomlTableV tbl)]
    insertAt acc (k:ks) tbl
      = case lookup k acc of
          Just (TomlTableV existing) -> replace acc k (TomlTableV (insertAt existing ks tbl))
          _                          -> acc ++ [(k, TomlTableV (insertAt [] ks tbl))]

    replace acc k v = map (\(k',v') -> if k' == k then (k,v) else (k',v')) acc

pTableSection :: Parser ([String],TomlTable)
pTableSection
  = do _    <- char '['
       notFollowedBy (char '[') <?> "a table header (array-of-tables is not supported)"
       skipSpaces
       path <- pKey `sepBy1` (skipSpaces >> char '.' >> skipSpaces)
       skipSpaces
       _    <- char ']'
       skipTrivia
       pairs <- many (pPair <* skipTrivia)
       return (path,pairs)

pPair :: Parser (String,TomlValue)
pPair
  = do k <- pKey
       skipSpaces
       _ <- char '='
       skipSpaces
       v <- pValue
       return (k,v)

pKey :: Parser String
pKey
  = pQuoted <|> many1 (satisfy isBareKeyChar) <?> "a key"
  where
    isBareKeyChar c = isAlphaNum c || c == '_' || c == '-'

pValue :: Parser TomlValue
pValue
  =   (TomlString <$> pQuoted)
  <|> pArray
  <|> pInlineTable
  <|> pBool
  <|> pInt
  <?> "a value"

pBool :: Parser TomlValue
pBool
  =   (TomlBool True  <$ try (string "true"))
  <|> (TomlBool False <$ try (string "false"))

pInt :: Parser TomlValue
pInt
  = do sign   <- option "" (string "-" <|> string "+")
       digits <- many1 (satisfy (\c -> isDigit c || c == '_'))
       let ds = filter (/= '_') digits
       return (TomlInt (read (if sign == "-" then '-':ds else ds)))

pArray :: Parser TomlValue
pArray
  = do _  <- char '['
       skipTrivia
       vs <- pValue `sepEndBy` (skipTrivia >> char ',' >> skipTrivia)
       skipTrivia
       _  <- char ']'
       return (TomlArray vs)

pInlineTable :: Parser TomlValue
pInlineTable
  = do _  <- char '{'
       skipTrivia
       ps <- pPair `sepEndBy` (skipTrivia >> char ',' >> skipTrivia)
       skipTrivia
       _  <- char '}'
       return (TomlTableV ps)

pQuoted :: Parser String
pQuoted
  = do _  <- char '"'
       cs <- many pStringChar
       _  <- char '"'
       return cs
  where
    pStringChar
      =   (char '\\' >> pEscape)
      <|> satisfy (\c -> c /= '"' && c /= '\\' && c /= '\n')

    pEscape
      =   ('"'  <$ char '"')
      <|> ('\\' <$ char '\\')
      <|> ('\n' <$ char 'n')
      <|> ('\t' <$ char 't')
      <|> ('\r' <$ char 'r')
      <?> "a string escape (\\\" \\\\ \\n \\t \\r)"

-- Spaces on the current line only.
skipSpaces :: Parser ()
skipSpaces = skipMany (oneOf " \t")

-- Spaces, newlines and comments.
skipTrivia :: Parser ()
skipTrivia = skipMany (void (oneOf " \t\r\n") <|> pComment)
  where
    pComment = do _ <- char '#'
                  skipMany (satisfy (/= '\n'))
    void p   = p >> return ()
