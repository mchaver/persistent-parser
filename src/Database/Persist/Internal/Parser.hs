{-|
Module      : Database.Persist.Internal.Parser
Description : Persistent model file parsing functions
Copyright   : (c) James M.C. Haver II
License     : BSD3
Maintainer  : mchaver@gmail.com
Stability   : Beta
-}

{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Database.Persist.Internal.Parser where

import           Control.Applicative
import           Control.Monad

import           Data.Attoparsec.ByteString.Char8 (isSpace)
import           Data.Attoparsec.Combinator
import           Data.Attoparsec.Text

import           Data.List  (delete,nub)
import           Data.Maybe
import           Data.Monoid ((<>))
import           Data.Text (Text)
import qualified Data.Text as T

import           Database.Persist.Internal.Parser.Types

import           Prelude hiding (takeWhile)

import           Text.Read (readMaybe)


-- handling indented text appropriately

parseModelsFile :: Text -> Either String ModelsFile
parseModelsFile = parseOnly parseEntities

parseQuasiQuotersFile :: Text -> Either String ModelsFile
parseQuasiQuotersFile = parseOnly parsePersistQuasiQuoters


-- | Parse Persist Models that are in quasi-quoters. The source could be a haskell file.
parsePersistQuasiQuoters :: Parser ModelsFile
parsePersistQuasiQuoters = do
  _ <- manyTill' anyChar (string "[persistLowerCase|" <|> string "[persistUpperCase|")
  manyTill' ( ModelsFileEntity     <$> parseEntity
          <|> ModelsFileWhiteSpace <$> collectWhiteSpace
          <|> ModelsFileComment    <$> singleLineComment) (string "|]")

-- | Parse a Persist Models file.
parseEntities :: Parser ModelsFile
parseEntities = do
  many' ( ModelsFileEntity     <$> parseEntity
      <|> ModelsFileWhiteSpace <$> collectWhiteSpace
      <|> ModelsFileComment    <$> singleLineComment)

-- | Parse a single Persist Entity
parseEntity :: Parser Entity
parseEntity = do

  entityName <- haskellTypeNameWithoutPrefix
  _ <- many' spaceNoNewLine
  derivesJson <- (string "json" *> pure True) <|> pure False
  _ <- many' spaceNoNewLine
  mSqlTable <- (Just <$> parseEntitySqlTable) <|> pure Nothing
  _ <- takeTill isEndOfLine
  endOfLine <|> endOfInput

  entityChildren <- many' ( EntityChildEntityField   <$> parseEntityField
                        <|> EntityChildEntityDerive  <$> parseEntityDerive
                        <|> EntityChildEntityPrimary <$> parseEntityPrimary
                        <|> EntityChildEntityForeign <$> parseEntityForeign
                        <|> EntityChildEntityUnique  <$> parseEntityUnique
                        <|> EntityChildWhiteSpace    <$> collectWhiteSpace
                        <|> EntityChildComment       <$> singleLineComment)

  return $ Entity entityName derivesJson mSqlTable entityChildren


parseEntitySqlTable :: Parser Text
parseEntitySqlTable = do
  _ <- string "sql"
  _ <- many' spaceNoNewLine
  _ <- char '='
  _ <- many' spaceNoNewLine
  -- take while not space
  text <- many' (digit <|> letter <|> underline)
  return $ T.pack text

-- helper functions

-- | Wrap a Parser in 'Maybe' because it might fail. Useful for making choices.
maybeOption :: Parser a -> Parser (Maybe a)
maybeOption p = option Nothing (Just <$> p)

-- | Parse a lowercase 'Char'.
lowerCase :: Parser Char
lowerCase = satisfy (\c -> c >= 'a' && c <= 'z')

-- | Parse an uppercase 'Char'.
upperCase :: Parser Char
upperCase = satisfy (\c -> c >= 'A' && c <= 'Z')

-- | Parse an underline.
underline :: Parser Char
underline = satisfy (== '_')

