module Scene.Parse.Module
  ( initializeMainModule,
    parse,
  )
where

import Control.Monad
import qualified Data.Text as T
import Entity.Ens
import Entity.Log
import Entity.Module
import Entity.ModuleChecksum
import Entity.ModuleURL
import Path
import Path.IO
import qualified Scene.Parse.Ens as E

parse :: Path Abs File -> IO Module
parse moduleFilePath = do
  entity <- E.parse moduleFilePath
  entryPointEns <- access "target" entity >>= toDictionary
  dependencyEns <- access "dependency" entity >>= toDictionary
  extraContentsEns <- access "extra-content" entity >>= toList
  target <- mapM interpretRelFilePath entryPointEns
  dependency <- mapM interpretDependency dependencyEns
  extraContents <- mapM (interpretExtraPath $ parent moduleFilePath) extraContentsEns
  return
    Module
      { moduleTarget = target,
        moduleDependency = dependency,
        moduleExtraContents = extraContents,
        moduleLocation = moduleFilePath
      }

initializeMainModule :: IO ()
initializeMainModule = do
  getMainModuleFilePath >>= parse >>= setMainModule

interpretRelFilePath :: Ens -> IO (Path Rel File)
interpretRelFilePath =
  toString >=> parseRelFile . T.unpack

interpretDependency :: Ens -> IO (ModuleURL, ModuleChecksum)
interpretDependency dependencyValue = do
  url <- access "URL" dependencyValue >>= toString
  checksum <- access "checksum" dependencyValue >>= toString
  return (ModuleURL url, ModuleChecksum checksum)

interpretExtraPath :: Path Abs Dir -> Ens -> IO SomePath
interpretExtraPath moduleRootDir entity = do
  itemPathText <- toString entity
  if T.last itemPathText == '/'
    then do
      dirPath <- resolveDir moduleRootDir $ T.unpack itemPathText
      ensureExistence moduleRootDir dirPath doesDirExist "directory"
      return $ Left dirPath
    else do
      filePath <- resolveFile moduleRootDir $ T.unpack itemPathText
      ensureExistence moduleRootDir filePath doesFileExist "file"
      return $ Right filePath

ensureExistence :: Path Abs Dir -> Path Abs t -> (Path Abs t -> IO Bool) -> T.Text -> IO ()
ensureExistence moduleRootDir path existenceChecker kindText = do
  b <- existenceChecker path
  unless b $ do
    relPathFromModuleRoot <- stripProperPrefix moduleRootDir path
    raiseError' $ "no such " <> kindText <> " exists: " <> T.pack (toFilePath relPathFromModuleRoot)

getMainModuleFilePath :: IO (Path Abs File)
getMainModuleFilePath =
  getCurrentDir >>= findModuleFile
