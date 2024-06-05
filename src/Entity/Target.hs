module Entity.Target where

import Data.Hashable
import Data.Text qualified as T
import Entity.BaseName qualified as BN
import Entity.ClangOption qualified as CL
import Entity.SourceLocator qualified as SL
import GHC.Generics (Generic)
import Path

data Target
  = Main MainTarget
  | Peripheral
  | PeripheralSingle (Path Abs File)
  deriving (Show, Eq, Generic)

data TargetSummary = TargetSummary
  { entryPoint :: SL.SourceLocator,
    clangOption :: CL.ClangOption
  }
  deriving (Show, Eq, Generic)

data MainTarget
  = Named T.Text TargetSummary
  | Zen (Path Abs File) [T.Text] [T.Text]
  deriving (Show, Eq, Generic)

instance Hashable Target

instance Hashable TargetSummary

instance Hashable MainTarget

emptyZen :: Path Abs File -> MainTarget
emptyZen path =
  Zen path [] []

getEntryPointName :: MainTarget -> BN.BaseName
getEntryPointName target =
  case target of
    Named {} ->
      BN.mainName
    Zen {} ->
      BN.zenName

getCompileOption :: Target -> [String]
getCompileOption target =
  case target of
    Peripheral {} ->
      []
    PeripheralSingle {} ->
      []
    Main c ->
      case c of
        Named _ targetSummary -> do
          map T.unpack $ CL.compileOption (clangOption targetSummary)
        Zen _ compileOption _ ->
          map T.unpack compileOption

getLinkOption :: Target -> [String]
getLinkOption target =
  case target of
    Peripheral {} ->
      []
    PeripheralSingle {} ->
      []
    Main c ->
      case c of
        Named _ targetSummary ->
          map T.unpack $ CL.linkOption (clangOption targetSummary)
        Zen _ _ linkOption ->
          map T.unpack linkOption
