module Context.Type
  ( initialize,
    lookup,
    lookupMaybe,
    insert,
  )
where

import Context.App
import Context.App.Internal
import Context.Throw qualified as Throw
import Data.HashMap.Strict qualified as Map
import Entity.DefiniteDescription qualified as DD
import Entity.Hint
import Entity.WeakTerm
import Prelude hiding (lookup)

initialize :: App ()
initialize = do
  writeRef' typeEnv Map.empty

lookup :: Hint -> DD.DefiniteDescription -> App WeakTerm
lookup m k = do
  valueOrNone <- lookupMaybe k
  case valueOrNone of
    Just value ->
      return value
    Nothing ->
      Throw.raiseCritical m $ "`" <> DD.reify k <> "` is not found in the term type environment."

lookupMaybe :: DD.DefiniteDescription -> App (Maybe WeakTerm)
lookupMaybe k = do
  tenv <- readRef' typeEnv
  return $ Map.lookup k tenv

insert :: DD.DefiniteDescription -> WeakTerm -> App ()
insert k v =
  modifyRef' typeEnv $ Map.insert k v
