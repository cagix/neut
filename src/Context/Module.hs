module Context.Module
  ( getModuleFilePath,
    getSourcePath,
    getModuleDirByID,
    getMainModule,
    setMainModule,
    getModuleCacheMap,
    insertToModuleCacheMap,
  )
where

import Context.App
import Context.App.Internal
import Context.Path qualified as Path
import Context.Throw qualified as Throw
import Data.HashMap.Strict qualified as Map
import Data.Text qualified as T
import Entity.Const
import Entity.Hint qualified as H
import Entity.Module
import Entity.ModuleChecksum qualified as MC
import Entity.ModuleID qualified as MID
import Entity.SourceLocator qualified as SL
import Entity.StrictGlobalLocator qualified as SGL
import Path
import Path.IO

getMainModule :: App Module
getMainModule =
  readRef "mainModule" mainModule

setMainModule :: Module -> App ()
setMainModule =
  writeRef mainModule

getModuleFilePath :: Maybe H.Hint -> MID.ModuleID -> App (Path Abs File)
getModuleFilePath mHint moduleID = do
  moduleDir <- getModuleDirByID mHint moduleID
  return $ moduleDir </> moduleFile

getModuleCacheMap :: App (Map.HashMap (Path Abs File) Module)
getModuleCacheMap =
  readRef' moduleCacheMap

insertToModuleCacheMap :: Path Abs File -> Module -> App ()
insertToModuleCacheMap k v =
  modifyRef' moduleCacheMap $ Map.insert k v

getSourcePath :: SGL.StrictGlobalLocator -> App (Path Abs File)
getSourcePath sgl = do
  moduleDir <- getModuleDirByID Nothing $ SGL.moduleID sgl
  let relPath = SL.reify $ SGL.sourceLocator sgl
  return $ moduleDir </> sourceRelDir </> relPath

getModuleDirByID :: Maybe H.Hint -> MID.ModuleID -> App (Path Abs Dir)
getModuleDirByID mHint moduleID = do
  mainModule <- getMainModule
  case moduleID of
    MID.Base -> do
      let message = "the base module can't be used here"
      case mHint of
        Just hint ->
          Throw.raiseError hint message
        Nothing ->
          Throw.raiseError' message
    MID.Main ->
      return $ getModuleRootDir mainModule
    MID.Library (MC.ModuleChecksum checksum) -> do
      libraryDir <- Path.getLibraryDirPath
      resolveDir libraryDir $ T.unpack checksum
