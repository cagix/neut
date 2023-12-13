module Scene.Parse.RawTerm
  ( rawExpr,
    preAscription,
    preBinder,
    parseTopDefInfo,
    parseDeclareItem,
    parseDefInfoCod,
    typeWithoutIdent,
    preVar,
    parseName,
    lowType,
    f,
  )
where

import Context.App
import Context.Decl qualified as Decl
import Context.Env qualified as Env
import Context.Gensym qualified as Gensym
import Context.Throw qualified as Throw
import Control.Comonad.Cofree
import Control.Monad
import Control.Monad.Trans
import Data.Set qualified as S
import Data.Text qualified as T
import Data.Vector qualified as V
import Entity.BaseName qualified as BN
import Entity.C
import Entity.Const
import Entity.DeclarationName qualified as DN
import Entity.DefiniteDescription qualified as DD
import Entity.ExternalName qualified as EN
import Entity.Hint
import Entity.Key
import Entity.LowType qualified as LT
import Entity.Name
import Entity.PrimType qualified as PT
import Entity.PrimType.FromText qualified as PT
import Entity.RawBinder
import Entity.RawDecl qualified as RDE
import Entity.RawIdent
import Entity.RawPattern qualified as RP
import Entity.RawTerm qualified as RT
import Entity.WeakPrim qualified as WP
import Entity.WeakPrimValue qualified as WPV
import Scene.Parse.Core
import Text.Megaparsec

rawExpr :: Parser (RT.RawTerm, C)
rawExpr = do
  m <- getCurrentHint
  choice
    [ rawExprLet m,
      rawExprSeqOrTerm m
    ]

rawExprLet :: Hint -> Parser (RT.RawTerm, C)
rawExprLet m = do
  choice
    [ rawTermLet m,
      rawTermUse m
    ]

rawExprSeqOrTerm :: Hint -> Parser (RT.RawTerm, C)
rawExprSeqOrTerm m = do
  e1 <- rawTerm
  choice
    [ do
        c1 <- delimiter' ";"
        (e2, c2) <- rawExpr
        return (m :< RT.Seq e1 c1 e2, c2),
      return e1
    ]

rawTerm :: Parser (RT.RawTerm, C)
rawTerm = do
  choice
    [ try rawTermPiGeneral,
      try rawTermPiIntro,
      rawTermPiOrConsOrAscOrBasic
    ]

rawTermBasic :: Parser (RT.RawTerm, C)
rawTermBasic = do
  choice
    [ rawTermDefine,
      rawTermPiElimExact,
      rawTermIntrospect,
      rawTermMagic,
      rawTermMatch,
      rawTermIf,
      rawTermWhen,
      rawTermAssert,
      rawTermNoema,
      rawTermFlowIntro,
      rawTermFlowElim,
      rawTermOption,
      rawTermEmbody,
      rawTermWith,
      rawTermPiElimOrSimple
    ]

