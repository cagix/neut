module Scene.Parse
  ( parseMain,
    parseOther,
  )
where

import Context.App
import qualified Context.Throw as Throw
import Control.Comonad.Cofree
import Control.Monad
import Control.Monad.IO.Class
import qualified Data.HashMap.Lazy as Map
import Data.IORef
import qualified Data.Set as S
import qualified Data.Text as T
import Entity.AliasInfo
import Entity.Binder
import Entity.EnumInfo
import qualified Entity.EnumInfo.Env as EnumInfo
import Entity.Global
import Entity.Hint
import qualified Entity.Ident.Reflect as Ident
import qualified Entity.Ident.Reify as Ident
import Entity.LamKind
import Entity.Namespace
import Entity.Opacity
import Entity.Source
import Entity.Stmt
import Entity.Stmt.Discern
import Entity.WeakTerm
import Scene.Parse.Core
import Scene.Parse.Enum
import Scene.Parse.Import
import Scene.Parse.WeakTerm
import System.IO.Unsafe
import Text.Megaparsec

--
-- core functions
--

parseMain :: Axis -> T.Text -> Source -> IO (Either [Stmt] ([QuasiStmt], [EnumInfo]))
parseMain axis mainFunctionName source = do
  result <- parseSource axis source
  ensureMain axis mainFunctionName
  return result

parseOther :: Axis -> Source -> IO (Either [Stmt] ([QuasiStmt], [EnumInfo]))
parseOther =
  parseSource

parseSource :: Axis -> Source -> IO (Either [Stmt] ([QuasiStmt], [EnumInfo]))
parseSource axis source = do
  setCurrentFilePath $ sourceFilePath source
  mCache <- loadCache source
  initializeNamespace axis source
  setupSectionPrefix axis source
  case mCache of
    Just cache -> do
      forM_ (cacheEnumInfo cache) EnumInfo.register
      let stmtList = cacheStmtList cache
      let names = S.fromList $ map extractName stmtList
      modifyIORef' topNameSetRef $ S.union names
      return $ Left stmtList
    Nothing -> do
      getCurrentFilePath axis >>= activateAliasInfo axis
      (defList, enumInfoList) <- run (program axis) $ sourceFilePath source
      privateNameSet <- readIORef privateNameSetRef
      modifyIORef' topNameSetRef $ S.filter (`S.notMember` privateNameSet)
      return $ Right (defList, enumInfoList)

ensureMain :: Axis -> T.Text -> IO ()
ensureMain axis mainFunctionName = do
  let m = error "undefined"
  topNameSet <- readIORef topNameSetRef
  currentGlobalLocator <- readIORef currentGlobalLocatorRef
  if S.member mainFunctionName topNameSet
    then return ()
    else (axis & throw & Throw.raiseError) m $ "`main` is missing in `" <> currentGlobalLocator <> "`"

program :: Axis -> Parser ([QuasiStmt], [EnumInfo])
program axis = do
  skipImportSequence
  program' axis <* eof

program' :: Axis -> Parser ([QuasiStmt], [EnumInfo])
program' axis =
  choice
    [ do
        enumInfo <- parseDefineEnum axis
        (defList, enumInfoList) <- program' axis
        return (defList, enumInfo : enumInfoList),
      do
        parseDefinePrefix axis
        program' axis,
      do
        parseStmtUse
        program' axis,
      do
        stmtList <- many (parseStmt axis) >>= liftIO . discernStmtList axis . concat
        return (stmtList, [])
    ]

parseDefinePrefix :: Axis -> Parser ()
parseDefinePrefix axis = do
  m <- currentHint
  try $ keyword "define-prefix"
  from <- snd <$> var
  delimiter "="
  to <- snd <$> var
  liftIO $ handleDefinePrefix axis m from to

parseStmtUse :: Parser ()
parseStmtUse = do
  try $ keyword "use"
  (_, name) <- parseDefiniteDescription
  liftIO $ activateLocalLocator name

parseStmt :: Axis -> Parser [WeakStmt]
parseStmt axis = do
  choice
    [ parseDefineData axis,
      parseDefineCodata axis,
      return <$> parseDefineResource axis,
      return <$> parseDefine axis OpacityTransparent,
      return <$> parseDefine axis OpacityOpaque,
      return <$> parseSection axis
    ]

--
-- parser for statements
--

