module Entity.WeakPrim where

import Data.Binary
import qualified Entity.PrimType as PT
import qualified Entity.WeakPrimValue as PV
import qualified GHC.Generics as G

data WeakPrim a
  = Type PT.PrimType
  | Value (PV.WeakPrimValue a)
  deriving (Show, G.Generic)

instance (Binary a) => Binary (WeakPrim a)

instance Functor WeakPrim where
  fmap f prim =
    case prim of
      Value primValue ->
        Value (fmap f primValue)
      Type primType ->
        Type primType

instance Foldable WeakPrim where
  foldMap f prim =
    case prim of
      Value primValue ->
        foldMap f primValue
      Type _ ->
        mempty

instance Traversable WeakPrim where
  traverse f prim =
    case prim of
      Value primValue ->
        Value <$> traverse f primValue
      Type primType ->
        pure (Type primType)