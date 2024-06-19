module Scene.Install (install) where

import Context.App
import Context.Env qualified as Env
import Context.Path qualified as Path
import Control.Monad
import Data.Text qualified as T
import Entity.Target qualified as Target
import Path
import Path.IO
import Prelude hiding (log)

install :: Target.MainTarget -> Path Abs Dir -> App ()
install targetOrZen dir = do
  execPath <- Env.getMainModule >>= Path.getExecutableOutputPath targetOrZen
  case targetOrZen of
    Target.Named targetName _ -> do
      execName <- parseRelFile $ T.unpack targetName
      let destPath = dir </> execName
      copyFile execPath destPath
    Target.Zen {} ->
      return ()
