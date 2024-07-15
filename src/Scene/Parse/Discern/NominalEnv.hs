module Scene.Parse.Discern.NominalEnv
  ( Axis (..),
    emptyAxis,
    extendAxis,
    extendAxisByNominalEnv,
    extendNominalEnvWithoutInsert,
  )
where

import Context.App
import Context.UnusedVariable qualified as UnusedVariable
import Entity.Hint
import Entity.Ident
import Entity.Ident.Reify qualified as Ident
import Entity.Layer
import Entity.Module
import Entity.NominalEnv
import Entity.VarDefKind

data Axis = Axis
  { _nenv :: NominalEnv,
    currentModule :: Module,
    currentLayer :: Layer
  }

emptyAxis :: Module -> Layer -> Axis
emptyAxis m l =
  Axis {_nenv = empty, currentModule = m, currentLayer = l}

extendAxis :: Hint -> Ident -> VarDefKind -> Axis -> App Axis
extendAxis m newVar k axis = do
  nenv' <- extendNominalEnv m newVar (currentLayer axis) k (_nenv axis)
  return $ axis {_nenv = nenv'}

extendAxisByNominalEnv :: VarDefKind -> NominalEnv -> Axis -> App Axis
extendAxisByNominalEnv k newNominalEnv oldAxis = do
  nenv' <- joinNominalEnv k newNominalEnv (_nenv oldAxis)
  return $ oldAxis {_nenv = nenv'}

extendNominalEnv :: Hint -> Ident -> Layer -> VarDefKind -> NominalEnv -> App NominalEnv
extendNominalEnv m newVar l k nenv = do
  UnusedVariable.insert m newVar k
  return $ (Ident.toText newVar, (m, newVar, l)) : nenv

extendNominalEnvWithoutInsert :: Hint -> Ident -> Layer -> NominalEnv -> NominalEnv
extendNominalEnvWithoutInsert m newVar l nenv = do
  (Ident.toText newVar, (m, newVar, l)) : nenv

joinNominalEnv :: VarDefKind -> NominalEnv -> NominalEnv -> App NominalEnv
joinNominalEnv k newNominalEnv oldNominalEnv = do
  case newNominalEnv of
    [] ->
      return oldNominalEnv
    (_, (m, x, l)) : rest -> do
      oldNominalEnv' <- extendNominalEnv m x l k oldNominalEnv
      joinNominalEnv k rest oldNominalEnv'
