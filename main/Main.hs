module Main where

import Clarify
import qualified Codec.Archive.Tar as Tar
import qualified Codec.Compression.GZip as GZip
import Complete
import Control.Monad.State.Lazy
import Data.ByteString.Builder
import qualified Data.ByteString.Lazy as L
import Data.Env
import Data.Log
import Data.Time.Clock.POSIX
import Elaborate
import Emit
import LLVM
import Options.Applicative
import Parse
import Path
import Path.IO
import System.Directory (listDirectory)
import System.Exit
import System.Process
import Text.Read (readMaybe)

type InputPath = String

type OutputPath = String

type IsIncremental = Bool

type CheckOptEndOfEntry = String

type ShouldColorize = Bool

type Line = Int

type Column = Int

data OutputKind
  = OutputKindObject
  | OutputKindLLVM
  | OutputKindAsm
  deriving (Show)

instance Read OutputKind where
  readsPrec _ "object" = [(OutputKindObject, [])]
  readsPrec _ "llvm" = [(OutputKindLLVM, [])]
  readsPrec _ "asm" = [(OutputKindAsm, [])]
  readsPrec _ _ = []

data Command
  = Build InputPath (Maybe OutputPath) OutputKind IsIncremental
  | Check InputPath ShouldColorize CheckOptEndOfEntry
  | Archive InputPath (Maybe OutputPath)
  | Complete InputPath Line Column

main :: IO ()
main = execParser (info (helper <*> parseOpt) fullDesc) >>= run

parseOpt :: Parser Command
parseOpt =
  subparser
    ( command
        "build"
        (info (helper <*> parseBuildOpt) (progDesc "build given file"))
        <> command
          "check"
          (info (helper <*> parseCheckOpt) (progDesc "check specified file"))
        <> command
          "archive"
          ( info
              (helper <*> parseArchiveOpt)
              (progDesc "create archive from given path")
          )
        <> command
          "complete"
          (info (helper <*> parseCompleteOpt) (progDesc "show completion info"))
    )

parseBuildOpt :: Parser Command
parseBuildOpt =
  Build
    <$> argument
      str
      ( mconcat
          [ metavar "INPUT",
            help "The path of input file"
          ]
      )
    <*> optional
      ( strOption $
          mconcat
            [ long "output",
              short 'o',
              metavar "OUTPUT",
              help "The path of output file"
            ]
      )
    <*> option
      kindReader
      ( mconcat
          [ long "emit",
            metavar "KIND",
            value OutputKindObject,
            help "The type of output file"
          ]
      )
    <*> flag
      False
      True
      ( mconcat
          [ long "incremental",
            help "Set this to enable incremental compilation"
          ]
      )

kindReader :: ReadM OutputKind
kindReader = do
  s <- str
  case readMaybe s of
    Nothing -> readerError $ "unknown mode:" ++ s
    Just m -> return m

parseCheckOpt :: Parser Command
parseCheckOpt = do
  let inputPathOpt =
        argument str $ mconcat [metavar "INPUT", help "The path of input file"]
  let colorizeOpt =
        flag True False $
          mconcat
            [ long "no-color",
              help "Set this to disable colorization of the output"
            ]
  let footerOpt =
        strOption $
          mconcat
            [ long "end-of-entry",
              value "",
              help "String printed after each entry",
              metavar "STRING"
            ]
  Check <$> inputPathOpt <*> colorizeOpt <*> footerOpt

parseArchiveOpt :: Parser Command
parseArchiveOpt = do
  let inputPathOpt =
        argument str $
          mconcat [metavar "INPUT", help "The path of input directory"]
  let outputPathOpt =
        optional
          $ strOption
          $ mconcat
            [ long "output",
              short 'o',
              metavar "OUTPUT",
              help "The path of output"
            ]
  Archive <$> inputPathOpt <*> outputPathOpt

parseCompleteOpt :: Parser Command
parseCompleteOpt = do
  let inputPathOpt =
        argument str $ mconcat [metavar "INPUT", help "The path of input file"]
  let lineOpt = argument auto $ mconcat [help "Line number", metavar "LINE"]
  let columnOpt =
        argument auto $ mconcat [help "Column number", metavar "COLUMN"]
  Complete <$> inputPathOpt <*> lineOpt <*> columnOpt

