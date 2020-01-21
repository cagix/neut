{-# LANGUAGE OverloadedStrings #-}

module Elaborate.Infer
  ( infer
  , univ
  , insWeakTypeEnv
  ) where

import Control.Monad.Except
import Control.Monad.State
import Data.Basic
import Data.Env
import Data.Maybe (catMaybes)
import Data.WeakTerm

import qualified Data.HashMap.Strict as Map
import qualified Data.Text as T

type Context = [(Identifier, WeakTermPlus)]

-- Given a term and a context, return the type of the term, updating the
-- constraint environment. This is more or less the same process in ordinary
-- Hindley-Milner type inference algorithm. The difference is that, when we
-- create a type variable, the type variable may depend on terms.
-- For example, consider generating constraints from an application `e1 @ e2`.
-- In ordinary predicate logic, we generate a type variable `?M` and add a
-- constraint `<type-of-e1> == <type-of-e2> -> ?M`. In dependent situation, however,
-- we cannot take this approach, since the `?M` may depend on other terms defined
-- beforehand. If `?M` depends on other terms, we cannot define substitution for terms
-- that contain metavariables because we don't know whether a substitution {x := e}
-- affects the content of a metavariable.
-- To handle this situation, we define metavariables to be *closed*. To represent
-- dependence, we apply all the names defined beforehand to the metavariables.
-- In other words, when we generate a metavariable, we use `?M @ (x1, ..., xn)` as a
-- representation of the hole, where x1, ..., xn are the defined names, or the context.
-- With this design, we can handle dependence in a simple way. This design decision
-- is due to "Elaboration in Dependent Type Theory". There also exists an approach
-- that deals with this situation which uses so-called contextual modality.
-- Interested readers are referred to A. Abel and B. Pientka. "Higher-Order
-- Dynamic Pattern Unification for Dependent Types and Records". Typed Lambda
-- Calculi and Applications, 2011.
-- {termはrename済みでclosed} infer' {termはrename済みでclosedで、かつすべてのsubtermが型でannotateされている}
infer :: WeakTermPlus -> WithEnv WeakTermPlus
infer e = do
  (e', _) <- infer' [] e
  let vs = varWeakTermPlus e'
  let info = toInfo "inferred term is not closed. freevars:" vs
  -- senv <- gets substEnv
  -- p' senv
  return $ assertP info e' $ null vs

infer' :: Context -> WeakTermPlus -> WithEnv (WeakTermPlus, WeakTermPlus)
infer' _ tau@(_, WeakTermTau) = return (tau, tau)
infer' _ (m, WeakTermUpsilon x) = do
  t <- lookupWeakTypeEnv x
  retWeakTerm t m $ WeakTermUpsilon x
infer' ctx (m, WeakTermPi xts t) = do
  (xts', t') <- inferPi ctx xts t
  retWeakTerm univ m $ WeakTermPi xts' t'
infer' ctx (m, WeakTermPiIntro xts e) = do
  (xts', (e', tCod)) <- inferBinder ctx xts e
  let piType = (emptyMeta, WeakTermPi xts' tCod)
  retWeakTerm piType m $ WeakTermPiIntro xts' e'
infer' ctx (m, WeakTermPiElim e@(_, WeakTermPiIntro xts _) es)
  | length xts == length es = do
    ets <- mapM (infer' ctx) es
    et <- infer' ctx e
    let es' = map fst ets
    -- let hss = map holeWeakTermPlus es'
    -- let defList = zip (map fst xts) (zip hss es')
    let defList = Map.fromList $ zip (map fst xts) es'
    modify (\env -> env {substEnv = defList `Map.union` substEnv env})
    inferPiElim ctx m et ets
infer' ctx (m, WeakTermPiElim e es) = do
  ets <- mapM (infer' ctx) es
  et <- infer' ctx e
  inferPiElim ctx m et ets
infer' ctx (m, WeakTermIter (x, t) xts e) = do
  t' <- inferType ctx t
  insWeakTypeEnv x t'
  -- Note that we cannot extend context with x. The type of e cannot be dependent on `x`.
  -- Otherwise the type of `mu x. e` might have `x` as free variable, which is unsound.
  (xts', (e', tCod)) <- inferBinder ctx xts e
  let piType = (emptyMeta, WeakTermPi xts' tCod)
  insConstraintEnv t' piType
  retWeakTerm piType m $ WeakTermIter (x, t') xts' e'
infer' ctx (m, WeakTermZeta _)
  -- zetaから変換先をlookupできるようにしておいたほうが正しい？
 = do
  (app, higherApp) <- newHoleInCtx ctx m
  return (app, higherApp)
infer' _ (m, WeakTermConst x)
  -- enum.n8, enum.n64, etc.
  | Just i <- asEnumNatNumConstant x = do
    t' <- toIsEnumType i
    retWeakTerm t' m $ WeakTermConst x
  -- i64, f16, u8, etc.
  | Just _ <- asLowTypeMaybe x = retWeakTerm univ m $ WeakTermConst x
  | otherwise = do
    t <- lookupWeakTypeEnv x
    retWeakTerm t m $ WeakTermConst x
infer' ctx (m, WeakTermConstDecl (x, t) e) = do
  t' <- inferType ctx t
  insWeakTypeEnv x t'
  -- the type of `e` doesn't depend on `x`
  (e', t'') <- infer' ctx e
  retWeakTerm t'' m $ WeakTermConstDecl (x, t') e'
infer' _ (m, WeakTermIntS size i) = do
  let t = (emptyMeta, WeakTermConst $ "i" <> T.pack (show size))
  retWeakTerm t m $ WeakTermIntS size i
infer' _ (m, WeakTermIntU size i) = do
  let t = (emptyMeta, WeakTermConst $ "u" <> T.pack (show size))
  retWeakTerm t m $ WeakTermIntU size i
infer' ctx (m, WeakTermInt t i) = do
  t' <- inferType ctx t
  -- holeはemptyにしたほうが妥当かも？
  retWeakTerm t' m $ WeakTermInt t' i
infer' _ (m, WeakTermFloat16 f) = do
  let t = (emptyMeta, WeakTermConst "f16")
  retWeakTerm t m $ WeakTermFloat16 f
infer' _ (m, WeakTermFloat32 f) = do
  let t = (emptyMeta, WeakTermConst "f32")
  retWeakTerm t m $ WeakTermFloat32 f
infer' _ (m, WeakTermFloat64 f) = do
  let t = (emptyMeta, WeakTermConst "f64")
  retWeakTerm t m $ WeakTermFloat64 f
infer' ctx (m, WeakTermFloat t f) = do
  t' <- inferType ctx t
  retWeakTerm t' m $ WeakTermFloat t' f
infer' _ (m, WeakTermEnum name) = retWeakTerm univ m $ WeakTermEnum name
infer' _ (m, WeakTermEnumIntro labelOrNum) = do
  case labelOrNum of
    EnumValueLabel l -> do
      k <- lookupKind l
      let t = (emptyMeta, WeakTermEnum $ EnumTypeLabel k)
      retWeakTerm t m $ WeakTermEnumIntro labelOrNum
    EnumValueNatNum i _ -> do
      let t = (emptyMeta, WeakTermEnum $ EnumTypeNatNum i)
      retWeakTerm t m $ WeakTermEnumIntro labelOrNum
infer' ctx (m, WeakTermEnumElim (e, t) les) = do
  t'' <- inferType ctx t
  (e', t') <- infer' ctx e
  insConstraintEnv t'' t'
  if null les
    then do
      h <- newTypeHoleInCtx ctx
      retWeakTerm h m $ WeakTermEnumElim (e', t') [] -- ex falso quodlibet
    else do
      let (ls, _) = unzip les
      tls <- mapM inferCase ls
      constrainList $ t' : catMaybes tls
      (es', ts) <- unzip <$> mapM (inferEnumElim ctx (e', t')) les
      constrainList $ ts
      retWeakTerm (head ts) m $ WeakTermEnumElim (e', t') $ zip ls es'
infer' ctx (m, WeakTermArray dom k) = do
  dom' <- inferType ctx dom
  retWeakTerm univ m $ WeakTermArray dom' k
infer' ctx (m, WeakTermArrayIntro k es) = do
  let tCod = inferKind k
  (es', ts) <- unzip <$> mapM (infer' ctx) es
  constrainList $ tCod : ts
  let len = toInteger $ length es
  let dom = (emptyMeta, WeakTermEnum (EnumTypeNatNum len))
  let t = (emptyMeta, WeakTermArray dom k)
  retWeakTerm t m $ WeakTermArrayIntro k es'
infer' ctx (m, WeakTermArrayElim k xts e1 e2) = do
  (e1', t1) <- infer' ctx e1
  (xts', (e2', t2)) <- inferBinder ctx xts e2
  let len = toInteger $ length xts
  let dom = (emptyMeta, WeakTermEnum (EnumTypeNatNum len))
  insConstraintEnv t1 (emptyMeta, WeakTermArray dom k)
  constrainList $ inferKind k : map snd xts'
  retWeakTerm t2 m $ WeakTermArrayElim k xts' e1' e2'
infer' _ (m, WeakTermStruct ts) = retWeakTerm univ m $ WeakTermStruct ts
infer' ctx (m, WeakTermStructIntro eks) = do
  let (es, ks) = unzip eks
  let ts = map inferKind ks
  let structType = (emptyMeta, WeakTermStruct ks)
  (es', ts') <- unzip <$> mapM (infer' ctx) es
  forM_ (zip ts ts') $ uncurry insConstraintEnv
  retWeakTerm structType m $ WeakTermStructIntro $ zip es' ks
infer' ctx (m, WeakTermStructElim xks e1 e2) = do
  (e1', t1) <- infer' ctx e1
  let (xs, ks) = unzip xks
  let ts = map inferKind ks
  let structType = (emptyMeta, WeakTermStruct ks)
  insConstraintEnv t1 structType
  let xts = zip xs ts
  forM_ xts $ uncurry insWeakTypeEnv
  (e2', t2) <- infer' (ctx ++ xts) e2
  retWeakTerm t2 m $ WeakTermStructElim xks e1' e2'

-- {} inferType {}
inferType :: Context -> WeakTermPlus -> WithEnv WeakTermPlus
inferType ctx t = do
  (t', u) <- infer' ctx t
  insConstraintEnv u univ
  return t'

-- {} inferKind {}
inferKind :: ArrayKind -> WeakTermPlus
inferKind (ArrayKindIntS i) =
  (emptyMeta, WeakTermConst $ "i" <> T.pack (show i))
inferKind (ArrayKindIntU i) =
  (emptyMeta, WeakTermConst $ "u" <> T.pack (show i))
inferKind (ArrayKindFloat size) =
  (emptyMeta, WeakTermConst $ "f" <> T.pack (show (sizeAsInt size)))
inferKind _ = error "inferKind for void-pointer"

-- {} inferPi {}
inferPi ::
     Context
  -> [(Identifier, WeakTermPlus)]
  -> WeakTermPlus
  -> WithEnv ([(Identifier, WeakTermPlus)], WeakTermPlus)
inferPi ctx [] cod = do
  cod' <- inferType ctx cod
  return ([], cod')
inferPi ctx ((x, t):xts) cod = do
  t' <- inferType ctx t
  insWeakTypeEnv x t'
  (xts', cod') <- inferPi (ctx ++ [(x, t')]) xts cod
  return ((x, t') : xts', cod')

-- {} inferBinder {}
inferBinder ::
     Context
  -> [(Identifier, WeakTermPlus)]
  -> WeakTermPlus
  -> WithEnv ([(Identifier, WeakTermPlus)], (WeakTermPlus, WeakTermPlus))
inferBinder ctx [] e = do
  et' <- infer' ctx e
  return ([], et')
inferBinder ctx ((x, t):xts) e = do
  t' <- inferType ctx t
  insWeakTypeEnv x t'
  (xts', et') <- inferBinder (ctx ++ [(x, t')]) xts e
  return ((x, t') : xts', et')

-- {} inferPiElim {}
inferPiElim ::
     Context
  -> Meta
  -> (WeakTermPlus, WeakTermPlus)
  -> [(WeakTermPlus, WeakTermPlus)]
  -> WithEnv (WeakTermPlus, WeakTermPlus)
inferPiElim ctx m (e, t) ets = do
  let (es, ts) = unzip ets
  case t of
    (_, WeakTermPi xts cod) -- performance optimization (not necessary for correctness)
      | length xts == length ets -> do
        let xs = map fst xts
        let ts' = map (substWeakTermPlus (zip xs es) . snd) xts
        forM_ (zip ts ts') $ uncurry insConstraintEnv
        let cod' = substWeakTermPlus (zip xs es) cod
        retWeakTerm cod' m $ WeakTermPiElim e es
    _ -> do
      ys <- mapM (const $ newNameWith "arg") es
      -- yts = [(y1, ?M1 @ (ctx[0], ..., ctx[n])),
      --        (y2, ?M2 @ (ctx[0], ..., ctx[n], y1)),
      --        ...,
      --        (ym, ?Mm @ (ctx[0], ..., ctx[n], y1, ..., y{m-1}))]
      yts <- newTypeHoleListInCtx ctx ys
      -- ts' = [?M1 @ (ctx[0], ..., ctx[n]),
      --        ?M2 @ (ctx[0], ..., ctx[n], e1),
      --        ...,
      --        ?Mm @ (ctx[0], ..., ctx[n], e1, ..., e{m-1})]
      let ts' = map (substWeakTermPlus (zip ys es) . snd) yts
      forM_ (zip ts ts') $ uncurry insConstraintEnv
      cod <- newTypeHoleInCtx (ctx ++ yts)
      let tPi = (emptyMeta, WeakTermPi yts cod)
      insConstraintEnv tPi t
      let cod' = substWeakTermPlus (zip ys es) cod
      retWeakTerm cod' m $ WeakTermPiElim e es

inferEnumElim ::
     Context
  -> (WeakTermPlus, WeakTermPlus)
  -> (Case, WeakTermPlus)
  -> WithEnv (WeakTermPlus, WeakTermPlus)
inferEnumElim ctx _ (CaseDefault, e) = infer' ctx e
inferEnumElim ctx ((_, WeakTermUpsilon x), enumType) (CaseValue v, e) = do
  x' <- newNameWith x
  -- infer `let xi := v in e{x := xi}`, with replacing all the occurrences of
  -- `x` in the type of `e{x := xi}` with `xi`.
  -- ctx must be extended since we're emulating the inference of `e{x := xi}` in `let xi := v in e{x := xi}`.
  let ctx' = ctx ++ [(x', enumType)]
  -- emulate the inference of the `let` part of `let xi := v in e{x := xi}`
  let val = (emptyMeta, WeakTermEnumIntro v)
  modify (\env -> env {substEnv = Map.insert x' val (substEnv env)})
  -- the `e{x := xi}` part
  let var = (emptyMeta, WeakTermUpsilon x')
  (e', t) <- infer' ctx' $ substWeakTermPlus [(x, var)] e
  let t' = substWeakTermPlus [(x, var)] t
  -- return `let xi := v in e{x := xi}`
  let e'' =
        ( emptyMeta
        , WeakTermPiElim
            (emptyMeta, WeakTermPiIntro [(x', enumType)] e')
            [(emptyMeta, WeakTermEnumIntro v)])
  return (e'', t')
inferEnumElim ctx _ (_, e) = infer' ctx e
  -- x <- newNameWith "hole-enum"
  -- h <- newTypeHoleInCtx $ ctx ++ [(x, enumType)]
  -- (e', t) <- infer' ctx e
  -- insConstraintEnv t $ substWeakTermPlus [(x, enumTerm)] h
  -- let sub = [(x, (emptyMeta, WeakTermEnumIntro v))]
  -- return (e', substWeakTermPlus sub h)

-- In a context (x1 : A1, ..., xn : An), this function creates metavariables
--   ?M  : Pi (x1 : A1, ..., xn : An). ?Mt @ (x1, ..., xn)
--   ?Mt : Pi (x1 : A1, ..., xn : An). Univ
-- and return ?M @ (x1, ..., xn) : ?Mt @ (x1, ..., xn).
-- Note that we can't just set `?M : Pi (x1 : A1, ..., xn : An). Univ` since
-- WeakTermZeta might be used as an ordinary term, that is, a term which is not a type.
-- {} newHoleInCtx {}
newHoleInCtx :: Context -> Meta -> WithEnv (WeakTermPlus, WeakTermPlus)
newHoleInCtx ctx m = do
  higherHole <- newHole
  let varSeq = map (toVar . fst) ctx
  let higherApp = (m, WeakTermPiElim higherHole varSeq)
  hole <- newHole
  let app = (m, WeakTermPiElim hole varSeq)
  return (app, higherApp)

-- In a context (x1 : A1, ..., xn : An), this function creates a metavariable
--   ?M  : Pi (x1 : A1, ..., xn : An). Univ
-- and return ?M @ (x1, ..., xn) : Univ.
newTypeHoleInCtx :: Context -> WithEnv WeakTermPlus
newTypeHoleInCtx ctx = do
  let varSeq = map (toVar . fst) ctx
  hole <- newHole
  return (emptyMeta, WeakTermPiElim hole varSeq)

-- In context ctx == [x1, ..., xn], `newTypeHoleListInCtx ctx [y1, ..., ym]` generates
-- the following list:
--
--   [(y1,   ?M1   @ (x1, ..., xn)),
--    (y2,   ?M2   @ (x1, ..., xn, y1),
--    ...,
--    (y{m}, ?M{m} @ (x1, ..., xn, y1, ..., y{m-1}))]
--
-- inserting type information `yi : ?Mi @ (x1, ..., xn, y1, ..., y{i-1})
newTypeHoleListInCtx ::
     Context -> [Identifier] -> WithEnv [(Identifier, WeakTermPlus)]
newTypeHoleListInCtx _ [] = return []
newTypeHoleListInCtx ctx (x:rest) = do
  t <- newTypeHoleInCtx ctx
  insWeakTypeEnv x t
  ts <- newTypeHoleListInCtx (ctx ++ [(x, t)]) rest
  return $ (x, t) : ts

inferCase :: Case -> WithEnv (Maybe WeakTermPlus)
inferCase (CaseValue (EnumValueLabel name)) = do
  k <- lookupKind name
  return $ Just (emptyMeta, WeakTermEnum $ EnumTypeLabel k)
inferCase (CaseValue (EnumValueNatNum i _)) =
  return $ Just (emptyMeta, WeakTermEnum $ EnumTypeNatNum i)
inferCase _ = return Nothing

constrainList :: [WeakTermPlus] -> WithEnv ()
constrainList [] = return ()
constrainList [_] = return ()
constrainList (t1:t2:ts) = do
  insConstraintEnv t1 t2
  constrainList $ t2 : ts

retWeakTerm ::
     WeakTermPlus -> Meta -> WeakTerm -> WithEnv (WeakTermPlus, WeakTermPlus)
retWeakTerm t m e = return ((m, e), t)

-- is-enum n{i}
toIsEnumType :: Integer -> WithEnv WeakTermPlus
toIsEnumType i = do
  return
    ( emptyMeta
    , WeakTermPiElim
        (emptyMeta, WeakTermConst "is-enum")
        [(emptyMeta, WeakTermEnum $ EnumTypeNatNum i)])

newHole :: WithEnv WeakTermPlus
newHole = do
  h <- newNameWith "hole"
  return (emptyMeta, WeakTermZeta h)

-- determineDomType :: [WeakTermPlus] -> WeakTermPlus
-- determineDomType ts =
--   if not (null ts)
--     then head ts
--     else (emptyMeta, WeakTermConst "bottom")
insConstraintEnv :: WeakTermPlus -> WeakTermPlus -> WithEnv ()
insConstraintEnv t1 t2 =
  modify (\e -> e {constraintEnv = (t1, t2) : constraintEnv e})

insWeakTypeEnv :: Identifier -> WeakTermPlus -> WithEnv ()
insWeakTypeEnv i t =
  modify (\e -> e {weakTypeEnv = Map.insert i t (weakTypeEnv e)})

lookupWeakTypeEnv :: Identifier -> WithEnv WeakTermPlus
lookupWeakTypeEnv s = do
  mt <- lookupWeakTypeEnvMaybe s
  case mt of
    Just t -> return t
    Nothing -> throwError $ s <> " is not found in the type environment."

lookupWeakTypeEnvMaybe :: Identifier -> WithEnv (Maybe WeakTermPlus)
lookupWeakTypeEnvMaybe s = do
  mt <- gets (Map.lookup s . weakTypeEnv)
  case mt of
    Nothing -> return Nothing
    Just t -> return $ Just t

lookupKind :: Identifier -> WithEnv Identifier
lookupKind name = do
  renv <- gets revEnumEnv
  case Map.lookup name renv of
    Nothing -> throwError $ "no such enum-intro is defined: " <> name
    Just j -> return j