-- | Parse strict marker "!" for haskellTypeName.
exclamationMark :: Parser Char
exclamationMark = satisfy (== '!')

-- | Parse lazy marker "~" for haskellTypeName.
tilde :: Parser Char
tilde = satisfy (== '~')


-- | Parse any space 'Char' excluding "\n".
spaceNoNewLine :: Parser Char
spaceNoNewLine = satisfy (\x -> isSpace x && not (isEndOfLine x)) <?> "spaceNoNewLine"

-- | Parse a Haskell function name. It starts with underscore or lowercase letter then
-- is followed by a combination of underscores, single quotes, letters and digits.
-- E.g., "get", "_get", "get_1", etc.
haskellFunctionName :: Parser Text
haskellFunctionName = do
  first <- lowerCase <|> underline
  rest  <- many' (digit <|> letter <|> underline)
  lookAhead ((space *> pure ()) <|> (char ']' *> pure ()) <|> endOfInput)
  return $ T.pack ([first] ++ rest)

-- | Parse a Haskell type name. It starts with an uppercase letter then
-- is followed by a combination of underscores, single quotes, letters and digits.
-- E.g., "Person", "Address", "PhoneNumber", etc.
haskellTypeName :: Parser Text
haskellTypeName = do
  _ <- (Just <$> exclamationMark) <|> (Just <$> tilde) <|> pure Nothing
  haskellTypeNameWithoutPrefix

haskellTypeNameWithoutPrefix :: Parser Text
haskellTypeNameWithoutPrefix = do
  first <- upperCase
  rest  <- many' (digit <|> letter <|> underline)
  -- check for ']' because it could be in a list
  lookAhead ((space *> pure ()) <|> (char ']' *> pure ())  <|> endOfInput)
  return $ T.pack ([first] ++ rest)



-- | Parse a comment that starts with "--".
singleLineComment :: Parser Comment
singleLineComment = do
  _ <- string "--"
  comment <- takeTill isEndOfLine
  endOfLine
  return $ Comment ("--" <> comment <> "\n")


collectWhiteSpace :: Parser WhiteSpace
collectWhiteSpace = do
  whiteSpace <- takeWhile (\x -> isSpace x && not (isEndOfLine x))
  endOfLine -- <|> endOfInput
  return $ WhiteSpace (whiteSpace <> "\n")



-- EntityName

parseEntityName :: Parser Text
parseEntityName = do
  name <- haskellTypeName
  _ <- takeTill isEndOfLine
  endOfLine <|> endOfInput
  return name

-- EntityField

parseEntityField :: Parser EntityField
parseEntityField = do
  efn <- parseEntityFieldName
  eft <- parseEntityFieldType

  ms <- parseMigrationOnlyAndSafeToRemove [] <|> pure []
  rs <- parseEntityFieldLastItem [] <|> pure []

  _ <- takeTill isEndOfLine
  endOfLine <|> endOfInput

  return $ EntityField efn
                       eft
                       (elem MigrationOnly ms)
                       (elem SafeToRemove ms)
                       (getFieldDefault rs)
                       (getFieldSqlRow  rs)
                       (getFieldSqlType rs)
                       (getFieldMaxLen  rs)


deleteItems :: (Eq a) => [a] -> [a] -> [a]
deleteItems (x:xs) ys = deleteItems xs $ delete x ys
deleteItems _ ys = nub ys

parseMigrationOnly :: Parser MigrationOnlyAndSafeToRemoveOption
parseMigrationOnly = string "MigrationOnly" *> pure MigrationOnly

parseSafeToRemove :: Parser MigrationOnlyAndSafeToRemoveOption
parseSafeToRemove  = string "SafeToRemove" *> pure SafeToRemove

