module Entity.PrimType.FromText (fromDefiniteDescription, fromText) where

import Data.Text qualified as T
import Entity.BaseName qualified as BN
import Entity.DataSize qualified as DS
import Entity.DefiniteDescription qualified as DD
import Entity.LocalLocator qualified as LL
import Entity.PrimNumSize
import Entity.PrimType qualified as PT
import Entity.StrictGlobalLocator qualified as SGL
import Text.Read

fromDefiniteDescription :: DS.DataSize -> DD.DefiniteDescription -> Maybe PT.PrimType
fromDefiniteDescription dataSize dd = do
  let sgl = DD.globalLocator dd
  let ll = DD.localLocator dd
  if SGL.llvmGlobalLocator /= sgl
    then Nothing
    else fromText dataSize $ BN.reify $ LL.baseName ll

fromText :: DS.DataSize -> T.Text -> Maybe PT.PrimType
fromText dataSize name
  | Just intSize <- asLowInt dataSize name =
      Just $ PT.Int intSize
  | Just floatSize <- asLowFloat dataSize name =
      Just $ PT.Float floatSize
  | otherwise =
      Nothing

intTypeName :: T.Text
intTypeName = "int"

asLowInt :: DS.DataSize -> T.Text -> Maybe IntSize
asLowInt dataSize s =
  if s == intTypeName
    then Just $ dataSizeToIntSize dataSize
    else do
      case T.splitAt 3 s of
        ("", "") ->
          Nothing
        (c, rest)
          | c == intTypeName,
            Just n <- readMaybe $ T.unpack rest,
            Just size <- asIntSize dataSize n ->
              Just size
          | otherwise ->
              Nothing

floatTypeName :: T.Text
floatTypeName = "float"

asLowFloat :: DS.DataSize -> T.Text -> Maybe FloatSize
asLowFloat dataSize s =
  if s == floatTypeName
    then Just $ dataSizeToFloatSize dataSize
    else do
      case T.splitAt 5 s of
        ("", "") ->
          Nothing
        (c, rest)
          | c == floatTypeName,
            Just n <- readMaybe $ T.unpack rest,
            Just size <- asFloatSize dataSize n ->
              Just size
          | otherwise ->
              Nothing

asIntSize :: DS.DataSize -> Int -> Maybe IntSize
asIntSize dataSize size =
  if 1 <= size && size <= DS.reify dataSize
    then Just $ IntSize size
    else Nothing

asFloatSize :: DS.DataSize -> Int -> Maybe FloatSize
asFloatSize dataSize size =
  if size > DS.reify dataSize
    then Nothing
    else case size of
      16 ->
        Just FloatSize16
      32 ->
        Just FloatSize32
      64 ->
        Just FloatSize64
      _ ->
        Nothing

dataSizeToFloatSize :: DS.DataSize -> FloatSize
dataSizeToFloatSize dataSize =
  case dataSize of
    DS.DataSize64 ->
      FloatSize64

dataSizeToIntSize :: DS.DataSize -> IntSize
dataSizeToIntSize dataSize =
  IntSize $ DS.reify dataSize
