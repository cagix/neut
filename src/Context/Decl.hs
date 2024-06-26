module Context.Decl
  ( initialize,
    insDeclEnv,
    insDeclEnv',
    lookupDeclEnv,
    getDeclEnv,
    member,
  )
where

import Context.App
import Context.App.Internal
import Context.Env qualified as Env
import Context.Throw qualified as Throw
import Control.Monad
import Data.HashMap.Strict qualified as Map
import Entity.ArgNum qualified as AN
import Entity.DeclarationName qualified as DN
import Entity.Foreign qualified as F
import Entity.Hint
import Entity.LowType qualified as LT
import Prelude hiding (lookup, read)

initialize :: App ()
initialize = do
  writeRef' declEnv Map.empty
  intBaseSize <- Env.getBaseSize'
  forM_ (F.defaultForeignList intBaseSize) $ \(F.Foreign name domList cod) -> do
    insDeclEnv' (DN.Ext name) domList cod

getDeclEnv :: App DN.DeclEnv
getDeclEnv =
  readRef' declEnv

insDeclEnv :: DN.DeclarationName -> AN.ArgNum -> App ()
insDeclEnv k argNum =
  modifyRef' declEnv $ Map.insert k (LT.toVoidPtrSeq argNum, LT.Pointer)

insDeclEnv' :: DN.DeclarationName -> [LT.LowType] -> LT.LowType -> App ()
insDeclEnv' k domList cod =
  modifyRef' declEnv $ Map.insert k (domList, cod)

lookupDeclEnv :: Hint -> DN.DeclarationName -> App ([LT.LowType], LT.LowType)
lookupDeclEnv m name = do
  denv <- readRef' declEnv
  case Map.lookup name denv of
    Just typeInfo ->
      return typeInfo
    Nothing -> do
      Throw.raiseError m $ "Undeclared function: " <> DN.reify name

member :: DN.DeclarationName -> App Bool
member name = do
  denv <- readRef' declEnv
  return $ Map.member name denv
