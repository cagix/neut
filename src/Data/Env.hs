module Data.Env where

import Control.Exception.Safe
import Control.Monad.State.Lazy
import Data.Basic
import Data.Comp
import qualified Data.HashMap.Lazy as Map
import qualified Data.IntMap as IntMap
import Data.Log
import Data.LowComp
import Data.LowType
import Data.MetaTerm
import qualified Data.PQueue.Min as Q
import qualified Data.Set as S
import Data.Term
import qualified Data.Text as T
import Data.Version (showVersion)
import Data.WeakTerm
import Path
import Path.IO
import Paths_neut (version)
import System.Directory (createDirectoryIfMissing)
import qualified Text.Show.Pretty as Pr

type Compiler a =
  StateT Env IO a

data VisitInfo
  = VisitInfoActive
  | VisitInfoFinish

data Env = Env
  { count :: Int,
    shouldColorize :: Bool,
    shouldCancelAlloc :: Bool,
    endOfEntry :: String,
    --
    -- Preprocess
    --
    topMetaNameEnv :: Map.HashMap T.Text Ident,
    metaTermCtx :: SubstMetaTerm,
    --
    -- parse
    --
    fileEnv :: Map.HashMap (Path Abs File) VisitInfo,
    traceEnv :: [Path Abs File],
    -- [("choice", [("left", 0), ("right", 1)]), ...]
    enumEnv :: Map.HashMap T.Text [(T.Text, Int)],
    -- [("left", ("choice", 0)), ("right", ("choice", 1)), ...]
    revEnumEnv :: Map.HashMap T.Text (T.Text, Int),
    dataEnv :: Map.HashMap T.Text [T.Text],
    constructorEnv :: Map.HashMap T.Text (Int, Int),
    prefixEnv :: [T.Text],
    nsEnv :: [(T.Text, T.Text)],
    sectionEnv :: [T.Text],
    topNameEnv :: Map.HashMap T.Text Ident,
    --
    -- elaborate
    --
    weakTypeEnv :: IntMap.IntMap WeakTermPlus,
    constTypeEnv :: Map.HashMap T.Text TermPlus,
    holeEnv :: IntMap.IntMap (WeakTermPlus, WeakTermPlus),
    constraintEnv :: [Constraint],
    suspendedConstraintEnv :: SuspendedConstraintQueue,
    substEnv :: IntMap.IntMap WeakTermPlus,
    opaqueEnv :: S.Set Ident,
    --
    -- clarify
    --
    defEnv :: Map.HashMap T.Text (IsReducible, [Ident], CompPlus),
    --
    -- LLVM
    --
    lowDefEnv :: Map.HashMap T.Text ([Ident], LowComp),
    declEnv :: Map.HashMap T.Text ([LowType], LowType),
    nopFreeSet :: S.Set Int
  }

initialEnv :: Env
initialEnv =
  Env
    { count = 0,
      shouldColorize = True,
      shouldCancelAlloc = True,
      endOfEntry = "",
      topMetaNameEnv = Map.empty,
      metaTermCtx = IntMap.empty,
      nsEnv = [],
      enumEnv = Map.empty,
      fileEnv = Map.empty,
      holeEnv = IntMap.empty,
      traceEnv = [],
      revEnumEnv = Map.empty,
      dataEnv = Map.empty,
      constructorEnv = Map.empty,
      topNameEnv = Map.empty,
      prefixEnv = [],
      sectionEnv = [],
      weakTypeEnv = IntMap.empty,
      constTypeEnv = Map.empty,
      defEnv = Map.empty,
      lowDefEnv = Map.empty,
      declEnv =
        Map.fromList
          [ ("malloc", ([voidPtr], voidPtr)),
            ("free", ([voidPtr], voidPtr))
          ],
      constraintEnv = [],
      suspendedConstraintEnv = Q.empty,
      substEnv = IntMap.empty,
      opaqueEnv = S.empty,
      nopFreeSet = S.empty
    }

runCompiler :: Compiler a -> Env -> IO (Either Error a)
runCompiler c env = do
  resultOrErr <- try $ runStateT c env
  case resultOrErr of
    Left err ->
      return $ Left err
    Right (result, _) ->
      return $ Right result

--
-- generating new symbols using count
--

{-# INLINE newCount #-}
newCount :: Compiler Int
newCount = do
  i <- gets count
  modify (\e -> e {count = i + 1})
  if i + 1 == 0
    then raiseCritical' "counter exhausted"
    else return i

{-# INLINE newIdentFromText #-}
newIdentFromText :: T.Text -> Compiler Ident
newIdentFromText s = do
  i <- newCount
  return $ I (s, i)

{-# INLINE newIdentFromIdent #-}
newIdentFromIdent :: Ident -> Compiler Ident
newIdentFromIdent x =
  newIdentFromText (asText x)

{-# INLINE newText #-}
newText :: Compiler T.Text
newText = do
  i <- newCount
  return $ ";" <> T.pack (show i)

{-# INLINE newAster #-}
newAster :: Hint -> Compiler WeakTermPlus
newAster m = do
  i <- newCount
  return (m, WeakTermAster i)

{-# INLINE newValueVarLocalWith #-}
newValueVarLocalWith :: Hint -> T.Text -> Compiler (Ident, ValuePlus)
newValueVarLocalWith m name = do
  x <- newIdentFromText name
  return (x, (m, ValueVarLocal x))

--
-- obtain information from the environment
--

getCurrentFilePath :: Compiler (Path Abs File)
getCurrentFilePath = do
  tenv <- gets traceEnv
  return $ head tenv

getCurrentDirPath :: Compiler (Path Abs Dir)
getCurrentDirPath =
  parent <$> getCurrentFilePath

getLibraryDirPath :: Compiler (Path Abs Dir)
getLibraryDirPath = do
  let ver = showVersion version
  relLibPath <- parseRelDir $ ".local/share/neut/" <> ver <> "/library"
  getDirPath relLibPath

getDirPath :: Path Rel Dir -> Compiler (Path Abs Dir)
getDirPath base = do
  homeDirPath <- getHomeDir
  let path = homeDirPath </> base
  liftIO $ createDirectoryIfMissing True $ toFilePath path
  return path

--
-- output
--

note :: Hint -> T.Text -> Compiler ()
note m str = do
  b <- gets shouldColorize
  eoe <- gets endOfEntry
  liftIO $ outputLog b eoe $ logNote (getPosInfo m) str

note' :: T.Text -> Compiler ()
note' str = do
  b <- gets shouldColorize
  eoe <- gets endOfEntry
  liftIO $ outputLog b eoe $ logNote' str

note'' :: T.Text -> Compiler ()
note'' str = do
  b <- gets shouldColorize
  liftIO $ outputLog' b $ logNote' str

warn :: PosInfo -> T.Text -> Compiler ()
warn pos str = do
  b <- gets shouldColorize
  eoe <- gets endOfEntry
  liftIO $ outputLog b eoe $ logWarning pos str

-- for debug
p :: String -> Compiler ()
p s =
  liftIO $ putStrLn s

p' :: (Show a) => a -> Compiler ()
p' s =
  liftIO $ putStrLn $ Pr.ppShow s
