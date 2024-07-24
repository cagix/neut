module Scene.Parse.Discern (discernStmtList) where

import Context.App
import Context.Decl qualified as Decl
import Context.Env qualified as Env
import Context.Gensym qualified as Gensym
import Context.Global qualified as Global
import Context.KeyArg qualified as KeyArg
import Context.Locator qualified as Locator
import Context.SymLoc qualified as SymLoc
import Context.Tag qualified as Tag
import Context.Throw qualified as Throw
import Context.TopCandidate qualified as TopCandidate
import Context.UnusedStaticFile qualified as UnusedStaticFile
import Context.UnusedVariable qualified as UnusedVariable
import Control.Comonad.Cofree hiding (section)
import Control.Monad
import Data.Containers.ListUtils qualified as ListUtils
import Data.HashMap.Strict qualified as Map
import Data.List
import Data.Set qualified as S
import Data.Text qualified as T
import Data.Vector qualified as V
import Entity.Annotation qualified as AN
import Entity.Arch qualified as Arch
import Entity.ArgNum qualified as AN
import Entity.Attr.Lam qualified as AttrL
import Entity.Attr.VarGlobal qualified as AttrVG
import Entity.BaseName qualified as BN
import Entity.Binder
import Entity.BuildMode qualified as BM
import Entity.C
import Entity.Const
import Entity.DeclarationName qualified as DN
import Entity.DefiniteDescription qualified as DD
import Entity.Error qualified as E
import Entity.Geist qualified as G
import Entity.GlobalName qualified as GN
import Entity.Hint
import Entity.Hint.Reify qualified as Hint
import Entity.Ident
import Entity.Ident.Reify qualified as Ident
import Entity.Key
import Entity.LamKind qualified as LK
import Entity.Layer
import Entity.Literal qualified as LI
import Entity.Locator qualified as L
import Entity.LowType qualified as LT
import Entity.LowType.FromRawLowType qualified as LT
import Entity.Magic qualified as M
import Entity.Module
import Entity.Name
import Entity.NecessityVariant
import Entity.Noema qualified as N
import Entity.NominalEnv
import Entity.OS qualified as OS
import Entity.Opacity qualified as O
import Entity.Pattern qualified as PAT
import Entity.Platform qualified as Platform
import Entity.RawBinder
import Entity.RawIdent hiding (isHole)
import Entity.RawLowType qualified as RLT
import Entity.RawPattern qualified as RP
import Entity.RawProgram
import Entity.RawTerm qualified as RT
import Entity.Remark qualified as R
import Entity.Rune qualified as RU
import Entity.Stmt
import Entity.StmtKind qualified as SK
import Entity.Syntax.Series qualified as SE
import Entity.Text.Util
import Entity.TopCandidate
import Entity.VarDefKind qualified as VDK
import Entity.WeakPrim qualified as WP
import Entity.WeakPrimValue qualified as WPV
import Entity.WeakTerm qualified as WT
import Entity.WeakTerm.FreeVars (freeVars)
import Scene.Parse.Discern.Data
import Scene.Parse.Discern.Name
import Scene.Parse.Discern.Noema
import Scene.Parse.Discern.NominalEnv
import Scene.Parse.Discern.PatternMatrix
import Scene.Parse.Discern.Struct
import Scene.Parse.Foreign
import Scene.Parse.Util
import Text.Read qualified as R

discernStmtList :: Module -> [RawStmt] -> App [WeakStmt]
discernStmtList mo =
  fmap concat . mapM (discernStmt mo)

