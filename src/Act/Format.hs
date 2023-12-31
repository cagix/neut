module Act.Format (format) where

import Context.App
import Context.Parse qualified as Parse
import Entity.Config.Format
import Path.IO
import Scene.Format qualified as Format
import Scene.Initialize qualified as Initialize
import Scene.Write qualified as Write

format :: Config -> App ()
format cfg = do
  Initialize.initializeCompiler (remarkCfg cfg) Nothing
  Initialize.initializeForTarget
  path <- resolveFile' $ filePathString cfg
  content <- Format.format (inputFileType cfg) path
  if mustUpdateInPlace cfg
    then Write.write path content
    else Parse.printSourceFile content
