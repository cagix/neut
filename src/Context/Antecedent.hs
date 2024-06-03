module Context.Antecedent where

import Context.App
import Context.App.Internal
import Control.Monad
import Data.ByteString.UTF8 qualified as B
import Data.HashMap.Strict qualified as Map
import Data.Text qualified as T
import Entity.Digest (hashAndEncode)
import Entity.Module qualified as M
import Entity.ModuleDigest qualified as MD
import Entity.ModuleID qualified as MID
import Prelude hiding (lookup, read)

initialize :: App ()
initialize = do
  writeRef' antecedentMap Map.empty
  writeRef' antecedentDigestCache Nothing

setMap :: Map.HashMap MID.ModuleID M.Module -> App ()
setMap =
  writeRef' antecedentMap

getMap :: App (Map.HashMap MID.ModuleID M.Module)
getMap =
  readRef' antecedentMap

lookup :: MD.ModuleDigest -> App (Maybe M.Module)
lookup mc = do
  aenv <- readRef' antecedentMap
  return $ Map.lookup (MID.Library mc) aenv

getShiftDigest :: App T.Text
getShiftDigest = do
  digestOrNone <- readRef' antecedentDigestCache
  case digestOrNone of
    Just digest -> do
      return digest
    Nothing -> do
      amap <- Map.toList <$> getMap
      let amap' = map (\(foo, bar) -> (MID.reify foo, MID.reify $ M.moduleID bar)) amap
      let digest = T.pack $ B.toString $ hashAndEncode $ B.fromString $ show amap'
      writeRef antecedentDigestCache digest
      return digest
