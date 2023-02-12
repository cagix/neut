module Entity.Source where

import Control.Monad.Catch
import Data.Set qualified as S
import Entity.Module
import Entity.OutputKind qualified as OK
import Path

data Source = Source
  { sourceFilePath :: Path Abs File,
    sourceModule :: Module
  }
  deriving (Show)

class MonadThrow m => Context m

getRelPathFromSourceDir :: Context m => Source -> m (Path Rel File)
getRelPathFromSourceDir source = do
  let sourceDir = getSourceDir $ sourceModule source
  stripProperPrefix sourceDir (sourceFilePath source)

sourceToOutputPath :: Context m => OK.OutputKind -> Source -> m (Path Abs File)
sourceToOutputPath kind source = do
  let artifactDir = getArtifactDir $ sourceModule source
  relPath <- getRelPathFromSourceDir source
  (relPathWithoutExtension, _) <- splitExtension relPath
  attachExtension (artifactDir </> relPathWithoutExtension) kind

getSourceCachePath :: Context m => Source -> m (Path Abs File)
getSourceCachePath source = do
  let artifactDir = getArtifactDir $ sourceModule source
  relPath <- getRelPathFromSourceDir source
  (relPathWithoutExtension, _) <- splitExtension relPath
  addExtension ".i" (artifactDir </> relPathWithoutExtension)

attachExtension :: Context m => Path Abs File -> OK.OutputKind -> m (Path Abs File)
attachExtension file kind =
  case kind of
    OK.LLVM -> do
      addExtension ".ll" file
    OK.Asm -> do
      addExtension ".s" file
    OK.Object -> do
      addExtension ".o" file

isCompilationSkippable :: S.Set (Path Abs File) -> S.Set (Path Abs File) -> [OK.OutputKind] -> Source -> Bool
isCompilationSkippable hasLLVMSet hasObjectSet outputKindList source =
  case outputKindList of
    [] ->
      True
    kind : rest -> do
      case kind of
        OK.LLVM -> do
          let b1 = S.member (sourceFilePath source) hasLLVMSet
          let b2 = isCompilationSkippable hasLLVMSet hasObjectSet rest source
          b1 && b2
        OK.Asm ->
          isCompilationSkippable hasLLVMSet hasObjectSet rest source
        OK.Object -> do
          let b1 = S.member (sourceFilePath source) hasObjectSet
          let b2 = isCompilationSkippable hasLLVMSet hasObjectSet rest source
          b1 && b2

attachOutputPath :: Context m => OK.OutputKind -> Source -> m (OK.OutputKind, Path Abs File)
attachOutputPath outputKind source = do
  outputPath <- sourceToOutputPath outputKind source
  return (outputKind, outputPath)
