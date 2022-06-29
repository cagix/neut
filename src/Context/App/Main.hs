module Context.App.Main
  ( new,
    Config (..),
  )
where

import Context.App
import qualified Context.Log.IO as Log
import qualified Context.Throw.IO as Throw
import Path
import Prelude hiding (log)

newtype Config = Config
  { mainFilePathConf :: Path Abs File
  }

new :: Log.Config -> Throw.Config -> IO Axis
new logCfg throwCfg = do
  logCtx <- Log.new logCfg
  throwCtx <- Throw.new throwCfg
  return
    Axis
      { log = logCtx,
        throw = throwCtx
      }