discernStmt :: Module -> RawStmt -> App [WeakStmt]
discernStmt mo stmt = do
  nameLifter <- Locator.getNameLifter
  case stmt of
    RawStmtDefine _ stmtKind (RT.RawDef {geist, body, endLoc}) -> do
      registerTopLevelName nameLifter stmt
      let impArgs = RT.extractArgs $ RT.impArgs geist
      let expArgs = RT.extractArgs $ RT.expArgs geist
      let (_, codType) = RT.cod geist
      let m = RT.loc geist
      let functionName = nameLifter $ fst $ RT.name geist
      let isConstLike = RT.isConstLike geist
      (impArgs', nenv) <- discernBinder (emptyAxis mo 0) impArgs endLoc
      (expArgs', nenv') <- discernBinder nenv expArgs endLoc
      codType' <- discern nenv' codType
      stmtKind' <- discernStmtKind (emptyAxis mo 0) stmtKind
      body' <- discern nenv' body
      Tag.insertGlobalVar m functionName isConstLike m
      TopCandidate.insert $ TopCandidate {loc = metaLocation m, dd = functionName, kind = toCandidateKind stmtKind'}
      forM_ expArgs' Tag.insertBinder
      return [WeakStmtDefine isConstLike stmtKind' m functionName impArgs' expArgs' codType' body']
    RawStmtDefineConst _ m (name, _) (_, (t, _)) (_, (v, _)) -> do
      let dd = nameLifter name
      registerTopLevelName nameLifter stmt
      t' <- discern (emptyAxis mo 0) t
      v' <- discern (emptyAxis mo 0) v
      Tag.insertGlobalVar m dd True m
      TopCandidate.insert $ TopCandidate {loc = metaLocation m, dd = dd, kind = Constant}
      return [WeakStmtDefineConst m dd t' v']
    RawStmtDefineData _ m (dd, _) args consInfo loc -> do
      stmtList <- defineData m dd args (SE.extract consInfo) loc
      discernStmtList mo stmtList
    RawStmtDefineResource _ m (name, _) (_, discarder) (_, copier) _ -> do
      let dd = nameLifter name
      registerTopLevelName nameLifter stmt
      t' <- discern (emptyAxis mo 0) $ m :< RT.Tau
      e' <- discern (emptyAxis mo 0) $ m :< RT.Resource [] (discarder, []) (copier, [])
      Tag.insertGlobalVar m dd True m
      TopCandidate.insert $ TopCandidate {loc = metaLocation m, dd = dd, kind = Constant}
      return [WeakStmtDefineConst m dd t' e']
    RawStmtNominal _ m geistList -> do
      geistList' <- forM (SE.extract geistList) $ \(geist, endLoc) -> do
        Global.registerGeist geist
        discernGeist mo endLoc geist
      return [WeakStmtNominal m geistList']
    RawStmtForeign _ foreignList -> do
      foreign' <- interpretForeign foreignList
      activateForeign foreign'
      return [WeakStmtForeign foreign']

discernGeist :: Module -> Loc -> RT.TopGeist -> App (G.Geist WT.WeakTerm)
discernGeist mo endLoc geist = do
  nameLifter <- Locator.getNameLifter
  let impArgs = RT.extractArgs $ RT.impArgs geist
  let expArgs = RT.extractArgs $ RT.expArgs geist
  (impArgs', axis) <- discernBinder (emptyAxis mo 0) impArgs endLoc
  (expArgs', axis') <- discernBinder axis expArgs endLoc
  forM_ (impArgs' ++ expArgs') $ \(_, x, _) -> UnusedVariable.delete x
  cod' <- discern axis' $ snd $ RT.cod geist
  let m = RT.loc geist
  let dd = nameLifter $ fst $ RT.name geist
  let kind = if RT.isConstLike geist then Constant else Function
  TopCandidate.insert $ TopCandidate {loc = metaLocation m, dd = dd, kind = kind}
  return $
    G.Geist
      { loc = m,
        name = dd,
        isConstLike = RT.isConstLike geist,
        impArgs = impArgs',
        expArgs = expArgs',
        cod = cod'
      }

registerTopLevelName :: (BN.BaseName -> DD.DefiniteDescription) -> RawStmt -> App ()
registerTopLevelName nameLifter stmt =
  case stmt of
    RawStmtDefine _ stmtKind (RT.RawDef {geist}) -> do
      let impArgs = RT.extractArgs $ RT.impArgs geist
      let expArgs = RT.extractArgs $ RT.expArgs geist
      let m = RT.loc geist
      let functionName = nameLifter $ fst $ RT.name geist
      let isConstLike = RT.isConstLike geist
      let allArgNum = AN.fromInt $ length $ impArgs ++ expArgs
      let expArgNames = map (\(_, x, _, _, _) -> x) expArgs
      stmtKind' <- liftStmtKind stmtKind
      Global.registerStmtDefine isConstLike m stmtKind' functionName allArgNum expArgNames
    RawStmtDefineConst _ m (name, _) _ _ -> do
      Global.registerStmtDefine True m (SK.Normal O.Clear) (nameLifter name) AN.zero []
    RawStmtNominal {} -> do
      return ()
    RawStmtDefineData _ m (dd, _) args consInfo loc -> do
      stmtList <- defineData m dd args (SE.extract consInfo) loc
      mapM_ (registerTopLevelName nameLifter) stmtList
    RawStmtDefineResource _ m (name, _) _ _ _ -> do
      Global.registerStmtDefine True m (SK.Normal O.Clear) (nameLifter name) AN.zero []
    RawStmtForeign {} ->
      return ()

liftStmtKind :: SK.RawStmtKind BN.BaseName -> App (SK.RawStmtKind DD.DefiniteDescription)
liftStmtKind stmtKind = do
  case stmtKind of
    SK.Normal opacity ->
      return $ SK.Normal opacity
    SK.Data dataName dataArgs consInfoList -> do
      nameLifter <- Locator.getNameLifter
      let (locList, consNameList, isConstLikeList, consArgsList, discriminantList) = unzip5 consInfoList
      let consNameList' = map nameLifter consNameList
      let consInfoList' = zip5 locList consNameList' isConstLikeList consArgsList discriminantList
      return $ SK.Data (nameLifter dataName) dataArgs consInfoList'
    SK.DataIntro dataName dataArgs consArgs discriminant -> do
      nameLifter <- Locator.getNameLifter
      return $ SK.DataIntro (nameLifter dataName) dataArgs consArgs discriminant

discernStmtKind :: Axis -> SK.RawStmtKind BN.BaseName -> App (SK.StmtKind WT.WeakTerm)
discernStmtKind ax stmtKind =
  case stmtKind of
    SK.Normal opacity ->
      return $ SK.Normal opacity
    SK.Data dataName dataArgs consInfoList -> do
      nameLifter <- Locator.getNameLifter
      (dataArgs', axis) <- discernBinder' ax dataArgs
      let (locList, consNameList, isConstLikeList, consArgsList, discriminantList) = unzip5 consInfoList
      (consArgsList', axisList) <- mapAndUnzipM (discernBinder' axis) consArgsList
      forM_ (concatMap _nenv axisList) $ \(_, (_, newVar, _)) -> do
        UnusedVariable.delete newVar
      let consNameList' = map nameLifter consNameList
      let consInfoList' = zip5 locList consNameList' isConstLikeList consArgsList' discriminantList
      return $ SK.Data (nameLifter dataName) dataArgs' consInfoList'
    SK.DataIntro dataName dataArgs consArgs discriminant -> do
      nameLifter <- Locator.getNameLifter
      (dataArgs', axis) <- discernBinder' ax dataArgs
      (consArgs', axis') <- discernBinder' axis consArgs
      forM_ (_nenv axis') $ \(_, (_, newVar, _)) -> do
        UnusedVariable.delete newVar
      return $ SK.DataIntro (nameLifter dataName) dataArgs' consArgs' discriminant

toCandidateKind :: SK.StmtKind a -> CandidateKind
toCandidateKind stmtKind =
  case stmtKind of
    SK.Normal {} ->
      Function
    SK.Data {} ->
      Function
    SK.DataIntro {} ->
      Constructor

discern :: Axis -> RT.RawTerm -> App WT.WeakTerm
discern axis term =
  case term of
    m :< RT.Tau ->
      return $ m :< WT.Tau
    m :< RT.Var name ->
      case name of
        Var s
          | Just x <- R.readMaybe (T.unpack s) -> do
              h <- Gensym.newHole m []
              return $ m :< WT.Prim (WP.Value $ WPV.Int h x)
          | Just x <- readIntBinaryMaybe s -> do
              h <- Gensym.newHole m []
              return $ m :< WT.Prim (WP.Value $ WPV.Int h x)
          | Just x <- readIntOctalMaybe s -> do
              h <- Gensym.newHole m []
              return $ m :< WT.Prim (WP.Value $ WPV.Int h x)
          | Just x <- readIntHexadecimalMaybe s -> do
              h <- Gensym.newHole m []
              return $ m :< WT.Prim (WP.Value $ WPV.Int h x)
          | Just x <- R.readMaybe (T.unpack s) -> do
              h <- Gensym.newHole m []
              return $ m :< WT.Prim (WP.Value $ WPV.Float h x)
          | Just (mDef, name', layer) <- lookup s (_nenv axis) -> do
              if layer == currentLayer axis
                then do
                  UnusedVariable.delete name'
                  Tag.insertLocalVar m name' mDef
                  return $ m :< WT.Var name'
                else
                  raiseLayerError m (currentLayer axis) layer
        _ -> do
          (dd, (_, gn)) <- resolveName m name
          interpretGlobalName m dd gn
    m :< RT.Pi impArgs expArgs _ t endLoc -> do
      (impArgs', axis') <- discernBinder axis (RT.extractArgs impArgs) endLoc
      (expArgs', axis'') <- discernBinder axis' (RT.extractArgs expArgs) endLoc
      t' <- discern axis'' t
      forM_ (impArgs' ++ expArgs') $ \(_, x, _) -> UnusedVariable.delete x
      return $ m :< WT.Pi impArgs' expArgs' t'
    m :< RT.PiIntro _ (RT.RawDef {geist, body, endLoc}) -> do
      lamID <- Gensym.newCount
      let impArgs = RT.extractArgs $ RT.impArgs geist
      let expArgs = RT.extractArgs $ RT.expArgs geist
      (impArgs', axis') <- discernBinder axis impArgs endLoc
      (expArgs', axis'') <- discernBinder axis' expArgs endLoc
      codType' <- discern axis'' $ snd $ RT.cod geist
      body' <- discern axis'' body
      ensureLayerClosedness m axis'' body'
      return $ m :< WT.PiIntro (AttrL.normal lamID codType') impArgs' expArgs' body'
    m :< RT.PiIntroFix _ (RT.RawDef {geist, body, endLoc}) -> do
      let impArgs = RT.extractArgs $ RT.impArgs geist
      let expArgs = RT.extractArgs $ RT.expArgs geist
      let mx = RT.loc geist
      let (x, _) = RT.name geist
      (impArgs', axis') <- discernBinder axis impArgs endLoc
      (expArgs', axis'') <- discernBinder axis' expArgs endLoc
      codType' <- discern axis'' $ snd $ RT.cod geist
      x' <- Gensym.newIdentFromText x
      axis''' <- extendAxis mx x' VDK.Normal axis''
      body' <- discern axis''' body
      let mxt' = (mx, x', codType')
      Tag.insertBinder mxt'
      lamID <- Gensym.newCount
      ensureLayerClosedness m axis''' body'
      return $ m :< WT.PiIntro (AttrL.Attr {lamKind = LK.Fix mxt', identity = lamID}) impArgs' expArgs' body'
    m :< RT.PiElim e _ es -> do
      case e of
        _ :< RT.Var (Var c)
          | c == "new-cell",
            [arg] <- SE.extract es -> do
              newCellDD <- locatorToVarGlobal m coreCellNewCell
              e' <- discern axis $ m :< RT.piElim newCellDD [arg]
              return $ m :< WT.Actual e'
          | c == "new-channel",
            [] <- SE.extract es -> do
              newChannelDD <- locatorToVarGlobal m coreChannelNewChannel
              e' <- discern axis $ m :< RT.piElim newChannelDD []
              return $ m :< WT.Actual e'
        _ -> do
          es' <- mapM (discern axis) $ SE.extract es
          e' <- discern axis e
          return $ m :< WT.PiElim e' es'
    m :< RT.PiElimByKey name _ kvs -> do
      (dd, _) <- resolveName m name
      let (ks, vs) = unzip $ map (\(_, k, _, _, v) -> (k, v)) $ SE.extract kvs
      ensureFieldLinearity m ks S.empty S.empty
      (argNum, keyList) <- KeyArg.lookup m dd
      vs' <- mapM (discern axis) vs
      args <- KeyArg.reorderArgs m keyList $ Map.fromList $ zip ks vs'
      let isConstLike = False
      return $ m :< WT.PiElim (m :< WT.VarGlobal (AttrVG.Attr {..}) dd) args
    m :< RT.PiElimExact _ e -> do
      e' <- discern axis e
      return $ m :< WT.PiElimExact e'
    m :< RT.Data attr dataName es -> do
      nameLifter <- Locator.getNameLifter
      dataName' <- Locator.attachCurrentLocator dataName
      es' <- mapM (discern axis) es
      return $ m :< WT.Data (fmap nameLifter attr) dataName' es'
    m :< RT.DataIntro attr consName dataArgs consArgs -> do
      nameLifter <- Locator.getNameLifter
      dataArgs' <- mapM (discern axis) dataArgs
      consArgs' <- mapM (discern axis) consArgs
      return $ m :< WT.DataIntro (fmap nameLifter attr) (nameLifter consName) dataArgs' consArgs'
    m :< RT.DataElim _ isNoetic es patternMatrix -> do
      let es' = SE.extract es
      let ms = map (\(me :< _) -> me) es'
      os <- mapM (const $ Gensym.newIdentFromText "match") es' -- os: occurrences
      es'' <- mapM (discern axis >=> castFromNoemaIfNecessary isNoetic) es'
      ts <- mapM (const $ Gensym.newHole m []) es''
      patternMatrix' <- discernPatternMatrix axis $ SE.extract patternMatrix
      ensurePatternMatrixSanity patternMatrix'
      let os' = zip ms os
      decisionTree <- compilePatternMatrix (currentLayer axis) (_nenv axis) isNoetic (V.fromList os') patternMatrix'
      return $ m :< WT.DataElim isNoetic (zip3 os es'' ts) decisionTree
    m :< RT.Box t -> do
      t' <- discern axis t
      return $ m :< WT.Box t'
    m :< RT.BoxNoema t -> do
      t' <- discern axis t
      return $ m :< WT.BoxNoema t'
    m :< RT.BoxIntro _ _ mxs (body, _) -> do
      xsOuter <- forM (SE.extract mxs) $ \(mx, x) -> discernIdent mx axis x
      xets <- discernNoeticVarList xsOuter
      let innerLayer = currentLayer axis - 1
      let xsInner = map (\((mx, x, _), _) -> (mx, x)) xets
      let innerAddition = map (\(mx, x) -> (Ident.toText x, (mx, x, innerLayer))) xsInner
      axisInner <- extendAxisByNominalEnv VDK.Borrowed innerAddition (axis {currentLayer = innerLayer})
      body' <- discern axisInner body
      return $ m :< WT.BoxIntro xets body'
    m :< RT.BoxIntroQuote _ _ (body, _) -> do
      body' <- discern axis body
      return $ m :< WT.BoxIntroQuote body'
    m :< RT.BoxElim nv mustIgnoreRelayedVars _ mxt _ mys _ e1 _ startLoc _ e2 endLoc -> do
      -- inner
      ysOuter <- forM (SE.extract mys) $ \(my, y) -> discernIdent my axis y
      yetsInner <- discernNoeticVarList ysOuter
      let innerLayer = currentLayer axis + layerOffset nv
      let ysInner = map (\((my, y, myDef :< _), _) -> (myDef, (my, y))) yetsInner
      let innerAddition = map (\(_, (my, y)) -> (Ident.toText y, (my, y, innerLayer))) ysInner
      axisInner <- extendAxisByNominalEnv VDK.Borrowed innerAddition (axis {currentLayer = innerLayer})
      e1' <- discern axisInner e1
      -- cont
      yetsCont <- discernNoeticVarList ysInner
      let ysCont = map (\((my, y, _), _) -> (my, y)) yetsCont
      let contAddition = map (\(my, y) -> (Ident.toText y, (my, y, currentLayer axis))) ysCont
      axisCont <- extendAxisByNominalEnv VDK.Relayed contAddition axis
      (mxt', e2') <- discernBinderWithBody' axisCont mxt startLoc endLoc e2
      Tag.insertBinder mxt'
      when mustIgnoreRelayedVars $ do
        forM_ ysCont $ UnusedVariable.delete . snd
      return $ m :< WT.BoxElim yetsInner mxt' e1' yetsCont e2'
    m :< RT.Embody e -> do
      embodyVar <- locatorToVarGlobal m coreBoxEmbody
      discern axis $ m :< RT.piElim embodyVar [e]
    m :< RT.Let letKind _ (mx, pat, c1, c2, t) _ _ e1 _ startLoc _ e2 endLoc -> do
      discernLet axis m letKind (mx, pat, c1, c2, t) e1 e2 startLoc endLoc
    m :< RT.LetOn _ mxt _ mys _ e1 _ startLoc _ e2 endLoc -> do
      let e1' = m :< RT.BoxIntroQuote [] [] (e1, [])
      discern axis $ m :< RT.BoxElim VariantT True [] mxt [] mys [] e1' [] startLoc [] e2 endLoc
    m :< RT.Pin _ mxt@(mx, x, _, _, _) _ _ e1 _ startLoc _ e2 endLoc -> do
      let m' = blur m
      tmp <- Gensym.newTextFromText "tmp-pin"
      let x' = SE.fromListWithComment Nothing SE.Comma [([], ((mx, x), []))]
      resultType <- Gensym.newPreHole m'
      discern axis $
        bind startLoc endLoc mxt e1 $
          m :< RT.LetOn [] (m', tmp, [], [], resultType) [] x' [] e2 [] startLoc [] (m' :< RT.Var (Var tmp)) endLoc
    m :< RT.StaticText s str -> do
      s' <- discern axis s
      case parseText str of
        Left reason ->
          Throw.raiseError m $ "Could not interpret the following as a text: " <> str <> "\nReason: " <> reason
        Right str' -> do
          return $ m :< WT.Prim (WP.Value $ WPV.StaticText s' str')
    m :< RT.Rune runeCons r -> do
      let int32Type = WT.intTypeBySize m 32
      runeCons' <- discern axis runeCons
      return $ m :< WT.PiElim runeCons' [m :< WT.Prim (WP.Value $ WPV.Int int32Type (RU.asInt r))]
    m :< RT.Hole k ->
      return $ m :< WT.Hole k []
    m :< RT.Magic _ magic -> do
      magic' <- discernMagic axis m magic
      return $ m :< WT.Magic magic'
    m :< RT.Annotation remarkLevel annot e -> do
      e' <- discern axis e
      case annot of
        AN.Type _ ->
          return $ m :< WT.Annotation remarkLevel (AN.Type (doNotCare m)) e'
    m :< RT.Resource _ (discarder, _) (copier, _) -> do
      resourceID <- Gensym.newCount
      discarder' <- discern axis discarder
      copier' <- discern axis copier
      return $ m :< WT.Resource resourceID discarder' copier'
    m :< RT.Use _ e _ xs _ cont endLoc -> do
      e' <- discern axis e
      (xs', axis') <- discernBinder axis (RT.extractArgs xs) endLoc
      cont' <- discern axis' cont
      return $ m :< WT.Use e' xs' cont'
    m :< RT.If ifClause elseIfClauseList (_, (elseBody, _)) -> do
      let (ifCond, ifBody) = RT.extractFromKeywordClause ifClause
      boolTrue <- locatorToName (blur m) coreBoolTrue
      boolFalse <- locatorToName (blur m) coreBoolFalse
      discern axis $ foldIf m boolTrue boolFalse ifCond ifBody elseIfClauseList elseBody
    m :< RT.Seq (e1, _) _ e2 -> do
      h <- Gensym.newTextForHole
      unit <- locatorToVarGlobal m coreUnit
      discern axis $ bind fakeLoc fakeLoc (m, h, [], [], unit) e1 e2
    m :< RT.When whenClause -> do
      let (whenCond, whenBody) = RT.extractFromKeywordClause whenClause
      boolTrue <- locatorToName (blur m) coreBoolTrue
      boolFalse <- locatorToName (blur m) coreBoolFalse
      unitUnit <- locatorToVarGlobal m coreUnitUnit
      discern axis $ foldIf m boolTrue boolFalse whenCond whenBody [] unitUnit
    m :< RT.ListIntro es -> do
      let m' = m {metaShouldSaveLocation = False}
      listNil <- locatorToVarGlobal m' coreListNil
      listCons <- locatorToVarGlobal m' coreListCons
      discern axis $ foldListApp m' listNil listCons $ SE.extract es
    m :< RT.Admit -> do
      admit <- locatorToVarGlobal m coreSystemAdmit
      t <- Gensym.newPreHole (blur m)
      textType <- locatorToVarGlobal m coreText
      discern axis $
        m
          :< RT.Annotation
            R.Warning
            (AN.Type ())
            ( m
                :< RT.piElim
                  admit
                  [t, m :< RT.StaticText textType ("admit: " <> T.pack (Hint.toString m) <> "\n")]
            )
    m :< RT.Detach _ _ (e, _) -> do
      t <- Gensym.newPreHole (blur m)
      detachVar <- locatorToVarGlobal m coreThreadDetach
      cod <- Gensym.newPreHole (blur m)
      discern axis $ m :< RT.piElim detachVar [t, RT.lam fakeLoc m [] cod e]
    m :< RT.Attach _ _ (e, _) -> do
      t <- Gensym.newPreHole (blur m)
      attachVar <- locatorToVarGlobal m coreThreadAttach
      discern axis $ m :< RT.piElim attachVar [t, e]
    m :< RT.Option t -> do
      eitherVar <- locatorToVarGlobal m coreEither
      unit <- locatorToVarGlobal m coreUnit
      discern axis $ m :< RT.piElim eitherVar [unit, t]
    m :< RT.Assert _ (mText, message) _ _ (e@(mCond :< _), _) -> do
      assert <- locatorToVarGlobal m coreSystemAssert
      textType <- locatorToVarGlobal m coreText
      let fullMessage = T.pack (Hint.toString m) <> "\nAssertion failure: " <> message <> "\n"
      cod <- Gensym.newPreHole (blur m)
      discern axis $
        m
          :< RT.piElim
            assert
            [mText :< RT.StaticText textType fullMessage, RT.lam fakeLoc mCond [] cod e]
    m :< RT.Introspect _ key _ clauseList -> do
      value <- getIntrospectiveValue m key
      clause <- lookupIntrospectiveClause m value $ SE.extract clauseList
      discern axis clause
    m :< RT.IncludeText _ _ mKey (key, _) -> do
      contentOrNone <- Locator.getStaticFileContent key
      case contentOrNone of
        Just (path, content) -> do
          UnusedStaticFile.delete key
          textType <- locatorToVarGlobal m coreText >>= discern axis
          Tag.insertFileLoc mKey (T.length key) (newSourceHint path)
          return $ m :< WT.Prim (WP.Value $ WPV.StaticText textType content)
        Nothing ->
          Throw.raiseError m $ "No such static file is defined: `" <> key <> "`"
    m :< RT.With withClause -> do
      let (binder, body) = RT.extractFromKeywordClause withClause
      case body of
        mLet :< RT.Let letKind c1 mxt@(mPat, pat, c2, c3, t) c c4 e1 c5 startLoc c6 e2 endLoc -> do
          let e1' = m :< RT.With (([], (binder, [])), ([], (e1, [])))
          let e2' = m :< RT.With (([], (binder, [])), ([], (e2, [])))
          case letKind of
            RT.Bind -> do
              tmpVar <- Gensym.newText
              (x, e2'') <- modifyLetContinuation (mPat, pat) endLoc False e2'
              let m' = blur m
              dom <- Gensym.newPreHole m'
              cod <- Gensym.newPreHole m'
              discern axis $
                bind'
                  False
                  startLoc
                  endLoc
                  (mPat, tmpVar, c2, c3, dom)
                  e1'
                  ( m
                      :< RT.piElim
                        binder
                        [ m' :< RT.Var (Var tmpVar),
                          RT.lam
                            startLoc
                            m'
                            [((mPat, x, c2, c3, t), c)]
                            cod
                            e2''
                        ]
                  )
            _ -> do
              discern axis $ mLet :< RT.Let letKind c1 mxt c c4 e1' c5 startLoc c6 e2' endLoc
        mSeq :< RT.Seq (e1, c1) c2 e2 -> do
          let e1' = m :< RT.With (([], (binder, [])), ([], (e1, [])))
          let e2' = m :< RT.With (([], (binder, [])), ([], (e2, [])))
          discern axis $ mSeq :< RT.Seq (e1', c1) c2 e2'
        mUse :< RT.Use c1 item c2 vars c3 cont endLoc -> do
          let cont' = m :< RT.With (([], (binder, [])), ([], (cont, [])))
          discern axis $ mUse :< RT.Use c1 item c2 vars c3 cont' endLoc
        mPin :< RT.Pin c1 (mx, x, c2, c3, t) c4 c5 e1 c6 startLoc c7 e2 endLoc -> do
          let e1' = m :< RT.With (([], (binder, [])), ([], (e1, [])))
          let e2' = m :< RT.With (([], (binder, [])), ([], (e2, [])))
          discern axis $ mPin :< RT.Pin c1 (mx, x, c2, c3, t) c4 c5 e1' c6 startLoc c7 e2' endLoc
        _ ->
          discern axis body
    _ :< RT.Projection e (mProj, proj) loc -> do
      t <- Gensym.newPreHole (blur mProj)
      let args = (SE.fromList SE.Brace SE.Comma [(mProj, proj, [], [], t)], [])
      let var = mProj :< RT.Var (Var proj)
      discern axis $ mProj :< RT.Use [] e [] args [] var loc
    _ :< RT.Brace _ (e, _) ->
      discern axis e

discernNoeticVarList :: [(Hint, (Hint, Ident))] -> App [(BinderF WT.WeakTerm, WT.WeakTerm)]
discernNoeticVarList xsOuter = do
  forM xsOuter $ \(mDef, (mOuter, outerVar)) -> do
    xInner <- Gensym.newIdentFromIdent outerVar
    t <- Gensym.newHole mOuter []
    Tag.insertLocalVar mDef outerVar mOuter
    return ((mOuter, xInner, t), mDef :< WT.Var outerVar)

discernRawLowType :: Hint -> RLT.RawLowType -> App LT.LowType
discernRawLowType m rlt = do
  dataSize <- Env.getDataSize m
  case LT.fromRawLowType dataSize rlt of
    Left err ->
      Throw.raiseError m err
    Right lt ->
      return lt

discernMagic :: Axis -> Hint -> RT.RawMagic -> App (M.Magic WT.WeakTerm)
discernMagic axis m magic =
  case magic of
    RT.Cast _ (_, (from, _)) (_, (to, _)) (_, (e, _)) _ -> do
      from' <- discern axis from
      to' <- discern axis to
      e' <- discern axis e
      return $ M.Cast from' to' e'
    RT.Store _ (_, (lt, _)) (_, (value, _)) (_, (pointer, _)) _ -> do
      lt' <- discernRawLowType m lt
      value' <- discern axis value
      pointer' <- discern axis pointer
      return $ M.Store lt' value' pointer'
    RT.Load _ (_, (lt, _)) (_, (pointer, _)) _ -> do
      lt' <- discernRawLowType m lt
      pointer' <- discern axis pointer
      return $ M.Load lt' pointer'
    RT.Alloca _ (_, (lt, _)) (_, (size, _)) _ -> do
      lt' <- discernRawLowType m lt
      size' <- discern axis size
      return $ M.Alloca lt' size'
    RT.External _ funcName _ args varArgsOrNone -> do
      (domList, cod) <- Decl.lookupDeclEnv m (DN.Ext funcName)
      args' <- mapM (discern axis) $ SE.extract args
      varArgs' <- case varArgsOrNone of
        Nothing ->
          return []
        Just (_, varArgs) ->
          forM (SE.extract varArgs) $ \(_, arg, _, _, lt) -> do
            arg' <- discern axis arg
            lt' <- discernRawLowType m lt
            return (arg', lt')
      return $ M.External domList cod funcName args' varArgs'
    RT.Global _ (_, (name, _)) (_, (lt, _)) _ -> do
      lt' <- discernRawLowType m lt
      return $ M.Global name lt'

modifyLetContinuation :: (Hint, RP.RawPattern) -> Loc -> N.IsNoetic -> RT.RawTerm -> App (RawIdent, RT.RawTerm)
modifyLetContinuation pat endLoc isNoetic cont@(mCont :< _) =
  case pat of
    (_, RP.Var (Var x))
      | not (isConsName x) ->
          return (x, cont)
    _ -> do
      tmp <- Gensym.newTextForHole
      return
        ( tmp,
          mCont
            :< RT.DataElim
              []
              isNoetic
              (SE.fromList'' [mCont :< RT.Var (Var tmp)])
              (SE.fromList SE.Brace SE.Bar [(SE.fromList'' [pat], [], cont, endLoc)])
        )

bind ::
  Loc ->
  Loc ->
  RawBinder RT.RawTerm ->
  RT.RawTerm ->
  RT.RawTerm ->
  RT.RawTerm
bind loc endLoc (m, x, c1, c2, t) =
  bind' False loc endLoc (m, x, c1, c2, t)

bind' ::
  RT.MustIgnoreRelayedVars ->
  Loc ->
  Loc ->
  RawBinder RT.RawTerm ->
  RT.RawTerm ->
  RT.RawTerm ->
  RT.RawTerm
bind' mustIgnoreRelayedVars loc endLoc (m, x, c1, c2, t) e cont =
  m
    :< RT.Let
      (RT.Plain mustIgnoreRelayedVars)
      []
      (m, RP.Var (Var x), c1, c2, t)
      []
      []
      e
      []
      loc
      []
      cont
      endLoc

foldListApp :: Hint -> RT.RawTerm -> RT.RawTerm -> [RT.RawTerm] -> RT.RawTerm
foldListApp m listNil listCons es =
  case es of
    [] ->
      listNil
    e : rest ->
      m :< RT.piElim listCons [e, foldListApp m listNil listCons rest]

lookupIntrospectiveClause :: Hint -> T.Text -> [(Maybe T.Text, C, RT.RawTerm)] -> App RT.RawTerm
lookupIntrospectiveClause m value clauseList =
  case clauseList of
    [] ->
      Throw.raiseError m $ "This term does not support `" <> value <> "`."
    (Just key, _, clause) : rest
      | key == value ->
          return clause
      | otherwise ->
          lookupIntrospectiveClause m value rest
    (Nothing, _, clause) : _ ->
      return clause

getIntrospectiveValue :: Hint -> T.Text -> App T.Text
getIntrospectiveValue m key = do
  bm <- Env.getBuildMode
  case key of
    "platform" -> do
      return $ Platform.reify Platform.platform
    "arch" ->
      return $ Arch.reify (Platform.arch Platform.platform)
    "os" ->
      return $ OS.reify (Platform.os Platform.platform)
    "build-mode" ->
      return $ BM.reify bm
    _ ->
      Throw.raiseError m $ "No such introspective value is defined: " <> key

foldIf ::
  Hint ->
  Name ->
  Name ->
  RT.RawTerm ->
  RT.RawTerm ->
  [RT.KeywordClause RT.RawTerm] ->
  RT.RawTerm ->
  RT.RawTerm
foldIf m true false ifCond ifBody elseIfList elseBody =
  case elseIfList of
    [] -> do
      m
        :< RT.DataElim
          []
          False
          (SE.fromList'' [ifCond])
          ( SE.fromList
              SE.Brace
              SE.Bar
              [ ( SE.fromList'' [(blur m, RP.Var true)],
                  [],
                  ifBody,
                  fakeLoc
                ),
                ( SE.fromList'' [(blur m, RP.Var false)],
                  [],
                  elseBody,
                  fakeLoc
                )
              ]
          )
    elseIfClause : rest -> do
      let (elseIfCond, elseIfBody) = RT.extractFromKeywordClause elseIfClause
      let cont = foldIf m true false elseIfCond elseIfBody rest elseBody
      m
        :< RT.DataElim
          []
          False
          (SE.fromList'' [ifCond])
          ( SE.fromList
              SE.Brace
              SE.Bar
              [ (SE.fromList'' [(blur m, RP.Var true)], [], ifBody, fakeLoc),
                (SE.fromList'' [(blur m, RP.Var false)], [], cont, fakeLoc)
              ]
          )

doNotCare :: Hint -> WT.WeakTerm
doNotCare m =
  m :< WT.Tau

discernLet ::
  Axis ->
  Hint ->
  RT.LetKind ->
  (Hint, RP.RawPattern, C, C, RT.RawTerm) ->
  RT.RawTerm ->
  RT.RawTerm ->
  Loc ->
  Loc ->
  App WT.WeakTerm
discernLet axis m letKind (mx, pat, c1, c2, t) e1 e2@(m2 :< _) startLoc endLoc = do
  let opacity = WT.Clear
  let discernLet' isNoetic = do
        e1' <- discern axis e1
        (x, e2') <- modifyLetContinuation (mx, pat) endLoc isNoetic e2
        (mxt', e2'') <- discernBinderWithBody' axis (mx, x, c1, c2, t) startLoc endLoc e2'
        Tag.insertBinder mxt'
        return $ m :< WT.Let opacity mxt' e1' e2''
  case letKind of
    RT.Plain _ -> do
      discernLet' False
    RT.Noetic -> do
      discernLet' True
    RT.Bind -> do
      Throw.raiseError m "`bind` can only be used inside `with`"
    RT.Try -> do
      let m' = blur m
      let mx' = blur mx
      let m2' = blur m2
      eitherTypeInner <- locatorToVarGlobal mx' coreEither
      leftType <- Gensym.newPreHole m2'
      let eitherType = m2' :< RT.piElim eitherTypeInner [leftType, t]
      tmpVar <- Gensym.newText
      e1' <- discern axis e1
      err <- Gensym.newText
      eitherLeft <- locatorToName m2' coreEitherLeft
      eitherRight <- locatorToName m2' coreEitherRight
      eitherLeftVar <- locatorToVarGlobal mx' coreEitherLeft
      (mxt', eitherCont) <-
        discernBinderWithBody' axis (mx, tmpVar, c1, c2, eitherType) startLoc endLoc $
          m'
            :< RT.DataElim
              []
              False
              (SE.fromList'' [m' :< RT.Var (Var tmpVar)])
              ( SE.fromList
                  SE.Brace
                  SE.Bar
                  [ ( SE.fromList'' [(m2', RP.Cons eitherLeft [] (RP.Paren (SE.fromList' [(m2', RP.Var (Var err))])))],
                      [],
                      m2' :< RT.piElim eitherLeftVar [m2' :< RT.Var (Var err)],
                      fakeLoc
                    ),
                    ( SE.fromList'' [(m2', RP.Cons eitherRight [] (RP.Paren (SE.fromList' [(mx, pat)])))],
                      [],
                      e2,
                      endLoc
                    )
                  ]
              )
      return $ m :< WT.Let opacity mxt' e1' eitherCont
    RT.Catch -> do
      let m' = blur m
      let mx' = blur mx
      let m2' = blur m2
      eitherTypeInner <- locatorToVarGlobal mx' coreEither
      rightType <- Gensym.newPreHole m2'
      let eitherType = m2' :< RT.piElim eitherTypeInner [t, rightType]
      tmpVar <- Gensym.newText
      e1' <- discern axis e1
      result <- Gensym.newText
      eitherLeft <- locatorToName m2' coreEitherLeft
      eitherRight <- locatorToName m2' coreEitherRight
      eitherRightVar <- locatorToVarGlobal mx' coreEitherRight
      (mxt', eitherCont) <-
        discernBinderWithBody' axis (mx, tmpVar, c1, c2, eitherType) startLoc endLoc $
          m'
            :< RT.DataElim
              []
              False
              (SE.fromList'' [m' :< RT.Var (Var tmpVar)])
              ( SE.fromList
                  SE.Brace
                  SE.Bar
                  [ ( SE.fromList'' [(m2', RP.Cons eitherLeft [] (RP.Paren (SE.fromList' [(mx, pat)])))],
                      [],
                      e2,
                      endLoc
                    ),
                    ( SE.fromList'' [(m2', RP.Cons eitherRight [] (RP.Paren (SE.fromList' [(m2', RP.Var (Var result))])))],
                      [],
                      m2' :< RT.piElim eitherRightVar [m2' :< RT.Var (Var result)],
                      fakeLoc
                    )
                  ]
              )
      return $ m :< WT.Let opacity mxt' e1' eitherCont

discernIdent :: Hint -> Axis -> RawIdent -> App (Hint, (Hint, Ident))
discernIdent m axis x =
  case lookup x (_nenv axis) of
    Nothing ->
      Throw.raiseError m $ "Undefined variable: " <> x
    Just (mDef, x', _) -> do
      UnusedVariable.delete x'
      return (mDef, (m, x'))

discernBinder ::
  Axis ->
  [RawBinder RT.RawTerm] ->
  Loc ->
  App ([BinderF WT.WeakTerm], Axis)
discernBinder axis binder endLoc =
  case binder of
    [] -> do
      return ([], axis)
    (mx, x, _, _, t) : xts -> do
      t' <- discern axis t
      x' <- Gensym.newIdentFromText x
      axis' <- extendAxis mx x' VDK.Normal axis
      (xts', axis'') <- discernBinder axis' xts endLoc
      Tag.insertBinder (mx, x', t')
      SymLoc.insert x' (metaLocation mx) endLoc
      return ((mx, x', t') : xts', axis'')

discernBinder' ::
  Axis ->
  [RawBinder RT.RawTerm] ->
  App ([BinderF WT.WeakTerm], Axis)
discernBinder' axis binder =
  case binder of
    [] -> do
      return ([], axis)
    (mx, x, _, _, t) : xts -> do
      t' <- discern axis t
      x' <- Gensym.newIdentFromText x
      axis' <- extendAxis mx x' VDK.Normal axis
      (xts', axis'') <- discernBinder' axis' xts
      Tag.insertBinder (mx, x', t')
      return ((mx, x', t') : xts', axis'')

discernBinderWithBody' ::
  Axis ->
  RawBinder RT.RawTerm ->
  Loc ->
  Loc ->
  RT.RawTerm ->
  App (BinderF WT.WeakTerm, WT.WeakTerm)
discernBinderWithBody' axis (mx, x, _, _, codType) startLoc endLoc e = do
  codType' <- discern axis codType
  x' <- Gensym.newIdentFromText x
  axis'' <- extendAxis mx x' VDK.Normal axis
  e' <- discern axis'' e
  SymLoc.insert x' startLoc endLoc
  return ((mx, x', codType'), e')

discernPatternMatrix ::
  Axis ->
  [RP.RawPatternRow RT.RawTerm] ->
  App (PAT.PatternMatrix ([Ident], [(BinderF WT.WeakTerm, WT.WeakTerm)], WT.WeakTerm))
discernPatternMatrix axis patternMatrix =
  case uncons patternMatrix of
    Nothing ->
      return $ PAT.new []
    Just (row, rows) -> do
      row' <- discernPatternRow axis row
      rows' <- discernPatternMatrix axis rows
      return $ PAT.consRow row' rows'

discernPatternRow ::
  Axis ->
  RP.RawPatternRow RT.RawTerm ->
  App (PAT.PatternRow ([Ident], [(BinderF WT.WeakTerm, WT.WeakTerm)], WT.WeakTerm))
discernPatternRow axis (patList, _, body, _) = do
  (patList', body') <- discernPatternRow' axis (SE.extract patList) [] body
  return (V.fromList patList', body')

discernPatternRow' ::
  Axis ->
  [(Hint, RP.RawPattern)] ->
  NominalEnv ->
  RT.RawTerm ->
  App ([(Hint, PAT.Pattern)], ([Ident], [(BinderF WT.WeakTerm, WT.WeakTerm)], WT.WeakTerm))
discernPatternRow' axis patList newVarList body = do
  case patList of
    [] -> do
      ensureVariableLinearity newVarList
      axis' <- extendAxisByNominalEnv VDK.Normal newVarList axis
      body' <- discern axis' body
      return ([], ([], [], body'))
    pat : rest -> do
      (pat', varsInPat) <- discernPattern (currentLayer axis) pat
      (rest', body') <- discernPatternRow' axis rest (varsInPat ++ newVarList) body
      return (pat' : rest', body')

ensureVariableLinearity :: NominalEnv -> App ()
ensureVariableLinearity vars = do
  let linearityErrors = getNonLinearOccurrences vars S.empty []
  unless (null linearityErrors) $ Throw.throw $ E.MakeError linearityErrors

getNonLinearOccurrences :: NominalEnv -> S.Set T.Text -> [(Hint, T.Text)] -> [R.Remark]
getNonLinearOccurrences vars found nonLinear =
  case vars of
    [] -> do
      let nonLinearVars = reverse $ ListUtils.nubOrdOn snd nonLinear
      flip map nonLinearVars $ \(m, x) ->
        R.newRemark m R.Error $
          "the pattern variable `"
            <> x
            <> "` is used non-linearly"
    (from, (m, _, _)) : rest
      | S.member from found ->
          getNonLinearOccurrences rest found ((m, from) : nonLinear)
      | otherwise ->
          getNonLinearOccurrences rest (S.insert from found) nonLinear

discernPattern ::
  Layer ->
  (Hint, RP.RawPattern) ->
  App ((Hint, PAT.Pattern), NominalEnv)
discernPattern layer (m, pat) = do
  case pat of
    RP.Var name -> do
      case name of
        Var x
          | Just i <- R.readMaybe (T.unpack x) -> do
              return ((m, PAT.Literal (LI.Int i)), [])
          | isConsName x -> do
              (consDD, dataArgNum, consArgNum, disc, isConstLike, _) <- resolveConstructor m $ Var x
              consDD' <- Locator.getReadableDD consDD
              unless isConstLike $
                Throw.raiseError m $
                  "The constructor `" <> consDD' <> "` cannot be used as a constant"
              return ((m, PAT.Cons (PAT.ConsInfo {args = [], ..})), [])
          | otherwise -> do
              x' <- Gensym.newIdentFromText x
              return ((m, PAT.Var x'), [(x, (m, x', layer))])
        Locator l -> do
          (dd, gn) <- resolveName m $ Locator l
          case gn of
            (_, GN.DataIntro dataArgNum consArgNum disc isConstLike) -> do
              let consInfo =
                    PAT.ConsInfo
                      { consDD = dd,
                        isConstLike = isConstLike,
                        disc = disc,
                        dataArgNum = dataArgNum,
                        consArgNum = consArgNum,
                        args = []
                      }
              return ((m, PAT.Cons consInfo), [])
            _ -> do
              dd' <- Locator.getReadableDD dd
              Throw.raiseError m $
                "The symbol `" <> dd' <> "` is not defined as a constuctor"
    RP.Cons cons _ mArgs -> do
      (consName, dataArgNum, consArgNum, disc, isConstLike, _) <- resolveConstructor m cons
      when isConstLike $
        Throw.raiseError m $
          "The constructor `" <> showName cons <> "` cannot have any arguments"
      case mArgs of
        RP.Paren args -> do
          (args', axisList) <- mapAndUnzipM (discernPattern layer) $ SE.extract args
          let consInfo =
                PAT.ConsInfo
                  { consDD = consName,
                    isConstLike = isConstLike,
                    disc = disc,
                    dataArgNum = dataArgNum,
                    consArgNum = consArgNum,
                    args = args'
                  }
          return ((m, PAT.Cons consInfo), concat axisList)
        RP.Of mkvs -> do
          let (ks, mvcs) = unzip $ SE.extract mkvs
          let mvs = map (\(mv, _, v) -> (mv, v)) mvcs
          ensureFieldLinearity m ks S.empty S.empty
          (_, keyList) <- KeyArg.lookup m consName
          defaultKeyMap <- constructDefaultKeyMap m keyList
          let specifiedKeyMap = Map.fromList $ zip ks mvs
          let keyMap = Map.union specifiedKeyMap defaultKeyMap
          reorderedArgs <- KeyArg.reorderArgs m keyList keyMap
          (patList', axisList) <- mapAndUnzipM (discernPattern layer) reorderedArgs
          let consInfo =
                PAT.ConsInfo
                  { consDD = consName,
                    isConstLike = isConstLike,
                    disc = disc,
                    dataArgNum = dataArgNum,
                    consArgNum = consArgNum,
                    args = patList'
                  }
          return ((m, PAT.Cons consInfo), concat axisList)
    RP.ListIntro patList -> do
      let m' = m {metaShouldSaveLocation = False}
      listNil <- Throw.liftEither $ DD.getLocatorPair m' coreListNil
      listCons <- locatorToName m' coreListCons
      discernPattern layer $ foldListAppPat m' listNil listCons $ SE.extract patList
    RP.RuneIntro r -> do
      return ((m, PAT.Literal (LI.Rune r)), [])

foldListAppPat ::
  Hint ->
  L.Locator ->
  Name ->
  [(Hint, RP.RawPattern)] ->
  (Hint, RP.RawPattern)
foldListAppPat m listNil listCons es =
  case es of
    [] ->
      (m, RP.Var $ Locator listNil)
    pat : rest -> do
      let rest' = foldListAppPat m listNil listCons rest
      (m, RP.Cons listCons [] (RP.Paren (SE.fromList' [pat, rest'])))

constructDefaultKeyMap :: Hint -> [Key] -> App (Map.HashMap Key (Hint, RP.RawPattern))
constructDefaultKeyMap m keyList = do
  names <- mapM (const Gensym.newTextForHole) keyList
  return $ Map.fromList $ zipWith (\k v -> (k, (m, RP.Var (Var v)))) keyList names

locatorToName :: Hint -> T.Text -> App Name
locatorToName m text = do
  (gl, ll) <- Throw.liftEither $ DD.getLocatorPair m text
  return $ Locator (gl, ll)

locatorToVarGlobal :: Hint -> T.Text -> App RT.RawTerm
locatorToVarGlobal m text = do
  (gl, ll) <- Throw.liftEither $ DD.getLocatorPair (blur m) text
  return $ blur m :< RT.Var (Locator (gl, ll))

getLayer :: Hint -> Axis -> Ident -> App Layer
getLayer m axis x =
  case lookup (Ident.toText x) (_nenv axis) of
    Nothing ->
      Throw.raiseCritical m $ "Scene.Parse.Discern.getLayer: Undefined variable: " <> Ident.toText x
    Just (_, _, l) -> do
      return l

findExternalVariable :: Hint -> Axis -> WT.WeakTerm -> App (Maybe (Ident, Layer))
findExternalVariable m axis e = do
  let fvs = S.toList $ freeVars e
  ls <- mapM (getLayer m axis) fvs
  return $ find (\(_, l) -> l /= currentLayer axis) $ zip fvs ls

ensureLayerClosedness :: Hint -> Axis -> WT.WeakTerm -> App ()
ensureLayerClosedness mClosure axis e = do
  mvar <- findExternalVariable mClosure axis e
  case mvar of
    Nothing ->
      return ()
    Just (x, l) -> do
      Throw.raiseError mClosure $
        "This closure is at the layer "
          <> T.pack (show (currentLayer axis))
          <> ", but the free variable `"
          <> Ident.toText x
          <> "` is at the layer "
          <> T.pack (show l)
          <> " (≠ "
          <> T.pack (show (currentLayer axis))
          <> ")"

raiseLayerError :: Hint -> Layer -> Layer -> App a
raiseLayerError m expected found = do
  Throw.raiseError m $
    "Expected layer:\n  "
      <> T.pack (show expected)
      <> "\nFound layer:\n  "
      <> T.pack (show found)
