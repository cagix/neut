{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}

{-# HLINT ignore "Use list comprehension" #-}

module Scene.Elaborate.Infer (inferStmt) where

import Context.App
import Context.Elaborate
import Context.Env qualified as Env
import Context.Gensym qualified as Gensym
import Context.KeyArg qualified as KeyArg
import Context.Locator qualified as Locator
import Context.OptimizableData qualified as OptimizableData
import Context.Throw qualified as Throw
import Context.Type qualified as Type
import Context.WeakDefinition qualified as WeakDefinition
import Control.Comonad.Cofree
import Control.Monad
import Data.HashMap.Strict qualified as Map
import Data.IntMap qualified as IntMap
import Data.Text qualified as T
import Entity.Annotation qualified as Annotation
import Entity.ArgNum qualified as AN
import Entity.Attr.Data qualified as AttrD
import Entity.Attr.DataIntro qualified as AttrDI
import Entity.Attr.Lam qualified as AttrL
import Entity.Attr.VarGlobal qualified as AttrVG
import Entity.Binder
import Entity.Const
import Entity.DecisionTree qualified as DT
import Entity.DefiniteDescription qualified as DD
import Entity.Discriminant qualified as D
import Entity.Geist qualified as G
import Entity.Hint
import Entity.HoleID qualified as HID
import Entity.HoleSubst qualified as HS
import Entity.Ident (Ident (..), isHole)
import Entity.Ident.Reify qualified as Ident
import Entity.Key (Key)
import Entity.LamKind qualified as LK
import Entity.Literal qualified as L
import Entity.Magic qualified as M
import Entity.Name qualified as N
import Entity.OptimizableData qualified as OD
import Entity.PrimOp
import Entity.PrimType qualified as PT
import Entity.Stmt
import Entity.StmtKind
import Entity.Term qualified as TM
import Entity.Term.FromPrimNum qualified as Term
import Entity.Term.Weaken
import Entity.WeakPrim qualified as WP
import Entity.WeakPrimValue qualified as WPV
import Entity.WeakTerm qualified as WT
import Entity.WeakTerm.ToText (toText)
import Scene.Elaborate.Unify (unifyCurrentConstraints)
import Scene.Parse.Discern.Name qualified as N
import Scene.WeakTerm.Reduce qualified as WT
import Scene.WeakTerm.Subst qualified as Subst
import Scene.WeakTerm.Subst qualified as WT

type BoundVarEnv = [BinderF WT.WeakTerm]

inferStmt :: WeakStmt -> App WeakStmt
inferStmt stmt =
  case stmt of
    WeakStmtDefine isConstLike stmtKind m x impArgs expArgs codType e -> do
      axis <- createNewAxis
      (impArgs', axis') <- inferBinder' axis impArgs
      (expArgs', axis'') <- inferBinder' axis' expArgs
      codType' <- inferType axis'' codType
      insertType x $ m :< WT.Pi impArgs' expArgs' codType'
      stmtKind' <- inferStmtKind stmtKind
      (e', te) <- infer axis'' e
      insConstraintEnv codType' te
      when (DD.isEntryPoint x) $ do
        let _m = m {metaShouldSaveLocation = False}
        unitType <- getUnitType _m
        insConstraintEnv (m :< WT.Pi [] [] unitType) (m :< WT.Pi impArgs' expArgs' codType')
      return $ WeakStmtDefine isConstLike stmtKind' m x impArgs' expArgs' codType' e'
    WeakStmtDefineConst m dd t v -> do
      axis1 <- createNewAxis
      t' <- inferType axis1 t
      insertType dd $ m :< WT.Pi [] [] t'
      axis2 <- createNewAxis
      (v', tv) <- infer axis2 v
      insConstraintEnv t' tv
      return $ WeakStmtDefineConst m dd t' v'
    WeakStmtNominal m geistList -> do
      geistList' <- mapM inferGeist geistList
      return $ WeakStmtNominal m geistList'
    WeakStmtForeign foreignList ->
      return $ WeakStmtForeign foreignList

inferGeist :: G.Geist WT.WeakTerm -> App (G.Geist WT.WeakTerm)
inferGeist G.Geist {..} = do
  axis <- createNewAxis
  (impArgs', axis') <- inferBinder' axis impArgs
  (expArgs', axis'') <- inferBinder' axis' expArgs
  cod' <- inferType axis'' cod
  insertType name $ loc :< WT.Pi impArgs' expArgs' cod'
  return $ G.Geist {impArgs = impArgs', expArgs = expArgs', cod = cod', ..}

insertType :: DD.DefiniteDescription -> WT.WeakTerm -> App ()
insertType dd t = do
  typeOrNone <- Type.lookupMaybe dd
  case typeOrNone of
    Nothing ->
      return ()
    Just declaredType ->
      insConstraintEnv declaredType t
  Type.insert dd t

inferStmtKind :: StmtKind WT.WeakTerm -> App (StmtKind WT.WeakTerm)
inferStmtKind stmtKind =
  case stmtKind of
    Normal {} ->
      return stmtKind
    Data dataName dataArgs consInfoList -> do
      empty <- createNewAxis
      (dataArgs', varEnv) <- inferBinder' empty dataArgs
      consInfoList' <- forM consInfoList $ \(m, dd, constLike, consArgs, discriminant) -> do
        (consArgs', _) <- inferBinder' varEnv consArgs
        return (m, dd, constLike, consArgs', discriminant)
      return $ Data dataName dataArgs' consInfoList'
    DataIntro consName dataArgs consArgs discriminant -> do
      empty <- createNewAxis
      (dataArgs', varEnv) <- inferBinder' empty dataArgs
      (consArgs', _) <- inferBinder' varEnv consArgs
      return $ DataIntro consName dataArgs' consArgs' discriminant

getIntType :: Hint -> App WT.WeakTerm
getIntType m = do
  baseSize <- Env.getBaseSize m
  return $ WT.intTypeBySize m baseSize

getUnitType :: Hint -> App WT.WeakTerm
getUnitType m = do
  locator <- Throw.liftEither $ DD.getLocatorPair m coreUnit
  (unitDD, _) <- N.resolveName m (N.Locator locator)
  let attr = AttrVG.Attr {argNum = AN.fromInt 0, isConstLike = True}
  return $ m :< WT.piElim (m :< WT.VarGlobal attr unitDD) []

createNewAxis :: App Axis
createNewAxis = do
  let varEnv = []
  return Axis {varEnv}

extendAxis :: BinderF WT.WeakTerm -> Axis -> Axis
extendAxis (mx, x, t) axis = do
  if isHole x then axis else axis {varEnv = (mx, x, t) : varEnv axis}

extendAxis' :: BinderF WT.WeakTerm -> Axis -> Axis
extendAxis' (mx, x, t) axis = do
  axis {varEnv = (mx, x, t) : varEnv axis}

newtype Axis
  = Axis {varEnv :: BoundVarEnv}

infer :: Axis -> WT.WeakTerm -> App (WT.WeakTerm, WT.WeakTerm)
infer axis term =
  case term of
    _ :< WT.Tau ->
      return (term, term)
    m :< WT.Var x -> do
      _ :< t <- lookupWeakTypeEnv m x
      return (term, m :< t)
    m :< WT.VarGlobal _ name -> do
      _ :< t <- Type.lookup m name
      return (term, m :< t)
    m :< WT.Pi impArgs expArgs t -> do
      (impArgs', axis') <- inferPiBinder axis impArgs
      (expArgs', axis'') <- inferPiBinder axis' expArgs
      t' <- inferType axis'' t
      return (m :< WT.Pi impArgs' expArgs' t', m :< WT.Tau)
    m :< WT.PiIntro attr@(AttrL.Attr {lamKind}) impArgs expArgs e -> do
      case lamKind of
        LK.Fix (mx, x, codType) -> do
          (impArgs', axis') <- inferBinder' axis impArgs
          (expArgs', axis'') <- inferBinder' axis' expArgs
          codType' <- inferType axis'' codType
          let piType = m :< WT.Pi impArgs' expArgs' codType'
          insWeakTypeEnv x piType
          (e', tBody) <- infer axis'' e
          insConstraintEnv codType' tBody
          let term' = m :< WT.PiIntro (attr {AttrL.lamKind = LK.Fix (mx, x, codType')}) impArgs' expArgs' e'
          return (term', piType)
        LK.Normal codType -> do
          (impArgs', axis') <- inferBinder' axis impArgs
          (expArgs', axis'') <- inferBinder' axis' expArgs
          codType' <- inferType axis'' codType
          (e', t') <- infer axis'' e
          insConstraintEnv codType' t'
          let term' = m :< WT.PiIntro (attr {AttrL.lamKind = LK.Normal codType'}) impArgs' expArgs' e'
          return (term', m :< WT.Pi impArgs' expArgs' t')
    m :< WT.PiElim e es -> do
      etl <- infer axis e
      etls <- mapM (infer axis) es
      inferPiElim axis m etl etls
    m :< WT.PiElimExact e -> do
      (e', t) <- infer axis e
      t' <- resolveType t
      case t' of
        _ :< WT.Pi impArgs expArgs codType -> do
          holes <- mapM (const $ newHole m $ varEnv axis) impArgs
          let sub = IntMap.fromList $ zip (map (\(_, x, _) -> Ident.toInt x) impArgs) (map Right holes)
          (expArgs', _) <- Subst.subst' sub expArgs
          let expArgs'' = map (\(_, x, _) -> m :< WT.Var x) expArgs'
          codType' <- Subst.subst sub codType
          lamID <- Gensym.newCount
          infer axis $ m :< WT.PiIntro (AttrL.normal lamID codType') [] expArgs' (m :< WT.PiElim e' expArgs'')
        _ ->
          Throw.raiseError m $ "Expected a function type, but got: " <> toText t'
    m :< WT.Data attr name es -> do
      (es', _) <- mapAndUnzipM (infer axis) es
      return (m :< WT.Data attr name es', m :< WT.Tau)
    m :< WT.DataIntro attr@(AttrDI.Attr {..}) consName dataArgs consArgs -> do
      (dataArgs', _) <- mapAndUnzipM (infer axis) dataArgs
      (consArgs', _) <- mapAndUnzipM (infer axis) consArgs
      let dataType = m :< WT.Data (AttrD.Attr {..}) dataName dataArgs'
      return (m :< WT.DataIntro attr consName dataArgs' consArgs', dataType)
    m :< WT.DataElim isNoetic oets tree -> do
      let (os, es, _) = unzip3 oets
      (es', ts') <- mapAndUnzipM (infer axis) es
      forM_ (zip os ts') $ uncurry insWeakTypeEnv
      (tree', _ :< treeType) <- inferDecisionTree m axis tree
      return (m :< WT.DataElim isNoetic (zip3 os es' ts') tree', m :< treeType)
    m :< WT.Box t -> do
      t' <- inferType axis t
      return (m :< WT.Box t', m :< WT.Tau)
    m :< WT.BoxNoema t -> do
      t' <- inferType axis t
      return (m :< WT.BoxNoema t', m :< WT.Tau)
    m :< WT.BoxIntro letSeq e -> do
      (letSeq', axis') <- inferQuoteSeq axis letSeq FromNoema
      (e', t) <- infer axis' e
      return (m :< WT.BoxIntro letSeq' e', m :< WT.Box t)
    m :< WT.BoxIntroQuote e -> do
      (e', t) <- infer axis e
      insertActualityConstraint t
      return (m :< WT.BoxIntroQuote e', m :< WT.Box t)
    m :< WT.BoxElim castSeq mxt e1 uncastSeq e2 -> do
      (castSeq', axis1) <- inferQuoteSeq axis castSeq ToNoema
      (e1', t1) <- infer axis1 e1
      (mxt'@(mx, _, t1'), axis2) <- inferBinder1 axis1 mxt
      insConstraintEnv (mx :< WT.Box t1') t1
      (uncastSeq', axis3) <- inferQuoteSeq axis2 uncastSeq FromNoema
      (e2', t2) <- infer axis3 e2
      return (m :< WT.BoxElim castSeq' mxt' e1' uncastSeq' e2', t2)
    _ :< WT.Actual e -> do
      (e', t') <- infer axis e
      insertActualityConstraint t'
      return (e', t')
    m :< WT.Let opacity (mx, x, t) e1 e2 -> do
      (e1', t1') <- infer axis e1
      t' <- inferType axis t >>= resolveType
      insWeakTypeEnv x t'
      case opacity of
        WT.Noetic ->
          insertActualityConstraint t'
        _ ->
          return ()
      insConstraintEnv t' t1' -- run this before `infer axis e2`
      (e2', t2') <- infer axis e2 -- no context extension
      return (m :< WT.Let opacity (mx, x, t') e1' e2', t2')
    m :< WT.Hole holeID _ -> do
      let rawHoleID = HID.reify holeID
      mHoleInfo <- lookupHoleEnv rawHoleID
      case mHoleInfo of
        Just (_ :< holeTerm, _ :< holeType) -> do
          return (m :< holeTerm, m :< holeType)
        Nothing -> do
          let holeArgs = map (\(mx, x, _) -> mx :< WT.Var x) (varEnv axis)
          let holeTerm = m :< WT.Hole holeID holeArgs
          holeType <- Gensym.newHole m holeArgs
          insHoleEnv rawHoleID holeTerm holeType
          return (holeTerm, holeType)
    m :< WT.Prim prim
      | WP.Type _ <- prim ->
          return (term, m :< WT.Tau)
      | WP.Value primValue <- prim ->
          case primValue of
            WPV.Int t v -> do
              empty <- createNewAxis
              t' <- inferType empty t
              return (m :< WT.Prim (WP.Value (WPV.Int t' v)), t')
            WPV.Float t v -> do
              empty <- createNewAxis
              t' <- inferType empty t
              return (m :< WT.Prim (WP.Value (WPV.Float t' v)), t')
            WPV.Op op -> do
              primOpType <- primOpToType m op
              return (term, weaken primOpType)
            WPV.StaticText t text -> do
              empty <- createNewAxis
              t' <- inferType empty t
              return (m :< WT.Prim (WP.Value (WPV.StaticText t' text)), m :< WT.BoxNoema t')
            WPV.Rune _ -> do
              return (m :< WT.Prim prim, m :< WT.Prim (WP.Type PT.Rune))
    m :< WT.Magic magic -> do
      case magic of
        M.Cast from to value -> do
          from' <- inferType axis from
          to'@(_ :< toInner) <- inferType axis to
          (value', t) <- infer axis value
          insConstraintEnv from' t
          return (m :< WT.Magic (M.Cast from' to' value'), m :< toInner)
        M.Alloca lt size -> do
          (size', sizeType) <- infer axis size
          intType <- getIntType m
          insConstraintEnv intType sizeType
          resultType <- newHole m (varEnv axis)
          return (m :< WT.Magic (M.Alloca lt size'), resultType)
        _ -> do
          magic' <- mapM (infer axis >=> return . fst) magic
          resultType <- newHole m (varEnv axis)
          return (m :< WT.Magic magic', resultType)
    m :< WT.Annotation logLevel annot e -> do
      (e', t) <- infer axis e
      case annot of
        Annotation.Type _ -> do
          return (m :< WT.Annotation logLevel (Annotation.Type t) e', t)
    m :< WT.Resource dd resourceID discarder copier -> do
      empty1 <- createNewAxis
      (discarder', td) <- infer empty1 discarder
      empty2 <- createNewAxis
      (copier', tc) <- infer empty2 copier
      x <- Gensym.newIdentFromText "_"
      intType <- getIntType m
      let tDiscard = m :< WT.Pi [] [(m, x, intType)] intType
      let tCopy = m :< WT.Pi [] [(m, x, intType)] intType
      insConstraintEnv tDiscard td
      insConstraintEnv tCopy tc
      return (m :< WT.Resource dd resourceID discarder' copier', m :< WT.Tau)
    m :< WT.Use e@(mt :< _) xts cont -> do
      (e', t') <- infer axis e
      t'' <- resolveType t'
      case t'' of
        _ :< WT.Data attr _ dataArgs
          | AttrD.Attr {..} <- attr,
            [(consDD, isConstLike')] <- consNameList -> do
              (_, keyList) <- KeyArg.lookup m consDD
              defaultKeyMap <- constructDefaultKeyMap axis m keyList
              let specifiedKeyMap = Map.fromList $ flip map xts $ \(mx, x, t) -> (Ident.toText x, (mx, x, t))
              let keyMap = Map.union specifiedKeyMap defaultKeyMap
              reorderedArgs <- KeyArg.reorderArgs m keyList keyMap
              dataArgs' <- mapM (const $ newTypedHole m (varEnv axis)) [1 .. length dataArgs]
              cursor <- Gensym.newIdentFromText "cursor"
              od <- OptimizableData.lookup consDD
              let freedVars = if mustBypassCursorDealloc od then [] else [cursor]
              insWeakTypeEnv cursor t''
              (tree', _ :< treeType) <-
                inferDecisionTree m axis $
                  DT.Switch
                    (cursor, t'')
                    ( DT.Unreachable,
                      [ DT.ConsCase
                          { mCons = m,
                            consDD = consDD,
                            isConstLike = isConstLike',
                            disc = D.zero,
                            dataArgs = dataArgs',
                            consArgs = reorderedArgs,
                            cont = DT.Leaf freedVars (adjustCont m reorderedArgs) cont
                          }
                      ]
                    )
              return (m :< WT.DataElim False [(cursor, e', t'')] tree', m :< treeType)
          | otherwise -> do
              Throw.raiseError mt $ "Expected a single-constructor ADT, but found: " <> toText t''
        _ :< _ -> do
          Throw.raiseError mt $ "Expected an ADT, but found: " <> toText t''

data CastDirection
  = FromNoema
  | ToNoema

inferQuoteSeq ::
  Axis ->
  [(BinderF WT.WeakTerm, WT.WeakTerm)] ->
  CastDirection ->
  App ([(BinderF WT.WeakTerm, WT.WeakTerm)], Axis)
inferQuoteSeq axis letSeq castDirection = do
  let (xts, es) = unzip letSeq
  (xts', axis') <- inferBinder' axis xts
  (es', ts) <- mapAndUnzipM (infer axis') es
  forM_ (zip xts' ts) $ \((m1, _, tInner), tOuter@(m2 :< _)) -> do
    case castDirection of
      ToNoema ->
        insConstraintEnv tInner (m2 :< WT.BoxNoema tOuter)
      FromNoema ->
        insConstraintEnv (m1 :< WT.BoxNoema tInner) tOuter
  return (zip xts' es', axis')

mustBypassCursorDealloc :: Maybe OD.OptimizableData -> Bool
mustBypassCursorDealloc odOrNone =
  case odOrNone of
    Just OD.Enum ->
      True
    Just OD.Unary ->
      True
    _ ->
      False

adjustCont :: Hint -> [BinderF WT.WeakTerm] -> [(BinderF WT.WeakTerm, WT.WeakTerm)]
adjustCont m xts =
  case xts of
    [] ->
      []
    (mx, x, t) : rest ->
      ((mx, x, t), mx :< WT.Var (ignoreUse x)) : adjustCont m rest

ignoreUse :: Ident -> Ident
ignoreUse (I (x, i)) =
  I (expVarPrefix <> x, i)

constructDefaultKeyMap :: Axis -> Hint -> [Key] -> App (Map.HashMap Key (BinderF WT.WeakTerm))
constructDefaultKeyMap axis m keyList = do
  names <- mapM (const Gensym.newIdentForHole) keyList
  ts <- mapM (const $ newHole m $ varEnv axis) names
  return $ Map.fromList $ zipWith (\k (v, t) -> (k, (m, v, t))) keyList $ zip names ts

inferArgs ::
  WT.SubstWeakTerm ->
  Hint ->
  [(WT.WeakTerm, WT.WeakTerm)] ->
  [BinderF WT.WeakTerm] ->
  WT.WeakTerm ->
  App WT.WeakTerm
inferArgs sub m args1 args2 cod =
  case (args1, args2) of
    ([], []) ->
      Subst.subst sub cod
    ((e, t) : ets, (_, x, tx) : xts) -> do
      tx' <- Subst.subst sub tx
      insConstraintEnv tx' t
      inferArgs (IntMap.insert (Ident.toInt x) (Right e) sub) m ets xts cod
    _ ->
      Throw.raiseCritical m "Invalid argument passed to inferArgs"

inferType :: Axis -> WT.WeakTerm -> App WT.WeakTerm
inferType varEnv t = do
  (t', u) <- infer varEnv t
  insConstraintEnv (WT.metaOf t :< WT.Tau) u
  return t'

inferPiBinder ::
  Axis ->
  [BinderF WT.WeakTerm] ->
  App ([BinderF WT.WeakTerm], Axis)
inferPiBinder axis binder =
  case binder of
    [] -> do
      return ([], axis)
    ((mx, x, t) : xts) -> do
      t' <- inferType axis t
      insWeakTypeEnv x t'
      (xtls', axis') <- inferPiBinder (extendAxis (mx, x, t') axis) xts
      return ((mx, x, t') : xtls', axis')

inferBinder' ::
  Axis ->
  [BinderF WT.WeakTerm] ->
  App ([BinderF WT.WeakTerm], Axis)
inferBinder' axis binder =
  case binder of
    [] -> do
      return ([], axis)
    ((mx, x, t) : xts) -> do
      t' <- inferType axis t
      insWeakTypeEnv x t'
      (xts', axis') <- inferBinder' (extendAxis' (mx, x, t') axis) xts
      return ((mx, x, t') : xts', axis')

inferBinder1 ::
  Axis ->
  BinderF WT.WeakTerm ->
  App (BinderF WT.WeakTerm, Axis)
inferBinder1 axis (mx, x, t) = do
  t' <- inferType axis t
  insWeakTypeEnv x t'
  return ((mx, x, t'), extendAxis' (mx, x, t') axis)

inferPiElim ::
  Axis ->
  Hint ->
  (WT.WeakTerm, WT.WeakTerm) ->
  [(WT.WeakTerm, WT.WeakTerm)] ->
  App (WT.WeakTerm, WT.WeakTerm)
inferPiElim axis m (e, t) expArgs = do
  t' <- resolveType t
  case t' of
    _ :< WT.Pi impPiArgs expPiArgs cod -> do
      ensureArityCorrectness e (length expPiArgs) (length expArgs)
      impArgs <- mapM (const $ newTypedHole m $ varEnv axis) [1 .. length impPiArgs]
      let args = impArgs ++ expArgs
      let piArgs = impPiArgs ++ expPiArgs
      _ :< cod' <- inferArgs IntMap.empty m args piArgs cod
      return (m :< WT.PiElim e (map fst args), m :< cod')
    _ ->
      Throw.raiseError m $ "Expected a function type, but got: " <> toText t'

inferPiElimExplicit ::
  Hint ->
  (WT.WeakTerm, WT.WeakTerm) ->
  [(WT.WeakTerm, WT.WeakTerm)] ->
  App (WT.WeakTerm, WT.WeakTerm)
inferPiElimExplicit m (e, t) args = do
  t' <- resolveType t
  case t' of
    _ :< WT.Pi impPiArgs expPiArgs cod -> do
      let piArgs = impPiArgs ++ expPiArgs
      ensureArityCorrectness e (length piArgs) (length args)
      _ :< cod' <- inferArgs IntMap.empty m args piArgs cod
      return (m :< WT.PiElim e (map fst args), m :< cod')
    _ ->
      Throw.raiseError m $ "Expected a function type, but got: " <> toText t'

newTypedHole :: Hint -> BoundVarEnv -> App (WT.WeakTerm, WT.WeakTerm)
newTypedHole m varEnv = do
  i <- HID.HoleID <$> Gensym.newCount
  j <- HID.HoleID <$> Gensym.newCount
  let holeArgs = map (\(mx, x, _) -> mx :< WT.Var x) varEnv
  let holeTerm = m :< WT.Hole i holeArgs
  let holeType = m :< WT.Hole j holeArgs
  insHoleEnv (HID.reify i) holeTerm holeType
  return (holeTerm, holeType)

ensureArityCorrectness :: WT.WeakTerm -> Int -> Int -> App ()
ensureArityCorrectness function expected found = do
  when (expected /= found) $ do
    case function of
      m :< WT.VarGlobal _ name -> do
        name' <- Locator.getReadableDD name
        Throw.raiseError m $
          "The function `"
            <> name'
            <> "` expects "
            <> T.pack (show expected)
            <> " arguments, but found "
            <> T.pack (show found)
            <> "."
      m :< _ ->
        Throw.raiseError m $
          "This function expects "
            <> T.pack (show expected)
            <> " arguments, but found "
            <> T.pack (show found)
            <> "."

primOpToType :: Hint -> PrimOp -> App TM.Term
primOpToType m op = do
  let (domList, cod) = getTypeInfo op
  let domList' = map (Term.fromPrimNum m) domList
  xs <- mapM (const (Gensym.newIdentFromText "_")) domList'
  let xts = zipWith (\x t -> (m, x, t)) xs domList'
  let cod' = Term.fromPrimNum m cod
  return $ m :< TM.Pi [] xts cod'

inferLet ::
  Axis ->
  (BinderF WT.WeakTerm, WT.WeakTerm) ->
  App (BinderF WT.WeakTerm, WT.WeakTerm)
inferLet varEnv ((mx, x, t), e1) = do
  (e1', t1') <- infer varEnv e1
  t' <- inferType varEnv t >>= resolveType
  insWeakTypeEnv x t'
  insConstraintEnv t' t1'
  return ((mx, x, t'), e1')

inferDecisionTree ::
  Hint ->
  Axis ->
  DT.DecisionTree WT.WeakTerm ->
  App (DT.DecisionTree WT.WeakTerm, WT.WeakTerm)
inferDecisionTree m axis tree =
  case tree of
    DT.Leaf ys letSeq body -> do
      letSeq' <- mapM (inferLet axis) letSeq
      (body', answerType) <- infer axis body
      return (DT.Leaf ys letSeq' body', answerType)
    DT.Unreachable -> do
      h <- newHole m (varEnv axis)
      return (DT.Unreachable, h)
    DT.Switch (cursor, mCursor :< _) clauseList -> do
      _ :< cursorType <- lookupWeakTypeEnv m cursor
      let cursorType' = mCursor :< cursorType
      (clauseList', answerType) <- inferClauseList m axis cursorType' clauseList
      return (DT.Switch (cursor, cursorType') clauseList', answerType)

inferClauseList ::
  Hint ->
  Axis ->
  WT.WeakTerm ->
  DT.CaseList WT.WeakTerm ->
  App (DT.CaseList WT.WeakTerm, WT.WeakTerm)
inferClauseList m axis cursorType (fallbackClause, clauseList) = do
  (clauseList', answerTypeList) <- flip mapAndUnzipM clauseList $ inferClause axis cursorType
  (fallbackClause', fallbackAnswerType) <- inferDecisionTree m axis fallbackClause
  h <- newHole m (varEnv axis)
  forM_ (answerTypeList ++ [fallbackAnswerType]) $ insConstraintEnv h
  return ((fallbackClause', clauseList'), fallbackAnswerType)

inferClause ::
  Axis ->
  WT.WeakTerm ->
  DT.Case WT.WeakTerm ->
  App (DT.Case WT.WeakTerm, WT.WeakTerm)
inferClause axis cursorType@(_ :< cursorTypeInner) decisionCase = do
  case decisionCase of
    DT.LiteralCase mPat literal cont -> do
      (cont', tCont) <- inferDecisionTree mPat axis cont
      case literal of
        L.Int _ -> do
          insertIntegerConstraint (mPat :< cursorTypeInner)
        L.Rune _ ->
          insConstraintEnv cursorType (mPat :< WT.Prim (WP.Type PT.Rune))
      return (DT.LiteralCase mPat literal cont', tCont)
    DT.ConsCase {..} -> do
      let m = DT.mCons decisionCase
      let (dataTermList, _) = unzip dataArgs
      typedDataArgs' <- mapM (infer axis) dataTermList
      (consArgs', extendedVarEnv) <- inferBinder' axis consArgs
      let argNum = AN.fromInt $ length dataArgs + length consArgs
      let attr = AttrVG.Attr {..}
      consTerm <- infer axis $ m :< WT.VarGlobal attr consDD
      (_, tPat) <- inferPiElimExplicit m consTerm $ typedDataArgs' ++ map (\(mx, x, t) -> (mx :< WT.Var x, t)) consArgs'
      insConstraintEnv cursorType tPat
      (cont', tCont) <- inferDecisionTree m extendedVarEnv cont
      return
        ( decisionCase
            { DT.dataArgs = typedDataArgs',
              DT.consArgs = consArgs',
              DT.cont = cont'
            },
          tCont
        )

resolveType :: WT.WeakTerm -> App WT.WeakTerm
resolveType t = do
  sub <- unifyCurrentConstraints
  reduceWeakType' sub t

reduceWeakType' :: HS.HoleSubst -> WT.WeakTerm -> App WT.WeakTerm
reduceWeakType' sub e = do
  e' <- WT.reduce e
  case e' of
    m :< WT.Hole h es ->
      case HS.lookup h sub of
        Nothing ->
          return e'
        Just (xs, body)
          | length xs == length es -> do
              let s = IntMap.fromList $ zip (map Ident.toInt xs) (map Right es)
              WT.subst s body >>= reduceWeakType' sub
          | otherwise ->
              Throw.raiseError m "Arity mismatch"
    m :< WT.PiElim (_ :< WT.VarGlobal _ name) args -> do
      mLam <- WeakDefinition.lookup name
      case mLam of
        Just lam ->
          reduceWeakType' sub $ m :< WT.PiElim lam args
        Nothing -> do
          return e'
    _ ->
      return e'