run :: Command -> IO ()
run cmd =
  case cmd of
    Build inputPathStr mOutputPathStr outputKind _ -> do
      inputPath <- resolveFile' inputPathStr
      time <- round <$> getPOSIXTime
      resultOrErr <-
        evalWithEnv (runBuild inputPath) $
          initialEnv {shouldColorize = True, endOfEntry = "", timestamp = time}
      (basename, _) <- splitExtension $ filename inputPath
      mOutputPath <- mapM resolveFile' mOutputPathStr
      outputPath <- constructOutputPath basename mOutputPath outputKind
      case resultOrErr of
        Left (Error err) ->
          seqIO (map (outputLog True "") err) >> exitWith (ExitFailure 1)
        Right result -> do
          let result' = toLazyByteString result
          case outputKind of
            OutputKindLLVM -> L.writeFile (toFilePath outputPath) result'
            OutputKindObject -> do
              tmpOutputPath <- liftIO $ addExtension ".ll" outputPath
              let tmpOutputPathStr = toFilePath tmpOutputPath
              L.writeFile tmpOutputPathStr result'
              callProcess
                "clang"
                [ tmpOutputPathStr,
                  "-Wno-override-module",
                  "-o" ++ toFilePath outputPath
                ]
              removeFile tmpOutputPath
            OutputKindAsm -> do
              tmpOutputPath <- liftIO $ addExtension ".ll" outputPath
              let tmpOutputPathStr = toFilePath tmpOutputPath
              L.writeFile tmpOutputPathStr result'
              callProcess
                "clang"
                [ "-S",
                  tmpOutputPathStr,
                  "-Wno-override-module",
                  "-o" ++ toFilePath outputPath
                ]
              removeFile tmpOutputPath
    Check inputPathStr colorizeFlag eoe -> do
      inputPath <- resolveFile' inputPathStr
      time <- round <$> getPOSIXTime
      resultOrErr <-
        evalWithEnv (runCheck inputPath) $
          initialEnv
            { shouldColorize = colorizeFlag,
              endOfEntry = eoe,
              isCheck = True,
              timestamp = time
            }
      case resultOrErr of
        Right _ -> return ()
        Left (Error err) ->
          seqIO (map (outputLog colorizeFlag eoe) err) >> exitWith (ExitFailure 1)
    Archive inputPathStr mOutputPathStr -> do
      inputPath <- resolveDir' inputPathStr
      contents <- listDirectory $ toFilePath inputPath
      mOutputPath <- mapM resolveFile' mOutputPathStr
      outputPath <- toFilePath <$> constructOutputArchivePath inputPath mOutputPath
      archive outputPath (toFilePath inputPath) contents
    Complete inputPathStr l c -> do
      inputPath <- resolveFile' inputPathStr
      time <- round <$> getPOSIXTime
      resultOrErr <-
        evalWithEnv (complete inputPath l c) $ initialEnv {timestamp = time}
      case resultOrErr of
        Left _ -> return ()
        Right result -> mapM_ putStrLn result

constructOutputPath :: Path Rel File -> Maybe (Path Abs File) -> OutputKind -> IO (Path Abs File)
constructOutputPath basename mPath kind =
  case mPath of
    Just path -> return path
    Nothing ->
      case kind of
        OutputKindLLVM -> do
          dir <- getCurrentDir
          addExtension ".ll" (dir </> basename)
        OutputKindAsm -> do
          dir <- getCurrentDir
          addExtension ".s" (dir </> basename)
        OutputKindObject -> do
          dir <- getCurrentDir
          return $ dir </> basename

constructOutputArchivePath :: Path Abs Dir -> Maybe (Path Abs File) -> IO (Path Abs File)
constructOutputArchivePath inputPath mPath =
  case mPath of
    Just path -> return path
    Nothing -> do
      let baseName = fromRelDir $ dirname inputPath
      outputPath <- resolveFile' baseName
      addExtension ".tar.gz" outputPath

runBuild :: Path Abs File -> WithEnv Builder
runBuild = parse >=> elaborate >=> clarify >=> toLLVM >=> emit

runCheck :: Path Abs File -> WithEnv ()
runCheck = parse >=> elaborate >=> \_ -> return ()

seqIO :: [IO ()] -> IO ()
seqIO = foldr (>>) (return ())

archive :: FilePath -> FilePath -> [FilePath] -> IO ()
archive tarPath base dir = do
  es <- Tar.pack base dir
  L.writeFile tarPath $ GZip.compress $ Tar.write es
