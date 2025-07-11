module Command.FormatSource.Move.FormatSource
  ( Handle,
    new,
    format,
  )
where

import Command.Common.Move.Format qualified as Format
import CommandParser.Rule.Config.FormatSource
import Control.Monad.IO.Class (MonadIO (liftIO))
import Error.Rule.EIO (EIO)
import Kernel.Common.Move.CreateGlobalHandle qualified as Global
import Path.IO
import Path.Move.Read (isStdin, readTextFromPathOrStdin)
import Path.Move.Write (printText, writeText)

newtype Handle = Handle
  { globalHandle :: Global.Handle
  }

new :: Global.Handle -> Handle
new globalHandle = do
  Handle {..}

format :: Handle -> Config -> EIO ()
format h cfg = do
  path <- resolveFile' (filePathString cfg)
  content <- readTextFromPathOrStdin path
  let formatHandle = Format.new (globalHandle h)
  content' <- Format.formatSource formatHandle (shouldMinimizeImports cfg) path content
  if mustUpdateInPlace cfg && not (isStdin path)
    then liftIO $ writeText path content'
    else liftIO $ printText content'
