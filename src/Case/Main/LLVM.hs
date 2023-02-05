module Case.Main.LLVM
  ( emit,
    link,
    Context,
  )
where

import Context.Env qualified as Env
import Context.External qualified as External
import Context.Path qualified as Path
import Context.Throw qualified as Throw
import Control.Monad.IO.Class
import Control.Monad.IO.Unlift
import Data.ByteString.Lazy qualified as L
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Entity.OutputKind qualified as OK
import GHC.IO.Handle
import Path
import Path.IO
import System.Exit
import System.Process

type ClangOption = String

type LLVMCode = L.ByteString

class
  ( Throw.Context m,
    Env.Context m,
    MonadIO m,
    Path.Context m,
    External.Context m,
    MonadUnliftIO m
  ) =>
  Context m

emit :: Context m => LLVMCode -> [(OK.OutputKind, Path Abs File)] -> m ()
emit llvmCode kindPathList = do
  case kindPathList of
    [] ->
      return ()
    (kind, path) : rest -> do
      emit' llvmCode kind path
      emit llvmCode rest

emit' :: Context m => LLVMCode -> OK.OutputKind -> Path Abs File -> m ()
emit' llvmCode kind path = do
  clangOptString <- Env.getClangOptString
  case kind of
    OK.LLVM -> do
      Path.writeByteString path llvmCode
    OK.Asm ->
      emitInner ("-S" : words clangOptString) llvmCode path
    OK.Object ->
      emitInner (words clangOptString) llvmCode path

emitInner :: Context m => [ClangOption] -> L.ByteString -> Path Abs File -> m ()
emitInner additionalClangOptions llvm outputPath = do
  let clangCmd = proc "clang" $ clangBaseOpt outputPath ++ additionalClangOptions
  withRunInIO $ \runInIO ->
    withCreateProcess clangCmd {std_in = CreatePipe, std_err = CreatePipe} $
      \mStdin _ mClangErrorHandler clangProcessHandler -> do
        case (mStdin, mClangErrorHandler) of
          (Just stdin, Just clangErrorHandler) -> do
            L.hPut stdin llvm
            hClose stdin
            clangExitCode <- waitForProcess clangProcessHandler
            runInIO $ raiseIfProcessFailed "clang" clangExitCode clangErrorHandler
          (Nothing, _) ->
            runInIO $ Throw.raiseError' "couldn't obtain stdin"
          (_, Nothing) ->
            runInIO $ Throw.raiseError' "couldn't obtain stderr"

clangLinkOpt :: [Path Abs File] -> Path Abs File -> String -> [String]
clangLinkOpt objectPathList outputPath additionalOptionStr = do
  let pathList = map toFilePath objectPathList
  ["-Wno-override-module", "-O2", "-o", toFilePath outputPath] ++ pathList ++ words additionalOptionStr

link :: Context m => String -> [Path Abs File] -> Path Abs File -> m ()
link additionalLinkOpt objectPathList outputPath = do
  clangOptString <- Env.getClangOptString
  ensureDir $ parent outputPath
  liftIO $ print $ words additionalLinkOpt ++ clangLinkOpt objectPathList outputPath clangOptString
  External.run "clang" $ words additionalLinkOpt ++ clangLinkOpt objectPathList outputPath clangOptString

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

raiseIfProcessFailed :: Context m => T.Text -> ExitCode -> Handle -> m ()
raiseIfProcessFailed procName exitCode h =
  case exitCode of
    ExitSuccess ->
      return ()
    ExitFailure i -> do
      errStr <- liftIO $ TIO.hGetContents h
      Throw.raiseError' $
        "the child process `"
          <> procName
          <> "` failed with the following message (exitcode = "
          <> T.pack (show i)
          <> "):\n"
          <> errStr
