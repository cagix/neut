module Scene.New
  ( createNewProject,
    constructDefaultModule,
  )
where

import Context.App
import Context.Module qualified as Module
import Context.Path qualified as Path
import Context.Remark qualified as Remark
import Context.Throw qualified as Throw
import Control.Monad
import Data.HashMap.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Entity.ClangOption qualified as CL
import Entity.Const
import Entity.Module
import Entity.ModuleID qualified as MID
import Entity.SourceLocator qualified as SL
import Entity.Target
import Entity.ZenConfig
import Path (parent, (</>))

createNewProject :: T.Text -> Module -> App ()
createNewProject moduleName newModule = do
  let moduleDir = parent $ moduleLocation newModule
  moduleDirExists <- Path.doesDirExist moduleDir
  if moduleDirExists
    then Throw.raiseError' $ "The directory `" <> moduleName <> "` already exists"
    else do
      createModuleFile newModule
      createMainFile newModule
      Remark.printNote' $ "Created a module: " <> moduleName

constructDefaultModule :: T.Text -> Maybe T.Text -> App Module
constructDefaultModule moduleName mTargetName = do
  let targetName = fromMaybe moduleName mTargetName
  currentDir <- Path.getCurrentDir
  moduleRootDir <- Path.resolveDir currentDir $ T.unpack moduleName
  mainFile <- Path.parseRelFile $ T.unpack targetName <> sourceFileExtension
  return $
    Module
      { moduleID = MID.Main,
        moduleArchiveDir = archiveRelDir,
        moduleCacheDir = cacheRelDir,
        moduleSourceDir = sourceRelDir,
        moduleTarget =
          Map.fromList
            [ ( targetName,
                TargetSummary
                  { entryPoint = SL.SourceLocator mainFile,
                    clangOption = CL.empty
                  }
              )
            ],
        moduleZenConfig = ZenConfig {clangOption = CL.empty},
        moduleDependency = Map.empty,
        moduleExtraContents = [],
        moduleAntecedents = [],
        moduleLocation = moduleRootDir </> moduleFile,
        moduleStaticFiles = Map.empty,
        moduleForeign = Foreign {input = [], output = [], script = []},
        modulePrefixMap = Map.empty,
        moduleInlineLimit = Nothing,
        modulePresetMap = Map.empty
      }

createModuleFile :: Module -> App ()
createModuleFile newModule = do
  Path.ensureDir $ parent $ moduleLocation newModule
  Module.saveEns (moduleLocation newModule) ([], (toDefaultEns newModule, []))
  buildDir <- Path.getBaseBuildDir newModule
  Path.ensureDir buildDir

createMainFile :: Module -> App ()
createMainFile newModule = do
  Path.ensureDir $ getSourceDir newModule
  forM_ (getTargetPathList newModule) $ \mainFilePath -> do
    Path.writeText mainFilePath "define main(): unit {\n  print(\"Hello, world!\\n\")\n}\n"
