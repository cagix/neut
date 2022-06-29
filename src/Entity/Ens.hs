module Entity.Ens
  ( Ens,
    EnsF (..),
    toInt64,
    toFloat64,
    toBool,
    toString,
    toList,
    toDictionary,
    access,
    ppEns,
    ppEnsTopLevel,
  )
where

import Context.App
import qualified Context.Throw as Throw
import Control.Comonad.Cofree
import qualified Data.HashMap.Lazy as M
import Data.Int
import Data.List
import qualified Data.Text as T
import Entity.Hint

data EnsF a
  = EnsInt64 Int64
  | EnsFloat64 Double
  | EnsBool Bool
  | EnsString T.Text
  | EnsList [a]
  | EnsDictionary (M.HashMap T.Text a)

type Ens = Cofree EnsF Hint

data EnsType
  = EnsTypeInt64
  | EnsTypeFloat64
  | EnsTypeBool
  | EnsTypeString
  | EnsTypeList
  | EnsTypeDictionary

access :: Axis -> T.Text -> Ens -> IO Ens
access axis k entity@(m :< _) = do
  dictionary <- toDictionary axis entity
  case M.lookup k dictionary of
    Just v ->
      return v
    Nothing ->
      raiseKeyNotFoundError axis m k

toInt64 :: Axis -> Ens -> IO Int64
toInt64 axis entity@(m :< _) =
  case entity of
    _ :< EnsInt64 s ->
      return s
    _ ->
      raiseTypeError axis m EnsTypeInt64 (typeOf entity)

toFloat64 :: Axis -> Ens -> IO Double
toFloat64 axis entity@(m :< _) =
  case entity of
    _ :< EnsFloat64 s ->
      return s
    _ ->
      raiseTypeError axis m EnsTypeFloat64 (typeOf entity)

toBool :: Axis -> Ens -> IO Bool
toBool axis entity@(m :< _) =
  case entity of
    _ :< EnsBool x ->
      return x
    _ ->
      raiseTypeError axis m EnsTypeBool (typeOf entity)

toString :: Axis -> Ens -> IO T.Text
toString axis entity@(m :< _) =
  case entity of
    _ :< EnsString s ->
      return s
    _ ->
      raiseTypeError axis m EnsTypeString (typeOf entity)

toDictionary :: Axis -> Ens -> IO (M.HashMap T.Text Ens)
toDictionary axis entity@(m :< _) =
  case entity of
    _ :< EnsDictionary e ->
      return e
    _ ->
      raiseTypeError axis m EnsTypeDictionary (typeOf entity)

toList :: Axis -> Ens -> IO [Ens]
toList axis entity@(m :< _) =
  case entity of
    _ :< EnsList e ->
      return e
    _ ->
      raiseTypeError axis m EnsTypeList (typeOf entity)

typeOf :: Ens -> EnsType
typeOf v =
  case v of
    _ :< EnsInt64 _ ->
      EnsTypeInt64
    _ :< EnsFloat64 _ ->
      EnsTypeFloat64
    _ :< EnsBool _ ->
      EnsTypeBool
    _ :< EnsString _ ->
      EnsTypeString
    _ :< EnsList _ ->
      EnsTypeList
    _ :< EnsDictionary _ ->
      EnsTypeDictionary

showEnsType :: EnsType -> T.Text
showEnsType entityType =
  case entityType of
    EnsTypeInt64 ->
      "i64"
    EnsTypeFloat64 ->
      "f64"
    EnsTypeBool ->
      "bool"
    EnsTypeString ->
      "string"
    EnsTypeList ->
      "list"
    EnsTypeDictionary ->
      "dictionary"

raiseKeyNotFoundError :: Axis -> Hint -> T.Text -> IO a
raiseKeyNotFoundError axis m k =
  (axis & throw & Throw.raiseError) m $
    "couldn't find the required key `"
      <> k
      <> "`."

raiseTypeError :: Axis -> Hint -> EnsType -> EnsType -> IO a
raiseTypeError axis m expectedType actualType =
  (axis & throw & Throw.raiseError) m $
    "the value here is expected to be of type `"
      <> showEnsType expectedType
      <> "`, but is: `"
      <> showEnsType actualType
      <> "`"

showWithOffset :: Int -> T.Text -> T.Text
showWithOffset n text =
  T.replicate n "  " <> text

ppInt64 :: Int64 -> T.Text
ppInt64 i =
  T.pack (show i)

ppFloat64 :: Double -> T.Text
ppFloat64 i =
  T.pack (show i)

ppBool :: Bool -> T.Text
ppBool x =
  if x
    then "true"
    else "false"

ppString :: T.Text -> T.Text
ppString x =
  T.pack $ show x

ppList :: Int -> [Cofree EnsF a] -> T.Text
ppList n xs = do
  let header = "["
  let xs' = map (showWithOffset (n + 1) . ppEns (n + 1)) xs
  let footer = showWithOffset n "]"
  T.intercalate "\n" $ [header] <> xs' <> [footer]

ppDictionary :: Int -> M.HashMap T.Text (Cofree EnsF a) -> T.Text
ppDictionary n dict = do
  if M.size dict == 0
    then "{}"
    else do
      let header = "{"
      let dictList = sortOn fst $ M.toList dict
      let strList = map (uncurry $ ppDictionaryEntry (n + 1)) dictList
      let footer = showWithOffset n "}"
      T.intercalate "\n" $ [header] <> strList <> [footer]

ppDictionaryEntry :: Int -> T.Text -> Cofree EnsF a -> T.Text
ppDictionaryEntry n key value = do
  showWithOffset n $ key <> " = " <> ppEns n value

ppEns :: Int -> Cofree EnsF a -> T.Text
ppEns n entity = do
  case entity of
    _ :< EnsInt64 i ->
      ppInt64 i
    _ :< EnsFloat64 i ->
      ppFloat64 i
    _ :< EnsBool b ->
      ppBool b
    _ :< EnsString s ->
      ppString s
    _ :< EnsList xs -> do
      ppList n xs
    _ :< EnsDictionary dict -> do
      ppDictionary n dict

ppEnsTopLevel :: M.HashMap T.Text (Cofree EnsF a) -> T.Text
ppEnsTopLevel dict = do
  let dictList = sortOn fst $ M.toList dict
  let strList = map (uncurry $ ppDictionaryEntry 0) dictList
  T.intercalate "\n" strList <> "\n"