{-# INLINE rawTermSimple #-}
rawTermSimple :: Parser (RT.RawTerm, C)
rawTermSimple = do
  choice
    [ rawTermBrace,
      rawTermListIntro,
      rawTermTextIntro,
      rawTermTau,
      rawTermAdmit,
      rawTermHole,
      rawTermInteger,
      rawTermFloat,
      rawTermSymbol
    ]

rawTermPiGeneral :: Parser (RT.RawTerm, C)
rawTermPiGeneral = do
  m <- getCurrentHint
  impArgs <- parseImplicitArgs
  expArgs <- argList'' (choice [try preAscription, typeWithoutIdent])
  cArrow <- delimiter' "->"
  (cod, c) <- rawTerm
  return (m :< RT.Pi impArgs expArgs cArrow cod, c)

rawTermPiIntro :: Parser (RT.RawTerm, C)
rawTermPiIntro = do
  m <- getCurrentHint
  impArgs <- parseImplicitArgs
  expArgs <- argList'' preBinder
  c1 <- delimiter' "=>"
  (e, c) <- rawExpr
  return (m :< RT.PiIntro impArgs expArgs c1 e, c)

rawTermPiOrConsOrAscOrBasic :: Parser (RT.RawTerm, C)
rawTermPiOrConsOrAscOrBasic = do
  m <- getCurrentHint
  basic <- rawTermBasic
  choice
    [ do
        cArrow <- delimiter' "->"
        x <- lift Gensym.newTextForHole
        (cod, c) <- rawTerm
        return (m :< RT.Pi ([], []) ([([], (m, x, [], [], basic))], []) cArrow cod, c),
      return basic
    ]

rawTermKeyValuePair :: Parser (Hint, Key, C, C, (RT.RawTerm, C))
rawTermKeyValuePair = do
  ((m, key), c1) <- var
  choice
    [ do
        c2 <- delimiter' "="
        value <- rawExpr
        return (m, key, c1, c2, value),
      do
        return (m, key, c1, [], (m :< RT.Var (Var key), []))
    ]

rawTermLet :: Hint -> Parser (RT.RawTerm, C)
rawTermLet mLet = do
  (letKind, c1) <-
    choice
      [ keyword' "let" >>= \c1 -> return (RT.Plain, c1),
        keyword' "try" >>= \c1 -> return (RT.Try, c1),
        keyword' "bind" >>= \c1 -> return (RT.Bind, c1),
        keyword' "tie" >>= \c1 -> return (RT.Noetic, c1)
      ]
  ((mx, patInner), c2) <- rawTermPattern
  (c3, t) <- rawTermLetVarAscription mx
  noeticVarList <-
    choice
      [ commaList' (keyword' "on") rawTermNoeticVar,
        return []
      ]
  lift $ ensureIdentLinearity S.empty $ map (fst . snd) noeticVarList
  c5 <- delimiter' "="
  (e1, _) <- rawExpr
  c6 <- delimiter' "in"
  (e2, _) <- rawExpr
  return (mLet :< RT.Let letKind c1 (mx, patInner, c2, c3, t) noeticVarList c5 e1 c6 e2, [])

rawTermUse :: Hint -> Parser (RT.RawTerm, C)
rawTermUse m = do
  c1 <- keyword' "use"
  (e, c2) <- rawTerm
  xs@(ys, _) <- argListBrace preBinder
  c3 <- delimiter' "in"
  lift $ ensureIdentLinearity S.empty $ map (\(_, (mx, x, _, _, _)) -> (mx, x)) ys
  (cont, c) <- rawExpr
  return (m :< RT.Use c1 e c2 xs c3 cont, c)

rawTermLetVarAscription :: Hint -> Parser (C, (RT.RawTerm, C))
rawTermLetVarAscription m = do
  (c, mtc) <- rawTermLetVarAscription'
  case mtc of
    Just tc ->
      return (c, tc)
    Nothing -> do
      t <- lift $ Gensym.newPreHole m
      return (c, (t, []))

rawTermLetVarAscription' :: Parser (C, Maybe (RT.RawTerm, C))
rawTermLetVarAscription' =
  choice
    [ try $ do
        c <- delimiter' ":"
        tc <- rawTerm
        return (c, Just tc),
      return ([], Nothing)
    ]

ensureIdentLinearity :: S.Set RawIdent -> [(Hint, RawIdent)] -> App ()
ensureIdentLinearity foundVarSet vs =
  case vs of
    [] ->
      return ()
    (m, name) : rest
      | S.member name foundVarSet ->
          Throw.raiseError m $ "found a non-linear occurrence of `" <> name <> "`."
      | otherwise ->
          ensureIdentLinearity (S.insert name foundVarSet) rest

rawTermNoeticVar :: Parser ((Hint, T.Text), C)
rawTermNoeticVar = do
  ((m, x), c) <- var
  return ((m, x), c)

rawTermEmbody :: Parser (RT.RawTerm, C)
rawTermEmbody = do
  m <- getCurrentHint
  c1 <- delimiter' "*"
  (e, c) <- rawTermBasic
  return (m :< RT.Embody e, c1 ++ c)

