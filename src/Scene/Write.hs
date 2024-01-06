module Scene.Write (write) where

import Context.App
import Context.Parse
import Data.Text qualified as T
import Path
import Prelude hiding (log)

write :: Path Abs File -> T.Text -> App ()
write path content = do
  writeTextFile path content
