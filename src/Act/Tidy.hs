module Act.Tidy (tidy) where

import Context.App
import Context.Module qualified as Module
import Context.Path qualified as Path
import Entity.Config.Tidy
import Scene.Fetch qualified as Fetch
import Scene.Initialize qualified as Initialize
import Prelude hiding (log)

tidy :: Config -> App ()
tidy cfg = do
  Initialize.initializeCompiler (remarkCfg cfg) Nothing
  Path.ensureNotInLibDir
  Module.getMainModule >>= Fetch.fetch
