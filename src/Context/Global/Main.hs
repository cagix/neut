module Context.Global.Main
  ( new,
  )
where

import qualified Context.Global as Global
import qualified Context.Throw as Throw
import Control.Monad
import Data.IORef
import qualified Data.Set as S
import qualified Data.Text as T
import Entity.Hint hiding (new)

type NameSet = S.Set T.Text

new :: Throw.Context -> IO Global.Axis
new axis = do
  topNameSetRef <- newIORef S.empty
  return
    Global.Axis
      { Global.register = register axis topNameSetRef,
        Global.isDefined = isDefined topNameSetRef
      }

register ::
  Throw.Context ->
  IORef NameSet ->
  Hint ->
  T.Text ->
  IO ()
register axis topNameSetRef m topLevelName = do
  topNameSet <- readIORef topNameSetRef
  when (S.member topLevelName topNameSet) $
    Throw.raiseError axis m $ "`" <> topLevelName <> "` is already defined at the top level"
  modifyIORef' topNameSetRef $ S.insert topLevelName

-- registerPrivate ::
--   Throw.Context ->
--   IORef NameSet ->
--   IORef NameSet ->
--   Hint ->
--   T.Text ->
--   IO ()
-- registerPrivate axis topNameSetRef privateNameSetRef m topLevelName = do
--   modifyIORef' privateNameSetRef $ S.insert topLevelName
--   register axis topNameSetRef m topLevelName

isDefined :: IORef NameSet -> T.Text -> IO Bool
isDefined topNameSetRef name = do
  topNameSet <- readIORef topNameSetRef
  return $ S.member name topNameSet

-- checkIfPrivate :: IORef Bool -> IO Bool
-- checkIfPrivate = do
--   isPrivateStack <- readIORef isPrivateStackRef
--   if null isPrivateStack
--     then return False
--     else return $ head isPrivateStack