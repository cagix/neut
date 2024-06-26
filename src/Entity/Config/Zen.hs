module Entity.Config.Zen (Config (..)) where

import Entity.BuildMode
import Entity.Config.Remark qualified as Remark

data Config = Config
  { filePathString :: FilePath,
    remarkCfg :: Remark.Config,
    buildMode :: BuildMode,
    args :: [String]
  }
