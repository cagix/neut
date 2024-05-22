module Scene.Link
  ( link,
  )
where

import Context.App
import Context.LLVM qualified as LLVM
import Context.Module qualified as Module
import Context.Path qualified as Path
import Data.Containers.ListUtils (nubOrdOn)
import Data.Maybe
import Entity.Artifact qualified as A
import Entity.Module
import Entity.OutputKind qualified as OK
import Entity.Source qualified as Source
import Entity.Target
import Path
import Path.IO

link :: ConcreteTarget -> Bool -> Bool -> A.ArtifactTime -> [Source.Source] -> App ()
link target shouldSkipLink didPerformForeignCompilation artifactTime sourceList = do
  mainModule <- Module.getMainModule
  isExecutableAvailable <- Path.getExecutableOutputPath target mainModule >>= Path.doesFileExist
  let b1 = not didPerformForeignCompilation
  let b2 = shouldSkipLink || (isJust (A.objectTime artifactTime) && isExecutableAvailable)
  if b1 && b2
    then return ()
    else link' target mainModule sourceList

link' :: ConcreteTarget -> Module -> [Source.Source] -> App ()
link' target mainModule sourceList = do
  mainObject <- snd <$> Path.getOutputPathForEntryPoint mainModule OK.Object target
  outputPath <- Path.getExecutableOutputPath target mainModule
  objectPathList <- mapM (Path.sourceToOutputPath (Concrete target) OK.Object) sourceList
  let moduleList = nubOrdOn moduleID $ map Source.sourceModule sourceList
  foreignDirList <- mapM (Path.getForeignDir (Concrete target)) moduleList
  foreignObjectList <- concat <$> mapM getForeignDirContent foreignDirList
  let clangOptions = getLinkOption (Concrete target)
  LLVM.link clangOptions (mainObject : objectPathList ++ foreignObjectList) outputPath

getForeignDirContent :: Path Abs Dir -> App [Path Abs File]
getForeignDirContent foreignDir = do
  b <- doesDirExist foreignDir
  if b
    then snd <$> listDir foreignDir
    else return []