parseSection :: Axis -> Parser WeakStmt
parseSection axis = do
  try $ keyword "section"
  sectionName <- symbol
  liftIO $ modifyIORef' isPrivateStackRef $ (:) (sectionName == "private")
  liftIO $ pushToCurrentLocalLocator sectionName
  stmtList <- concat <$> many (parseStmt axis)
  m <- currentHint
  keyword "end"
  _ <- liftIO $ popFromCurrentLocalLocator axis m
  liftIO $ modifyIORef' isPrivateStackRef tail
  return $ WeakStmtSection m sectionName stmtList

-- define name (x1 : A1) ... (xn : An) : A = e
parseDefine :: Axis -> Opacity -> Parser WeakStmt
parseDefine axis opacity = do
  m <- currentHint
  try $
    case opacity of
      OpacityOpaque ->
        keyword "define"
      OpacityTransparent ->
        keyword "define-inline"
  ((_, name), impArgs, expArgs, codType, e) <- parseTopDefInfo axis
  name' <- liftIO $ attachSectionPrefix name
  liftIO $ defineFunction axis opacity m name' (length impArgs) (impArgs ++ expArgs) codType e

defineFunction ::
  Axis ->
  Opacity ->
  Hint ->
  T.Text ->
  Int ->
  [BinderF WeakTerm] ->
  WeakTerm ->
  WeakTerm ->
  IO WeakStmt
defineFunction axis opacity m name impArgNum binder codType e = do
  registerTopLevelName axis m name
  return $ WeakStmtDefine opacity m name impArgNum binder codType e

parseDefineData :: Axis -> Parser [WeakStmt]
parseDefineData axis = do
  m <- currentHint
  try $ keyword "define-data"
  a <- var >>= liftIO . attachSectionPrefix . snd
  dataArgs <- argList $ weakAscription axis
  consInfoList <- asBlock $ manyList $ parseDefineDataClause axis
  liftIO $ defineData axis m a dataArgs consInfoList

defineData ::
  Axis ->
  Hint ->
  T.Text ->
  [BinderF WeakTerm] ->
  [(Hint, T.Text, [BinderF WeakTerm])] ->
  IO [WeakStmt]
defineData axis m dataName dataArgs consInfoList = do
  consInfoList' <- mapM (modifyConstructorName dataName) consInfoList
  setAsData dataName (length dataArgs) consInfoList'
  let consType = m :< WeakTermPi [] (m :< WeakTermTau)
  formRule <- defineFunction axis OpacityOpaque m dataName 0 dataArgs (m :< WeakTermTau) consType
  introRuleList <- mapM (parseDefineDataConstructor axis dataName dataArgs) $ zip consInfoList' [0 ..]
  return $ formRule : introRuleList

modifyConstructorName :: T.Text -> (Hint, T.Text, [BinderF WeakTerm]) -> IO (Hint, T.Text, [BinderF WeakTerm])
modifyConstructorName dataName (mb, b, yts) = do
  return (mb, dataName <> nsSep <> b, yts)

parseDefineDataConstructor ::
  Axis ->
  T.Text ->
  [BinderF WeakTerm] ->
  ((Hint, T.Text, [BinderF WeakTerm]), Integer) ->
  IO WeakStmt
