module Context.LLVM.Main (new) where

import Context.LLVM
import qualified Context.Throw as Throw
import qualified Data.ByteString.Lazy as L
import Entity.OutputKind
import GHC.IO.Handle
import Path
import Path.IO
import System.Process

type ClangOptString = String

type ClangOption = String

type LLVMCode = L.ByteString

new :: ClangOptString -> Throw.Context -> IO Axis
new clangOptStr axis = do
  return
    Axis
      { emit = _emit axis clangOptStr,
        link = _link axis clangOptStr
      }

_emit :: Throw.Context -> ClangOptString -> OutputKind -> LLVMCode -> Path Abs File -> IO ()
_emit axis clangOptString kind = do
  case kind of
    OutputKindAsm ->
      emitInner ("-S" : words clangOptString) axis
    _ ->
      emitInner (words clangOptString) axis

emitInner :: [ClangOption] -> Throw.Context -> L.ByteString -> Path Abs File -> IO ()
emitInner additionalClangOptions axis llvm outputPath = do
  let clangCmd = proc "clang" $ clangBaseOpt outputPath ++ additionalClangOptions
  withCreateProcess clangCmd {std_in = CreatePipe, std_err = CreatePipe} $
    \(Just stdin) _ (Just clangErrorHandler) clangProcessHandler -> do
      L.hPut stdin llvm
      hClose stdin
      clangExitCode <- waitForProcess clangProcessHandler
      Throw.raiseIfProcessFailed axis "clang" clangExitCode clangErrorHandler
      return ()

clangLinkOpt :: [Path Abs File] -> Path Abs File -> String -> [String]
clangLinkOpt objectPathList outputPath additionalOptionStr = do
  let pathList = map toFilePath objectPathList
  ["-Wno-override-module", "-O2", "-o", toFilePath outputPath] ++ pathList ++ words additionalOptionStr

_link :: Throw.Context -> ClangOptString -> [Path Abs File] -> Path Abs File -> IO ()
_link axis clangOptString objectPathList outputPath = do
  ensureDir $ parent outputPath
  let clangCmd = proc "clang" $ clangLinkOpt objectPathList outputPath clangOptString
  withCreateProcess clangCmd {std_err = CreatePipe} $
    \_ _ (Just clangErrorHandler) clangHandler -> do
      clangExitCode <- waitForProcess clangHandler
      Throw.raiseIfProcessFailed axis "clang" clangExitCode clangErrorHandler

clangBaseOpt :: Path Abs File -> [String]
clangBaseOpt outputPath =
  [ "-xir",
    "-Wno-override-module",
    "-O2",
    "-c",
    "-",
    "-o",
    toFilePath outputPath
  ]