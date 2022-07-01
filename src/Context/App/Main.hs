module Context.App.Main
  ( new,
    Config (..),
  )
where

import Context.App
import qualified Context.Gensym.Main as Gensym
import qualified Context.LLVM.Main as LLVM
import qualified Context.Log.IO as Log
import qualified Context.Throw.IO as Throw
import Path
import Prelude hiding (log)

newtype Config = Config
  { mainFilePathConf :: Path Abs File
  }

new :: Log.Config -> Throw.Config -> String -> IO Axis
new logCfg throwCfg clangOptStr = do
  logCtx <- Log.new logCfg
  throwCtx <- Throw.new throwCfg
  gensymCtx <- Gensym.new
  llvmCtx <- LLVM.new clangOptStr throwCtx
  return
    Axis
      { log = logCtx,
        throw = throwCtx,
        gensym = gensymCtx,
        llvm = llvmCtx
      }