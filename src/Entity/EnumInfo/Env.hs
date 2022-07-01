module Entity.EnumInfo.Env
  ( register,
    registerIfNew,
    initializeEnumEnv,
  )
where

import Context.Throw
import Control.Monad
import Data.Function
import qualified Data.HashMap.Lazy as Map
import Data.IORef
import Data.List
import Entity.EnumInfo
import Entity.Global
import Entity.Hint

register :: EnumInfo -> IO ()
register enumInfo = do
  let (name, xis) = fromEnumInfo enumInfo
  let (xs, is) = unzip xis
  let rev = Map.fromList $ zip xs (zip (repeat name) is)
  modifyIORef' enumEnvRef $ Map.insert name xis
  modifyIORef' revEnumEnvRef $ Map.union rev

registerIfNew :: Context -> Hint -> EnumInfo -> IO ()
registerIfNew context m enumInfo = do
  let (name, xis) = fromEnumInfo enumInfo
  enumEnv <- readIORef enumEnvRef
  let definedEnums = Map.keys enumEnv ++ map fst (concat (Map.elems enumEnv))
  case find (`elem` definedEnums) $ name : map fst xis of
    Just x ->
      (context & raiseError) m $ "the constant `" <> x <> "` is already defined [ENUM]"
    _ ->
      register enumInfo

initializeEnumEnv :: IO ()
initializeEnumEnv = do
  forM_ initialEnumEnv register