{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TypeSynonymInstances #-}

module Data.Basic where

import Control.Comonad.Cofree (Cofree (..))
import Data.Binary (Binary)
import Data.Functor.Classes
import qualified Data.Text as T
import GHC.Generics (Generic)
import Path (Abs, File, Path, parseAbsFile)
import System.Environment (getExecutablePath)

newtype Ident
  = I (T.Text, Int)
  deriving (Eq, Ord, Generic)

instance Show Ident where
  show (I (s, i)) =
    T.unpack s ++ "-" ++ show i

instance Binary Ident

type Line =
  Int

type Column =
  Int

type Loc =
  (Line, Column)

data Hint = Hint
  { metaFileName :: FilePath,
    metaLocation :: Loc
  }
  deriving (Generic)

instance Binary Hint

type PosInfo =
  (FilePath, Loc)

instance Show Hint where
  show _ =
    "_"

instance Eq Hint where
  _ == _ = True

data EnumCaseF a
  = EnumCaseLabel T.Text
  | EnumCaseInt Int
  | EnumCaseDefault
  deriving (Show, Eq, Ord, Generic)

instance Functor EnumCaseF where
  fmap _ v =
    case v of
      EnumCaseLabel label ->
        EnumCaseLabel label
      EnumCaseInt i ->
        EnumCaseInt i
      EnumCaseDefault ->
        EnumCaseDefault

instance Eq1 EnumCaseF where
  liftEq _ v1 v2 =
    case (v1, v2) of
      (EnumCaseLabel l1, EnumCaseLabel l2)
        | l1 == l2 ->
          True
      (EnumCaseInt i1, EnumCaseInt i2)
        | i1 == i2 ->
          True
      (EnumCaseDefault, EnumCaseDefault) ->
        False
      _ ->
        False

instance Show1 EnumCaseF where
  liftShowsPrec _ _ _ someValue =
    case someValue of
      EnumCaseLabel label ->
        showString $ T.unpack label
      EnumCaseInt i ->
        showString $ show i
      EnumCaseDefault ->
        showString "default"

instance (Binary a) => Binary (EnumCaseF a)

type EnumCase =
  Cofree EnumCaseF Hint

type CompEnumCase =
  Cofree EnumCaseF ()

instance Binary EnumCase

-- instance Show EnumCase

data Opacity
  = OpacityOpaque
  | OpacityTranslucent
  | OpacityTransparent
  deriving (Show, Eq, Generic)

instance Binary Opacity

data LamKind a
  = LamKindNormal
  | LamKindCons T.Text T.Text
  | LamKindFix a
  | LamKindResourceHandler
  deriving (Show, Generic)

instance (Binary a) => Binary (LamKind a)

type IsReducible =
  Bool

isOpaque :: Opacity -> Bool
isOpaque o =
  case o of
    OpacityOpaque ->
      True
    _ ->
      False

isTransparent :: Opacity -> Bool
isTransparent o =
  case o of
    OpacityTransparent ->
      True
    _ ->
      False

fromLamKind :: LamKind a -> Maybe a
fromLamKind k =
  case k of
    LamKindFix x ->
      Just x
    _ ->
      Nothing

lamKindWeakEq :: LamKind a -> LamKind a -> Bool
lamKindWeakEq k1 k2 =
  case (k1, k2) of
    (LamKindNormal, LamKindNormal) ->
      True
    (LamKindCons t11 t12, LamKindCons t21 t22) ->
      t11 == t21 && t12 == t22
    _ ->
      False

asText :: Ident -> T.Text
asText (I (s, _)) =
  s

{-# INLINE asText' #-}
asText' :: Ident -> T.Text
asText' (I (s, i)) =
  s <> "-" <> T.pack (show i)

asText'' :: Ident -> T.Text
asText'' (I (_, i)) =
  "_" <> T.pack (show i)

asIdent :: T.Text -> Ident
asIdent s =
  I (s, 0)

asInt :: Ident -> Int
asInt (I (_, i)) =
  i

showHint :: Hint -> String
showHint m = do
  let name = metaFileName m
  let (l, c) = metaLocation m
  name ++ ":" ++ show l ++ ":" ++ show c

newHint :: Int -> Int -> FilePath -> Hint
newHint l c path =
  Hint
    { metaFileName = path,
      metaLocation = (l, c)
    }

getPosInfo :: Hint -> PosInfo
getPosInfo m =
  (metaFileName m, metaLocation m)

showPosInfo :: FilePath -> Loc -> String
showPosInfo path (l, c) =
  path ++ ":" ++ show l ++ ":" ++ show c

getExecPath :: IO (Path Abs File)
getExecPath =
  getExecutablePath >>= parseAbsFile
