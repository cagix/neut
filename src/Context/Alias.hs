module Context.Alias
  ( resolveAlias,
    resolveLocatorAlias,
    initializeAliasMap,
    activateAliasInfo,
  )
where

import Context.Antecedent qualified as Antecedent
import Context.App
import Context.App.Internal
import Context.Locator qualified as Locator
import Context.Module qualified as Module
import Context.Throw qualified as Throw
import Control.Monad
import Data.HashMap.Strict qualified as Map
import Data.Maybe qualified as Maybe
import Entity.AliasInfo
import Entity.BaseName qualified as BN
import Entity.GlobalLocator qualified as GL
import Entity.GlobalLocatorAlias qualified as GLA
import Entity.Hint
import Entity.Module
import Entity.ModuleAlias
import Entity.ModuleDigest
import Entity.ModuleID qualified as MID
import Entity.Source qualified as Source
import Entity.SourceLocator qualified as SL
import Entity.StrictGlobalLocator qualified as SGL
import Entity.TopNameMap

registerGlobalLocatorAlias ::
  Hint ->
  GLA.GlobalLocatorAlias ->
  SGL.StrictGlobalLocator ->
  App ()
registerGlobalLocatorAlias m from to = do
  amap <- readRef' locatorAliasMap
  if Map.member from amap
    then Throw.raiseError m $ "the alias is already defined: " <> BN.reify (GLA.reify from)
    else modifyRef' locatorAliasMap $ Map.insert from to

resolveAlias ::
  Hint ->
  GL.GlobalLocator ->
  App SGL.StrictGlobalLocator
resolveAlias m gl = do
  case gl of
    GL.GlobalLocator moduleAlias sourceLocator -> do
      moduleID <- resolveModuleAlias m moduleAlias
      return
        SGL.StrictGlobalLocator
          { SGL.moduleID = moduleID,
            SGL.sourceLocator = sourceLocator
          }
    GL.GlobalLocatorAlias alias -> do
      aliasMap <- readRef' locatorAliasMap
      case Map.lookup alias aliasMap of
        Just sgl ->
          return sgl
        Nothing ->
          Throw.raiseError m $
            "no such global locator alias is defined: " <> BN.reify (GLA.reify alias)

resolveLocatorAlias ::
  Hint ->
  ModuleAlias ->
  SL.SourceLocator ->
  App SGL.StrictGlobalLocator
resolveLocatorAlias m moduleAlias sourceLocator = do
  moduleID <- resolveModuleAlias m moduleAlias
  return $
    SGL.StrictGlobalLocator
      { SGL.moduleID = moduleID,
        SGL.sourceLocator = sourceLocator
      }

resolveModuleAlias :: Hint -> ModuleAlias -> App MID.ModuleID
resolveModuleAlias m moduleAlias = do
  aliasMap <- readRef' moduleAliasMap
  case Map.lookup moduleAlias aliasMap of
    Just digest ->
      return $ MID.Library digest
    Nothing
      | moduleAlias == defaultModuleAlias ->
          return MID.Main
      | moduleAlias == baseModuleAlias ->
          return MID.Base
      | moduleAlias == coreModuleAlias ->
          resolveModuleAlias m defaultModuleAlias
      | otherwise ->
          Throw.raiseError m $
            "no such module alias is defined: " <> BN.reify (extract moduleAlias)

getModuleDigestAliasList :: Module -> App [(ModuleAlias, ModuleDigest)]
getModuleDigestAliasList baseModule = do
  let dependencyList = Map.toList $ moduleDependency baseModule
  forM dependencyList $ \(key, (_, digest)) -> do
    digest' <- getLatestCompatibleDigest digest
    return (key, digest')

getLatestCompatibleDigest :: ModuleDigest -> App ModuleDigest
getLatestCompatibleDigest mc = do
  mNewerModule <- Antecedent.lookup mc
  case mNewerModule of
    Just newerModule ->
      case moduleID newerModule of
        MID.Library newerDigest ->
          getLatestCompatibleDigest newerDigest
        _ ->
          return mc
    Nothing ->
      return mc

activateAliasInfo :: TopNameMap -> AliasInfo -> App ()
activateAliasInfo topNameMap aliasInfo =
  case aliasInfo of
    Prefix m from to ->
      registerGlobalLocatorAlias m from to
    Use strictGlobalLocator localLocatorList ->
      Locator.activateSpecifiedNames topNameMap strictGlobalLocator localLocatorList

initializeAliasMap :: App ()
initializeAliasMap = do
  currentModule <- Source.sourceModule <$> readRef "currentSource" currentSource
  mainModule <- Module.getMainModule
  let additionalDigestAlias = getAlias mainModule currentModule
  currentAliasList <- getModuleDigestAliasList currentModule
  let aliasMap = Map.fromList $ Maybe.catMaybes [additionalDigestAlias] ++ currentAliasList
  writeRef' moduleAliasMap aliasMap
  writeRef' locatorAliasMap Map.empty

getAlias :: Module -> Module -> Maybe (ModuleAlias, ModuleDigest)
getAlias mainModule currentModule = do
  case getID mainModule currentModule of
    MID.Library digest ->
      return (defaultModuleAlias, digest)
    MID.Main ->
      Nothing
    MID.Base ->
      Nothing