rawTermTau :: Parser (RT.RawTerm, C)
rawTermTau = do
  m <- getCurrentHint
  c <- keyword' "tau"
  return (m :< RT.Tau, c)

rawTermHole :: Parser (RT.RawTerm, C)
rawTermHole = do
  m <- getCurrentHint
  c <- keyword' "_"
  h <- lift $ Gensym.newPreHole m
  return (h, c)

parseDefInfo :: Hint -> Parser (RT.DefInfo RT.RawTerm, C)
parseDefInfo m = do
  (functionVar, c1) <- var
  impArgs <- parseImplicitArgs
  expArgs <- argList'' preBinder
  (c6, codType) <- parseDefInfoCod m
  (c7, (e, c)) <- betweenBrace' rawExpr
  return ((functionVar, c1, impArgs, expArgs, c6, codType, c7, e), c)

parseTopDefInfo :: Parser RT.TopDefInfo
parseTopDefInfo = do
  topDefHeader <- parseTopDefHeader
  (e, _) <- betweenBrace rawExpr
  return (topDefHeader, e)

parseTopDefHeader :: Parser RT.TopDefHeader
parseTopDefHeader = do
  m <- getCurrentHint
  funcBaseName <- baseName
  impArgs <- parseImplicitArgs
  expDomArgList <- argSeqOrList preBinder
  lift $ ensureArgumentLinearity S.empty $ map (\(mx, x, _, _, _) -> (mx, x)) expDomArgList
  (_, codType) <- parseDefInfoCod m
  return ((m, funcBaseName), map (f . snd) $ fst impArgs, map f expDomArgList, fst codType)

