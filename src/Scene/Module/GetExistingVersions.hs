module Scene.Module.GetExistingVersions (getExistingVersions) where

import Context.App
import Context.Path (getBaseName)
import Data.List
import Data.Maybe
import Entity.Module
import Entity.PackageVersion qualified as PV
import Path.IO

getExistingVersions :: Module -> App [PV.PackageVersion]
getExistingVersions targetModule = do
  let archiveDir = getArchiveDir targetModule
  b <- doesDirExist archiveDir
  if not b
    then return []
    else do
      (_, archiveFiles) <- listDir archiveDir
      basenameList <- mapM getBaseName archiveFiles
      return $ sort $ mapMaybe PV.reflect basenameList