getMigrationOnlyAndSafeToRemoveOption :: MigrationOnlyAndSafeToRemoveOption -> Parser MigrationOnlyAndSafeToRemoveOption
getMigrationOnlyAndSafeToRemoveOption MigrationOnly = parseMigrationOnly
getMigrationOnlyAndSafeToRemoveOption SafeToRemove  = parseSafeToRemove

parseMigrationOnlyAndSafeToRemove :: [MigrationOnlyAndSafeToRemoveOption] -> Parser [MigrationOnlyAndSafeToRemoveOption]
parseMigrationOnlyAndSafeToRemove parserOps = do
  _ <- many1 spaceNoNewLine
  let parsers = deleteItems parserOps [MigrationOnly,SafeToRemove]
  mResult <- (Just <$> choice (map getMigrationOnlyAndSafeToRemoveOption parsers)) <|> pure Nothing
  case mResult of
    Nothing -> return parserOps
    Just result -> parseMigrationOnlyAndSafeToRemove (parserOps ++ [result]) <|> pure (parserOps ++ [result])

getFieldDefault :: [EntityFieldLastItem] -> Maybe Text
getFieldDefault (x:xs) =
  case x of
    (FieldDefault y) -> Just y
    _ -> getFieldDefault xs
getFieldDefault _ = Nothing

getFieldSqlRow  :: [EntityFieldLastItem] -> Maybe Text
getFieldSqlRow (x:xs) =
  case x of
    (FieldSqlRow y) -> Just y
    _ -> getFieldSqlRow xs
getFieldSqlRow _ = Nothing

getFieldSqlType :: [EntityFieldLastItem] -> Maybe Text
getFieldSqlType (x:xs) =
  case x of
    (FieldSqlType y) -> Just y
    _                -> getFieldSqlType xs
getFieldSqlType _ = Nothing

getFieldMaxLen  :: [EntityFieldLastItem] -> Maybe Int
getFieldMaxLen (x:xs) =
  case x of
    (FieldMaxLen y) -> Just y
    _ -> getFieldMaxLen xs
getFieldMaxLen _ = Nothing


getEntityFieldLastItemParser :: EntityFieldLastItem -> Parser EntityFieldLastItem
getEntityFieldLastItemParser (FieldDefault  _) = parseFieldDefault
getEntityFieldLastItemParser (FieldSqlRow   _) = parseFieldSqlRow
getEntityFieldLastItemParser (FieldSqlType  _) = parseFieldSqlType
getEntityFieldLastItemParser (FieldMaxLen   _) = parseFieldMaxLen


parseFieldDefault :: Parser EntityFieldLastItem
parseFieldDefault = do
  _ <- string "default"
  _ <- many' spaceNoNewLine
  _ <- char '='
  _ <- many' spaceNoNewLine
  -- take while not space
  text <- many' (digit <|> letter <|> underline)
  return $ FieldDefault $ T.pack text


parseFieldSqlRow :: Parser EntityFieldLastItem
parseFieldSqlRow = do
  _ <- string "sql"
  _ <- many' spaceNoNewLine
  _ <- char '='
  _ <- many' spaceNoNewLine
  -- take while not space
  text <- many' (digit <|> letter <|> underline)
  return $ FieldSqlRow $ T.pack text

parseFieldSqlType :: Parser EntityFieldLastItem
parseFieldSqlType = do
  _ <- string "sqltype"
  _ <- many' spaceNoNewLine
  _ <- char '='
  _ <- many' spaceNoNewLine
  -- take while not space
  text <- many' (digit <|> letter <|> underline)
  return $ FieldSqlType $ T.pack text

parseFieldMaxLen :: Parser EntityFieldLastItem
parseFieldMaxLen = do
  _ <- string "maxlen"
  _ <- many' spaceNoNewLine
  _ <- char '='
  _ <- many' spaceNoNewLine
  -- take while not space
  intString <- many1 digit

  case readMaybe intString :: Maybe Int of
    Nothing -> fail "fieldMaxLen"
    Just int -> return $ FieldMaxLen int