parseDeclareItem :: (BN.BaseName -> App DD.DefiniteDescription) -> Parser RDE.RawDecl
parseDeclareItem nameLifter = do
  loc <- getCurrentHint
  name <- baseName >>= lift . nameLifter
  (isConstLike, impArgs, expArgs) <-
    choice
      [ do
          impArgs <- parseImplicitArgs
          choice
            [ do
                expDomArgList <- argSeqOrList preBinder
                return (False, impArgs, expDomArgList),
              return (True, impArgs, [])
            ],
        do
          return (True, ([], []), [])
      ]
  delimiter ":"
  cod <- fst <$> rawTerm
  let impArgs' = map snd $ fst impArgs
  return RDE.RawDecl {loc, name, isConstLike, impArgs = impArgs', expArgs, cod}

parseImplicitArgs :: Parser ([(C, RawBinder (RT.RawTerm, C))], C)
parseImplicitArgs =
  choice
    [ parseImplicitArgs',
      return ([], [])
    ]

parseImplicitArgs' :: Parser ([(C, RawBinder (RT.RawTerm, C))], C)
parseImplicitArgs' =
  argListAngle preBinder

ensureArgumentLinearity :: S.Set RawIdent -> [(Hint, RawIdent)] -> App ()
ensureArgumentLinearity foundVarSet vs =
  case vs of
    [] ->
      return ()
    (m, name) : rest
      | S.member name foundVarSet ->
          Throw.raiseError m $ "found a non-linear occurrence of `" <> name <> "`."
      | otherwise ->
          ensureArgumentLinearity (S.insert name foundVarSet) rest

parseDefInfoCod :: Hint -> Parser (C, (RT.RawTerm, C))
parseDefInfoCod m =
  choice
    [ do
        c <- delimiter' ":"
        t <- rawTerm
        return (c, t),
      do
        h <- lift $ Gensym.newPreHole m
        return ([], (h, []))
    ]

rawTermDefine :: Parser (RT.RawTerm, C)
rawTermDefine = do
  m <- getCurrentHint
  c0 <- keyword' "define"
  (defInfo, c) <- parseDefInfo m
  return (m :< RT.PiIntroFix c0 defInfo, c)

rawTermMagic :: Parser (RT.RawTerm, C)
rawTermMagic = do
  m <- getCurrentHint
  c <- keyword' "magic"
  choice
    [ rawTermMagicCast m c,
      rawTermMagicStore m c,
      rawTermMagicLoad m c,
      rawTermMagicExternal m c,
      rawTermMagicGlobal m c
    ]

rawTermMagicBase :: T.Text -> Parser (C -> C -> a) -> Parser (a, C)
rawTermMagicBase k parser = do
  c1 <- keyword' k
  (c2, (magicF, c3)) <- betweenParen' parser
  return (magicF c1 c2, c3)

rawTermMagicCast :: Hint -> C -> Parser (RT.RawTerm, C)
rawTermMagicCast m c = do
  rawTermMagicBase "cast" $ do
    castFrom <- rawTerm
    c3 <- delimiter' ","
    castTo <- rawTerm
    c4 <- delimiter' ","
    value <- rawTerm
    return $ \c1 c2 -> m :< RT.Magic c (RT.Cast c1 (c2, castFrom) (c3, castTo) (c4, value))

rawTermMagicStore :: Hint -> C -> Parser (RT.RawTerm, C)
rawTermMagicStore m c = do
  rawTermMagicBase "store" $ do
    lt <- lowType
    c3 <- delimiter' ","
    value <- rawTerm
    c4 <- delimiter' ","
    pointer <- rawTerm
    return $ \c1 c2 -> m :< RT.Magic c (RT.Store c1 (c2, lt) (c3, value) (c4, pointer))

rawTermMagicLoad :: Hint -> C -> Parser (RT.RawTerm, C)
rawTermMagicLoad m c = do
  rawTermMagicBase "load" $ do
    lt <- lowType
    c3 <- delimiter' ","
    pointer <- rawTerm
    return $ \c1 c2 -> m :< RT.Magic c (RT.Load c1 (c2, lt) (c3, pointer))

rawTermMagicExternal :: Hint -> C -> Parser (RT.RawTerm, C)
rawTermMagicExternal m c = do
  rawTermMagicBase "external" $ do
    (extFunName, cExt) <- symbol'
    let extFunName' = EN.ExternalName extFunName
    es <- many $ do
      c3 <- delimiter' ","
      e <- rawTerm
      return (c3, e)
    varArgAndTypeList <-
      choice
        [ commaList' (delimiter' ";") rawTermAndLowType,
          return []
        ]
    (domList, cod) <- lift $ Decl.lookupDeclEnv m (DN.Ext extFunName')
    return $ \c1 c2 -> m :< RT.Magic c (RT.External c1 domList cod (c2, (extFunName', cExt)) es varArgAndTypeList)

rawTermAndLowType :: Parser ((RT.RawTerm, C), (LT.LowType, C))
rawTermAndLowType = do
  e <- rawTerm
  t <- lowType
  return (e, t)

rawTermMagicGlobal :: Hint -> C -> Parser (RT.RawTerm, C)
rawTermMagicGlobal m c = do
  rawTermMagicBase "global" $ do
    (globalVarName, c3) <- string'
    c4 <- delimiter' ","
    lt <- lowType
    return $ \c1 c2 -> m :< RT.Magic c (RT.Global c1 c2 (EN.ExternalName globalVarName, c3) c4 lt)

lowType :: Parser (LT.LowType, C)
lowType = do
  choice
    [ lowTypePointer,
      lowTypeVoid,
      lowTypeNumber
    ]

lowTypePointer :: Parser (LT.LowType, C)
lowTypePointer = do
  c <- keyword' "pointer"
  return (LT.Pointer, c)

lowTypeVoid :: Parser (LT.LowType, C)
lowTypeVoid = do
  c <- keyword' "void"
  return (LT.Void, c)

lowTypeNumber :: Parser (LT.LowType, C)
lowTypeNumber = do
  (pt, c) <- primType
  return (LT.PrimNum pt, c)

primType :: Parser (PT.PrimType, C)
primType = do
  m <- getCurrentHint
  (sizeString, c) <- symbol'
  dataSize <- lift $ Env.getDataSize m
  case PT.fromText dataSize sizeString of
    Just primNum ->
      return (primNum, c)
    _ -> do
      failure (Just (asTokens sizeString)) (S.fromList [asLabel "i{n}", asLabel "f{n}"])

rawTermMatch :: Parser (RT.RawTerm, C)
rawTermMatch = do
  m <- getCurrentHint
  (c1, isNoetic) <-
    choice
      [ do
          c1 <- try (keyword' "case")
          return (c1, True),
        do
          c1 <- keyword' "match"
          return (c1, False)
      ]
  es <- sepList spaceConsumer' (delimiter' ",") rawTermBasic
  (c2, (patternRowList, c3)) <- betweenBrace' $ manyList' $ rawTermPatternRow (length es)
  return (m :< RT.DataElim c1 isNoetic es c2 (RP.new patternRowList), c3)

rawTermPatternRow :: Int -> Parser (RP.RawPatternRow (RT.RawTerm, C))
rawTermPatternRow patternSize = do
  m <- getCurrentHint
  patternList <- commaList' spaceConsumer' rawTermPattern
  unless (length patternList == patternSize) $ do
    lift $
      Throw.raiseError m $
        "the size of the pattern row `"
          <> T.pack (show (length patternList))
          <> "` doesn't match with its input size `"
          <> T.pack (show patternSize)
          <> "`"
          <> "\n"
          <> T.pack (show patternList)
  c <- delimiter' "=>"
  body <- rawExpr
  return (V.fromList patternList, c, body)

rawTermPattern :: Parser ((Hint, RP.RawPattern), C)
rawTermPattern = do
  rawTermPatternBasic

rawTermPatternBasic :: Parser ((Hint, RP.RawPattern), C)
rawTermPatternBasic =
  choice
    [ rawTermPatternListIntro,
      rawTermPatternConsOrVar
    ]

rawTermPatternListIntro :: Parser ((Hint, RP.RawPattern), C)
rawTermPatternListIntro = do
  m <- getCurrentHint
  (patList, c) <- argListBracket rawTermPattern
  return ((m, RP.ListIntro patList), c)

parseName :: Parser ((Hint, Name), C)
parseName = do
  ((m, varText), c) <- var
  v <- interpretVarName m varText
  return (v, c)

rawTermPatternConsOrVar :: Parser ((Hint, RP.RawPattern), C)
rawTermPatternConsOrVar = do
  ((m, varOrLocator), c1) <- parseName
  choice
    [ do
        (patArgs, c) <- argList'' rawTermPattern
        return ((m, RP.Cons varOrLocator c1 (RP.Paren patArgs)), c),
      do
        c2 <- keyword' "of"
        (c3, (kvs, c)) <- betweenBrace' $ bulletListOrCommaSeq rawTermPatternKeyValuePair
        return ((m, RP.Cons varOrLocator c1 (RP.Of c2 c3 kvs)), c),
      do
        return ((m, RP.Var varOrLocator), [])
    ]

rawTermPatternKeyValuePair :: Parser (Key, ((Hint, RP.RawPattern), C))
rawTermPatternKeyValuePair = do
  mFrom <- getCurrentHint
  (from, c1) <- symbol'
  choice
    [ do
        c2 <- delimiter' "="
        (to, c) <- rawTermPattern
        return (from, (to, c1 ++ c2 ++ c)),
      do
        return (from, ((mFrom, RP.Var (Var from)), [])) -- record rhyming
    ]

rawTermIf :: Parser (RT.RawTerm, C)
rawTermIf = do
  m <- getCurrentHint
  c1 <- keyword' "if"
  ifCond <- rawTerm
  (c2, (ifBody, c3)) <- betweenBrace' rawExpr
  elseIfList <- many $ do
    cElif1 <- keyword' "else-if"
    elseIfCond <- rawTerm
    (cElif2, (elseIfBody, cElif3)) <- betweenBrace' rawExpr
    return (cElif1, elseIfCond, cElif2, elseIfBody, cElif3)
  c4 <- keyword' "else"
  (c5, (elseBody, c)) <- betweenBrace' rawExpr
  return (m :< RT.If (c1, ifCond, c2, ifBody, c3) elseIfList c4 c5 elseBody, c)

rawTermWhen :: Parser (RT.RawTerm, C)
rawTermWhen = do
  m <- getCurrentHint
  c1 <- keyword' "when"
  whenCond <- rawTerm
  (c2, (whenBody, c)) <- betweenBrace' rawExpr
  return (m :< RT.When c1 whenCond c2 whenBody, c)

rawTermBrace :: Parser (RT.RawTerm, C)
rawTermBrace = do
  m <- getCurrentHint
  (c1, (e, c)) <- betweenBrace' rawExpr
  return (m :< RT.Brace c1 e, c)

rawTermWith :: Parser (RT.RawTerm, C)
rawTermWith = do
  m <- getCurrentHint
  c1 <- keyword' "with"
  (binder, c2) <- rawTerm
  (c3, (body, c)) <- betweenBrace' rawExpr
  return (m :< RT.With c1 binder c2 c3 body, c)

rawTermNoema :: Parser (RT.RawTerm, C)
rawTermNoema = do
  m <- getCurrentHint
  c1 <- delimiter' "&"
  (t, c) <- rawTermBasic
  return (m :< RT.Noema t, c1 ++ c)

rawTermFlowIntro :: Parser (RT.RawTerm, C)
rawTermFlowIntro = do
  m <- getCurrentHint
  c1 <- keyword' "detach"
  (c2, (e, c)) <- betweenBrace' rawExpr
  return (m :< RT.Detach c1 c2 e, c)

rawTermFlowElim :: Parser (RT.RawTerm, C)
rawTermFlowElim = do
  m <- getCurrentHint
  c1 <- keyword' "attach"
  (c2, (e, c)) <- betweenBrace' rawExpr
  return (m :< RT.Attach c1 c2 e, c)

rawTermOption :: Parser (RT.RawTerm, C)
rawTermOption = do
  m <- getCurrentHint
  c1 <- delimiter' "?"
  (t, c) <- rawTermBasic
  return (m :< RT.Option c1 t, c)

rawTermAdmit :: Parser (RT.RawTerm, C)
rawTermAdmit = do
  m <- getCurrentHint
  c <- keyword' "admit"
  return (m :< RT.Admit, c)

rawTermAssert :: Parser (RT.RawTerm, C)
rawTermAssert = do
  m <- getCurrentHint
  c1 <- keyword' "assert"
  mText <- getCurrentHint
  (message, c2) <- string'
  (c3, (e, c)) <- betweenBrace' rawExpr
  return (m :< RT.Assert c1 (mText, message) c2 c3 e, c)

rawTermPiElimOrSimple :: Parser (RT.RawTerm, C)
rawTermPiElimOrSimple = do
  m <- getCurrentHint
  ec@(e, c1) <- rawTermSimple
  case e of
    _ :< RT.Var name -> do
      choice
        [ do
            c2 <- keyword' "of"
            (c3, (kvs, c4)) <- betweenBrace' $ do
              choice
                [ someList' rawTermKeyValuePair,
                  commaList' spaceConsumer' rawTermKeyValuePair
                ]
            return (m :< RT.PiElimByKey name c1 c2 c3 kvs, c4),
          rawTermPiElimCont m ec
        ]
    _ -> do
      rawTermPiElimCont m ec

rawTermPiElimCont :: Hint -> (RT.RawTerm, C) -> Parser (RT.RawTerm, C)
rawTermPiElimCont m ec = do
  argListList <- many $ argList'' rawExpr
  return $ foldPiElim m ec argListList

foldPiElim ::
  Hint ->
  (RT.RawTerm, C) ->
  [([RT.EL RT.RawTerm], C)] ->
  (RT.RawTerm, C)
foldPiElim m (e, c) argListList =
  case argListList of
    [] ->
      (e, c)
    (args, c1) : rest ->
      foldPiElim m (m :< RT.PiElim e c args, c1) rest

preBinder :: Parser (RawBinder (RT.RawTerm, C))
preBinder =
  choice
    [ try preAscription,
      preAscription'
    ]

preAscription :: Parser (RawBinder (RT.RawTerm, C))
preAscription = do
  ((m, x), c1) <- var
  c2 <- delimiter' ":"
  (a, c) <- rawTerm
  return (m, x, c1, c2, (a, c))

typeWithoutIdent :: Parser (RawBinder (RT.RawTerm, C))
typeWithoutIdent = do
  m <- getCurrentHint
  x <- lift Gensym.newTextForHole
  (t, c) <- rawTerm
  return (m, x, [], [], (t, c))

preAscription' :: Parser (RawBinder (RT.RawTerm, C))
preAscription' = do
  ((m, x), c) <- var
  h <- lift $ Gensym.newPreHole m
  return (m, x, c, [], (h, []))

rawTermListIntro :: Parser (RT.RawTerm, C)
rawTermListIntro = do
  m <- getCurrentHint
  (es, c) <- argListBracket rawExpr
  return (m :< RT.ListIntro es, c)

rawTermPiElimExact :: Parser (RT.RawTerm, C)
rawTermPiElimExact = do
  m <- getCurrentHint
  c1 <- keyword' "exact"
  (e, c) <- rawTerm
  return (m :< RT.PiElimExact c1 e, c)

rawTermIntrospect :: Parser (RT.RawTerm, C)
rawTermIntrospect = do
  m <- getCurrentHint
  c1 <- keyword' "introspect"
  (key, c2) <- symbol'
  (c3, (clauseList, c)) <- betweenBrace' $ manyList' rawTermIntrospectiveClause
  return (m :< RT.Introspect c1 key c2 c3 clauseList, c)

rawTermIntrospectiveClause :: Parser (Maybe T.Text, C, (RT.RawTerm, C))
rawTermIntrospectiveClause = do
  s <- symbol
  c <- delimiter' "=>"
  body <- rawExpr
  if s /= "default"
    then return (Just s, c, body)
    else return (Nothing, c, body)

rawTermSymbol :: Parser (RT.RawTerm, C)
rawTermSymbol = do
  ((m, varOrLocator), c) <- parseVarName
  return (m :< RT.Var varOrLocator, c)

parseVarName :: Parser ((Hint, Name), C)
parseVarName = do
  ((m, varText), c) <- var
  v <- interpretVarName m varText
  return (v, c)

interpretVarName :: Hint -> T.Text -> Parser (Hint, Name)
interpretVarName m varText = do
  case DD.getLocatorPair m varText of
    Left _ ->
      return (m, Var varText)
    Right (gl, ll) ->
      return (m, Locator (gl, ll))

rawTermTextIntro :: Parser (RT.RawTerm, C)
rawTermTextIntro = do
  m <- getCurrentHint
  (s, c) <- string'
  textType <- lift $ locatorToVarGlobal m coreText
  return (m :< RT.Prim (WP.Value (WPV.StaticText textType s)), c)

rawTermInteger :: Parser (RT.RawTerm, C)
rawTermInteger = do
  m <- getCurrentHint
  (intValue, c) <- try integer'
  h <- lift $ Gensym.newPreHole m
  return (m :< RT.Prim (WP.Value (WPV.Int h intValue)), c)

rawTermFloat :: Parser (RT.RawTerm, C)
rawTermFloat = do
  m <- getCurrentHint
  (floatValue, c) <- try float'
  h <- lift $ Gensym.newPreHole m
  return (m :< RT.Prim (WP.Value (WPV.Float h floatValue)), c)

preVar :: Hint -> T.Text -> RT.RawTerm
preVar m str =
  rawVar m (Var str)

locatorToVarGlobal :: Hint -> T.Text -> App RT.RawTerm
locatorToVarGlobal m text = do
  (gl, ll) <- Throw.liftEither $ DD.getLocatorPair (blur m) text
  return $ rawVar (blur m) (Locator (gl, ll))

rawVar :: Hint -> Name -> RT.RawTerm
rawVar m name =
  m :< RT.Var name

f :: RawBinder (a, C) -> RawBinder a
f (m, x, c1, c2, (t, _)) =
  (m, x, c1, c2, t)