parseDefineDataConstructor axis dataName dataArgs ((m, consName, consArgs), consNumber) = do
  let dataConsArgs = dataArgs ++ consArgs
  let consArgs' = map identPlusToVar consArgs
  let dataType = constructDataType m dataName dataArgs
  defineFunction
    axis
    OpacityTransparent
    m
    consName
    (length dataArgs)
    dataConsArgs
    dataType
    $ m
      :< WeakTermPiIntro
        (LamKindCons dataName consName consNumber dataType)
        [ (m, Ident.fromText consName, m :< WeakTermPi consArgs (m :< WeakTermTau))
        ]
        (m :< WeakTermPiElim (weakVar m consName) consArgs')

constructDataType :: Hint -> T.Text -> [BinderF WeakTerm] -> WeakTerm
constructDataType m dataName dataArgs =
  m :< WeakTermPiElim (m :< WeakTermVarGlobal dataName) (map identPlusToVar dataArgs)

parseDefineDataClause :: Axis -> Parser (Hint, T.Text, [BinderF WeakTerm])
parseDefineDataClause axis = do
  m <- currentHint
  b <- symbol
  yts <- argList $ parseDefineDataClauseArg axis
  return (m, b, yts)

parseDefineDataClauseArg :: Axis -> Parser (BinderF WeakTerm)
parseDefineDataClauseArg axis = do
  m <- currentHint
  choice
    [ try (weakAscription axis),
      weakTermToWeakIdent m (weakTerm axis)
    ]

parseDefineCodata :: Axis -> Parser [WeakStmt]
parseDefineCodata axis = do
  m <- currentHint
  try $ keyword "define-codata"
  dataName <- var >>= liftIO . attachSectionPrefix . snd
  dataArgs <- argList $ weakAscription axis
  elemInfoList <- asBlock $ manyList $ weakAscription axis
  formRule <- liftIO $ defineData axis m dataName dataArgs [(m, "new", elemInfoList)]
  elimRuleList <- liftIO $ mapM (parseDefineCodataElim axis dataName dataArgs elemInfoList) elemInfoList
  return $ formRule ++ elimRuleList

parseDefineCodataElim :: Axis -> T.Text -> [BinderF WeakTerm] -> [BinderF WeakTerm] -> BinderF WeakTerm -> IO WeakStmt
parseDefineCodataElim axis dataName dataArgs elemInfoList (m, elemName, elemType) = do
  let codataType = constructDataType m dataName dataArgs
  recordVarText <- newText
  let projArgs = dataArgs ++ [(m, Ident.fromText recordVarText, codataType)]
  let elemName' = dataName <> nsSep <> Ident.toText elemName
  defineFunction
    axis
    OpacityOpaque
    m
    elemName'
    (length dataArgs)
    projArgs
    elemType
    $ m
      :< WeakTermMatch
        Nothing
        (weakVar m recordVarText, codataType)
        [((m, dataName <> nsSep <> "new", elemInfoList), weakVar m (Ident.toText elemName))]

parseDefineResource :: Axis -> Parser WeakStmt
parseDefineResource axis = do
  m <- currentHint
  try $ keyword "define-resource"
  name <- snd <$> var
  asBlock $ do
    discarder <- delimiter "-" >> weakTerm axis
    copier <- delimiter "-" >> weakTerm axis
    liftIO $ registerTopLevelName axis m name
    liftIO $ modifyIORef' resourceTypeSetRef $ S.insert name
    return $ WeakStmtDefineResource m name discarder copier

setAsData :: T.Text -> Int -> [(Hint, T.Text, [BinderF WeakTerm])] -> IO ()
setAsData dataName dataArgNum consInfoList = do
  let consNameList = map (\(_, consName, _) -> consName) consInfoList
  modifyIORef' dataEnvRef $ Map.insert dataName consNameList
  forM_ consNameList $ \consName ->
    modifyIORef' constructorEnvRef $ Map.insert consName dataArgNum

identPlusToVar :: BinderF WeakTerm -> WeakTerm
identPlusToVar (m, x, _) =
  m :< WeakTermVar x

registerTopLevelName :: Axis -> Hint -> T.Text -> IO ()
registerTopLevelName axis m x = do
  topNameSet <- readIORef topNameSetRef
  when (S.member x topNameSet) $
    (axis & throw & Throw.raiseError) m $ "the variable `" <> x <> "` is already defined at the top level"
  modifyIORef' topNameSetRef $ S.insert x
  isPrivate <- checkIfPrivate
  when isPrivate $
    modifyIORef' privateNameSetRef $ S.insert x

checkIfPrivate :: IO Bool
checkIfPrivate = do
  isPrivateStack <- readIORef isPrivateStackRef
  if null isPrivateStack
    then return False
    else return $ head isPrivateStack

{-# NOINLINE isPrivateStackRef #-}
isPrivateStackRef :: IORef [Bool]
isPrivateStackRef =
  unsafePerformIO (newIORef [])

{-# NOINLINE privateNameSetRef #-}
privateNameSetRef :: IORef (S.Set T.Text)
privateNameSetRef =
  unsafePerformIO (newIORef S.empty)

weakTermToWeakIdent :: Hint -> Parser WeakTerm -> Parser (BinderF WeakTerm)
weakTermToWeakIdent m f = do
  a <- f
  h <- liftIO $ newTextualIdentFromText "_"
  return (m, h, a)
