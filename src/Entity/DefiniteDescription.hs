module Entity.DefiniteDescription
  ( DefiniteDescription (..),
    new,
    moduleID,
    localLocator,
    globalLocator,
    getReadableDD,
    getLocatorPair,
    newByGlobalLocator,
    getFormDD,
    imm,
    cls,
    toBuilder,
    llvmGlobalLocator,
    isEntryPoint,
  )
where

import Data.Binary
import Data.ByteString.Builder
import Data.HashMap.Strict qualified as Map
import Data.Hashable
import Data.List (find)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Entity.BaseName qualified as BN
import Entity.Const
import Entity.Error
import Entity.GlobalLocator qualified as GL
import Entity.Hint qualified as H
import Entity.List (initLast)
import Entity.LocalLocator qualified as LL
import Entity.Module qualified as M
import Entity.ModuleAlias qualified as MA
import Entity.ModuleDigest qualified as MD
import Entity.ModuleID qualified as MID
import Entity.SourceLocator qualified as SL
import Entity.StrictGlobalLocator qualified as SGL
import GHC.Generics

newtype DefiniteDescription = MakeDefiniteDescription {reify :: T.Text}
  deriving (Generic, Show)

instance Eq DefiniteDescription where
  dd1 == dd2 = do
    reify dd1 == reify dd2

instance Ord DefiniteDescription where
  compare dd1 dd2 = compare (reify dd1) (reify dd2)

instance Binary DefiniteDescription

instance Hashable DefiniteDescription

new :: SGL.StrictGlobalLocator -> LL.LocalLocator -> DefiniteDescription
new gl ll =
  MakeDefiniteDescription
    { reify = SGL.reify gl <> nsSep <> LL.reify ll
    }

newByGlobalLocator :: SGL.StrictGlobalLocator -> BN.BaseName -> DefiniteDescription
newByGlobalLocator gl name = do
  new gl $ LL.new name

{-# INLINE toLowName #-}
toLowName :: DefiniteDescription -> T.Text
toLowName dd =
  wrapWithQuote $ reify dd

{-# INLINE wrapWithQuote #-}
wrapWithQuote :: T.Text -> T.Text
wrapWithQuote x =
  "\"" <> x <> "\""

-- this.foo.bar
-- ~> this.foo.bar#form
getFormDD :: DefiniteDescription -> DefiniteDescription
getFormDD dd = do
  MakeDefiniteDescription
    { reify = reify dd <> "#" <> BN.reify BN.form
    }

moduleID :: DefiniteDescription -> T.Text
moduleID dd = do
  let nameList = T.splitOn nsSep (reify dd)
  case nameList of
    headElem : _ ->
      headElem
    _ ->
      error "Entity.DefiniteDescription.moduleID"

unconsDD :: DefiniteDescription -> (MID.ModuleID, T.Text)
unconsDD dd = do
  let nameList = T.splitOn nsSep (reify dd)
  case nameList of
    headElem : rest ->
      case headElem of
        "this" ->
          (MID.Main, T.intercalate nsSep rest)
        "base" ->
          (MID.Base, T.intercalate nsSep rest)
        _ ->
          (MID.Library (MD.ModuleDigest headElem), T.intercalate nsSep rest)
    _ ->
      error "Entity.DefiniteDescription.moduleID"

getReadableDD :: M.Module -> DefiniteDescription -> T.Text
getReadableDD baseModule dd =
  case unconsDD dd of
    (MID.Main, rest) ->
      "this" <> nsSep <> rest
    (MID.Base, rest) ->
      "base" <> nsSep <> rest
    (MID.Library digest, rest) -> do
      let depMap = Map.toList $ M.moduleDependency baseModule
      let aliasOrNone = fmap (MA.reify . fst) $ flip find depMap $ \(_, dependency) -> do
            digest == M.dependencyDigest dependency
      case aliasOrNone of
        Nothing ->
          reify dd
        Just alias ->
          alias <> nsSep <> rest

globalLocator :: DefiniteDescription -> T.Text
globalLocator dd = do
  let nameList = T.splitOn nsSep (reify dd)
  case initLast nameList of
    Just (xs, _) ->
      T.intercalate nsSep xs
    _ ->
      error "Entity.DefiniteDescription.globalLocator"

localLocator :: DefiniteDescription -> T.Text
localLocator dd = do
  let nameList = T.splitOn "." (reify dd)
  case initLast nameList of
    Just (_, result) ->
      result
    _ ->
      error "Entity.DefiniteDescription.localLocator"

imm :: DefiniteDescription
imm =
  newByGlobalLocator (SGL.baseGlobalLocatorOf SL.internalLocator) BN.imm

cls :: DefiniteDescription
cls =
  newByGlobalLocator (SGL.baseGlobalLocatorOf SL.internalLocator) BN.cls

toBuilder :: DefiniteDescription -> Builder
toBuilder dd =
  TE.encodeUtf8Builder $ toLowName dd

getLocatorPair :: H.Hint -> T.Text -> Either Error (GL.GlobalLocator, LL.LocalLocator)
getLocatorPair m varText = do
  let nameList = T.splitOn "." varText
  case initLast nameList of
    Nothing ->
      Left $ newError m "Entity.DefiniteDescription.getLocatorPair: empty variable name"
    Just ([], _) ->
      Left $ newError m $ "The symbol `" <> varText <> "` does not contain a global locator"
    Just (initElems, lastElem) -> do
      gl <- GL.reflect m $ T.intercalate "." initElems
      ll <- LL.reflect m lastElem
      return (gl, ll)

llvmGlobalLocator :: T.Text
llvmGlobalLocator =
  "base.llvm"

isEntryPoint :: DefiniteDescription -> Bool
isEntryPoint dd =
  localLocator dd `elem` ["main", "zen"]
