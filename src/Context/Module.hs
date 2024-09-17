{-# LANGUAGE TemplateHaskell #-}

module Context.Module
  ( getLibraryDirPath,
    ensureNotInLibDir,
    getModuleFilePath,
    getModuleDirByID,
    getModuleCacheMap,
    getCoreModuleURL,
    getCoreModuleDigest,
    insertToModuleCacheMap,
    saveEns,
    sourceFromPath,
    getAllSourcePathInModule,
    getAllSourceInModule,
  )
where

import Context.App
import Context.App.Internal
import Context.Env
import Context.Path qualified as Path
import Context.Throw qualified as Throw
import Control.Monad
import Control.Monad.IO.Class
import Data.HashMap.Strict qualified as Map
import Data.Text qualified as T
import Entity.Const
import Entity.Ens
import Entity.Ens.Reify qualified as Ens
import Entity.Hint qualified as H
import Entity.Module
import Entity.ModuleDigest
import Entity.ModuleDigest qualified as MD
import Entity.ModuleID qualified as MID
import Entity.ModuleURL
import Entity.Source qualified as Source
import Path
import Path.IO
import System.Environment

returnDirectory :: Path Abs Dir -> App (Path Abs Dir)
returnDirectory path =
  ensureDir path >> return path

getCacheDirPath :: App (Path Abs Dir)
getCacheDirPath = do
  mCacheDirPathString <- liftIO $ lookupEnv envVarCacheDir
  case mCacheDirPathString of
    Just cacheDirPathString -> do
      parseAbsDir cacheDirPathString >>= returnDirectory
    Nothing ->
      getXdgDir XdgCache (Just $(mkRelDir "neut")) >>= returnDirectory

getLibraryDirPath :: App (Path Abs Dir)
getLibraryDirPath = do
  cacheDirPath <- getCacheDirPath
  returnDirectory $ cacheDirPath </> $(mkRelDir "library")

ensureNotInLibDir :: App ()
ensureNotInLibDir = do
  b <- inLibDir
  when b $
    Throw.raiseError'
      "This command cannot be used under the library directory"

inLibDir :: App Bool
inLibDir = do
  currentDir <- getCurrentDir
  libDir <- getLibraryDirPath
  return $ isProperPrefixOf libDir currentDir

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

getModuleDirByID :: Maybe H.Hint -> MID.ModuleID -> App (Path Abs Dir)
getModuleDirByID mHint moduleID = do
  mainModule <- getMainModule
  case moduleID of
    MID.Base -> do
      let message = "The base module cannot be used here"
      case mHint of
        Just hint ->
          Throw.raiseError hint message
        Nothing ->
          Throw.raiseError' message
    MID.Main ->
      return $ getModuleRootDir mainModule
    MID.Library (MD.ModuleDigest digest) -> do
      libraryDir <- getLibraryDirPath
      resolveDir libraryDir $ T.unpack digest

saveEns :: Path Abs File -> FullEns -> App ()
saveEns path (c1, (ens, c2)) = do
  ens' <- Throw.liftEither $ stylize ens
  Path.writeText path $ Ens.pp (c1, (ens', c2))

getCoreModuleURL :: App ModuleURL
getCoreModuleURL = do
  mCoreModuleURL <- liftIO $ lookupEnv envVarCoreModuleURL
  case mCoreModuleURL of
    Just coreModuleURL ->
      return $ ModuleURL $ T.pack coreModuleURL
    Nothing ->
      Throw.raiseError' $ "The URL of the core module is not specified; set it via " <> T.pack envVarCoreModuleURL

getCoreModuleDigest :: App ModuleDigest
getCoreModuleDigest = do
  mCoreModuleDigest <- liftIO $ lookupEnv envVarCoreModuleDigest
  case mCoreModuleDigest of
    Just coreModuleDigest ->
      return $ ModuleDigest $ T.pack coreModuleDigest
    Nothing ->
      Throw.raiseError' $ "The digest of the core module is not specified; set it via " <> T.pack envVarCoreModuleDigest

sourceFromPath :: Module -> Path Abs File -> App Source.Source
sourceFromPath baseModule path = do
  ensureFileModuleSanity path baseModule
  return $
    Source.Source
      { Source.sourceModule = baseModule,
        Source.sourceFilePath = path,
        Source.sourceHint = Nothing
      }

ensureFileModuleSanity :: Path Abs File -> Module -> App ()
ensureFileModuleSanity filePath mainModule = do
  unless (isProperPrefixOf (getSourceDir mainModule) filePath) $ do
    Throw.raiseError' $
      "The file `"
        <> T.pack (toFilePath filePath)
        <> "` is not in the source directory of current module"

getAllSourcePathInModule :: Module -> App [Path Abs File]
getAllSourcePathInModule baseModule = do
  (_, filePathList) <- listDirRecur (getSourceDir baseModule)
  return $ filter hasSourceExtension filePathList

getAllSourceInModule :: Module -> App [Source.Source]
getAllSourceInModule baseModule = do
  sourcePathList <- getAllSourcePathInModule baseModule
  mapM (sourceFromPath baseModule) sourcePathList

hasSourceExtension :: Path Abs File -> Bool
hasSourceExtension path =
  case splitExtension path of
    Just (_, ext)
      | ext == sourceFileExtension ->
          True
    _ ->
      False