parseEntityFieldLastItem :: [EntityFieldLastItem] -> Parser [EntityFieldLastItem]
parseEntityFieldLastItem parserOps = do
  _ <- many1 spaceNoNewLine
  let parsers = deleteItems parserOps [FieldDefault "", FieldSqlType "", FieldSqlRow "", FieldMaxLen 0]
  mResult <- (Just <$> choice (map getEntityFieldLastItemParser parsers)) <|> pure Nothing

  case mResult of
    Nothing -> return parserOps
    Just result -> parseEntityFieldLastItem (parserOps ++ [result]) <|> pure (parserOps ++ [result])


parseEntityFieldName :: Parser Text
parseEntityFieldName = do
  _ <- many1 spaceNoNewLine
  name <- haskellFunctionName

  case name == "deriving" of
    True -> fail "deriving"
    False -> return name

parseStrictness :: Parser Strictness
parseStrictness =
  (string "!" *> pure ExplicitStrict) <|> (string "~" *> pure Lazy) <|> pure Strict

parseEntityFieldType :: Parser EntityFieldType
parseEntityFieldType = do
  _ <- many1 spaceNoNewLine
  mLeftBracket <- maybeOption (char '[')
  strictness <- parseStrictness
  name <- haskellTypeName

  case mLeftBracket of
    Nothing -> do
      -- _ <- many' spaceNoNewLine
      -- mMaybe <- maybeOption (string "Maybe")
      mybe <- (parseMaybe *> pure True) <|> pure False
      return $ EntityFieldType name strictness False mybe
    Just _  -> do
      _ <- char ']'
      -- _ <- many' spaceNoNewLine
      -- mMaybe <- maybeOption (string "Maybe")
      mybe <- (parseMaybe *> pure True) <|> pure False
      return $ EntityFieldType name strictness True mybe


parseMaybe :: Parser ()
parseMaybe = do
  _ <- many1 spaceNoNewLine
  void $ string "Maybe"

-- EntityUnique

parseEntityUnique :: Parser EntityUnique
parseEntityUnique = do
  eun <- parseEntityUniqueName
  euefn <- parseEntityUniqueEntityFieldName
  _ <- takeTill isEndOfLine
  endOfLine <|> endOfInput

  return $ EntityUnique eun euefn

parseEntityUniqueName :: Parser Text
parseEntityUniqueName = do
  _ <- many1 spaceNoNewLine
  haskellTypeName

parseEntityUniqueEntityFieldName :: Parser [Text]
parseEntityUniqueEntityFieldName = do
  _ <- many1 spaceNoNewLine
  many1 haskellFunctionName


-- EntityDerive

parseEntityDerive :: Parser EntityDerive
parseEntityDerive = do
  _ <- many1 spaceNoNewLine
  _ <- string "deriving"
  -- _ <- many1 spaceNoNewLine
  names <- many1 (many1 spaceNoNewLine *> haskellTypeName)

  _ <- takeTill isEndOfLine
  endOfLine <|> endOfInput

  return $ EntityDerive names

parseEntityPrimary :: Parser EntityPrimary
parseEntityPrimary = do
  _ <- many1 spaceNoNewLine
  _ <- string "Primary"
  names <- many1 (many1 spaceNoNewLine *> haskellFunctionName)
  _ <- takeTill isEndOfLine
  endOfLine <|> endOfInput

  return $ EntityPrimary names

parseEntityForeign :: Parser EntityForeign
parseEntityForeign = do
  _ <- many1 spaceNoNewLine
  _ <- string "Foreign"
  _ <- many1 spaceNoNewLine
  foreignTable <- haskellTypeName
  names <- many1 (many1 spaceNoNewLine *> haskellFunctionName)

  _ <- takeTill isEndOfLine
  endOfLine <|> endOfInput

  return $ EntityForeign foreignTable names


parseForeignKeyType :: Parser () -- Text
parseForeignKeyType = void $ manyTill anyChar (string "Id" *> endOfInput)