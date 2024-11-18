module Entity.DeclarationName where

import Data.ByteString.Builder
import Data.HashMap.Strict qualified as Map
import Data.Hashable
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Entity.BaseLowType
import Entity.DefiniteDescription qualified as DD
import Entity.ExternalName qualified as EN
import Entity.ForeignCodType qualified as F
import GHC.Generics

data DeclarationName
  = In DD.DefiniteDescription
  | Ext EN.ExternalName
  deriving (Eq, Ord, Show, Generic)

instance Hashable DeclarationName

type DeclEnv = Map.HashMap DeclarationName ([BaseLowType], F.ForeignCodType BaseLowType)

malloc :: DeclarationName
malloc =
  Ext EN.malloc

free :: DeclarationName
free =
  Ext EN.free

toBuilder :: DeclarationName -> Builder
toBuilder dn =
  case dn of
    In dd ->
      DD.toBuilder dd
    Ext (EN.ExternalName rawTxt) ->
      TE.encodeUtf8Builder rawTxt

reify :: DeclarationName -> T.Text
reify dn =
  case dn of
    In dd ->
      DD.reify dd
    Ext (EN.ExternalName rawTxt) ->
      rawTxt
