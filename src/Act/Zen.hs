module Act.Zen (zen) where

import Context.App
import Context.Env qualified as Env
import Context.Path qualified as Path
import Control.Monad
import Data.Maybe
import Entity.ClangOption qualified as CL
import Entity.Config.Zen
import Entity.Module (Module (moduleZenConfig))
import Entity.OutputKind
import Entity.Target
import Entity.ZenConfig qualified as Z
import Path.IO (resolveFile')
import Scene.Build (Axis (..), buildTarget)
import Scene.Fetch qualified as Fetch
import Scene.Initialize qualified as Initialize
import Prelude hiding (log)

zen :: Config -> App ()
zen cfg = do
  setup cfg
  path <- resolveFile' (filePathString cfg)
  mainModule <- Env.getMainModule
  let zenConfig = Z.clangOption $ moduleZenConfig mainModule
  buildTarget (fromConfig cfg) mainModule $
    Main (Zen path (CL.compileOption zenConfig) (CL.linkOption zenConfig))

fromConfig :: Config -> Axis
fromConfig cfg =
  Axis
    { _outputKindList = [Object],
      _shouldSkipLink = False,
      _shouldExecute = True,
      _installDir = Nothing,
      _executeArgs = args cfg
    }

setup :: Config -> App ()
setup cfg = do
  Path.ensureNotInLibDir
  Initialize.initializeCompiler (remarkCfg cfg)
  Env.setBuildMode $ buildMode cfg
  Env.getMainModule >>= Fetch.fetch
