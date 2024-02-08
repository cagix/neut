module Scene.Archive (archive) where

import Context.App
import Context.External qualified as External
import Context.Module qualified as Module
import Context.Path qualified as Path
import Context.Throw qualified as Throw
import Control.Monad
import Data.List
import Data.Text qualified as T
import Entity.Const
import Entity.Ens qualified as E
import Entity.Module
import Entity.PackageVersion qualified as PV
import Path
import Path.IO (copyDirRecur, copyFile, listDirRecurRel, withSystemTempDir)
import Prelude hiding (log)

archive :: PV.PackageVersion -> E.FullEns -> Path Abs Dir -> [SomePath Rel] -> App ()
archive packageVersion fullEns moduleRootDir contents = do
  withSystemTempDir "archive" $ \tempRootDir -> do
    Module.saveEns (tempRootDir </> moduleFile) fullEns
    copyModuleContents tempRootDir moduleRootDir contents
    makeArchiveFromTempDir packageVersion tempRootDir

makeArchiveFromTempDir :: PV.PackageVersion -> Path Abs Dir -> App ()
makeArchiveFromTempDir packageVersion tempRootDir = do
  (_, files) <- listDirRecurRel tempRootDir
  let newContents = map toFilePath files
  mainModule <- Module.getMainModule
  outputPath <- toFilePath <$> getArchiveFilePath mainModule (PV.reify packageVersion)
  External.run "tar" $ ["-c", "--zstd", "-f", outputPath, "-C", toFilePath tempRootDir] ++ newContents

copyModuleContents :: Path Abs Dir -> Path Abs Dir -> [SomePath Rel] -> App ()
copyModuleContents tempRootDir moduleRootDir contents = do
  forM_ contents $ \content -> do
    case content of
      Left dirPath -> do
        copyDirRecur (moduleRootDir </> dirPath) (tempRootDir </> dirPath)
      Right filePath -> do
        copyFile (moduleRootDir </> filePath) (tempRootDir </> filePath)

getArchiveFilePath :: Module -> T.Text -> App (Path Abs File)
getArchiveFilePath targetModule versionText = do
  let archiveDir = getArchiveDir targetModule
  Path.ensureDir archiveDir
  archiveFile <- Path.resolveFile archiveDir $ T.unpack $ versionText <> packageFileExtension
  archiveExists <- Path.doesFileExist archiveFile
  when archiveExists $ do
    Throw.raiseError' $ "the archive `" <> versionText <> "` already exists"
  return archiveFile
