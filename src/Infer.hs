module Infer
  ( check
  , unify
  ) where

import           Control.Monad
import           Control.Monad.State
import           Control.Monad.Trans.Except

import           Control.Comonad.Cofree

import qualified Text.Show.Pretty           as Pr

import           Data
import           Data.List
import           Data.Maybe

check :: Identifier -> Neut -> WithEnv Neut
check main e = do
  t <- infer e
  insTypeEnv main t -- insert the type of main function
  affineConstraint' e
  env <- get
  liftIO $ putStrLn $ "constraint = " ++ Pr.ppShow (constraintEnv env)
  sub <- unifyLoop (constraintEnv env) 0
  let (is, ts) = unzip $ typeEnv env
  let ts' = map (subst sub) ts
  let tenv' = zip is ts'
  modify (\e -> e {typeEnv = tenv', constraintEnv = []})
  return $ subst sub e

infer :: Neut -> WithEnv Neut
infer (meta :< NeutVar s) = do
  t <- lookupTypeEnv' s
  returnMeta meta t
infer (meta :< NeutPi (s, tdom) tcod) = inferBinder meta s tdom tcod
infer (meta :< NeutPiIntro (s, tdom) e) = do
  insTypeEnv s tdom
  udom <- infer tdom
  tcod <- infer e
  ucod <- infer tcod
  insConstraintEnv udom ucod
  wrapTypeWithUniv udom (NeutPi (s, tdom) tcod) >>= returnMeta meta
infer (meta :< NeutPiElim e1 e2) = do
  tPi <- infer e1 -- forall (x : tdom). tcod
  tdom <- infer e2
  udom <- infer tdom
  codName <- newName
  tcod <- wrapType $ NeutHole codName
  ucod <- infer tcod
  insConstraintEnv udom ucod
  x <- newNameOfType tdom
  typeMeta2 <- newNameWith "meta"
  insTypeEnv typeMeta2 udom
  insConstraintEnv tPi (typeMeta2 :< NeutPi (x, tdom) tcod) -- t1 == forall (x : tdom). tcod
  insEqEnv $ EquationPiElim tPi e2 codName
  undefined
  -- returnMeta meta $ explicitSubst tcod [(x, e2)]
infer (meta :< NeutSigma (s, tdom) tcod) = inferBinder meta s tdom tcod
infer (meta :< NeutSigmaIntro e1 e2) = do
  t1 <- infer e1 -- A
  t2 <- infer e2 -- B {x := e1}
  u1 <- infer t1
  u2 <- infer t2
  insConstraintEnv u1 u2
  t2nosub <- newHole -- B
  x <- newNameOfType t1
  -- let t2sub = explicitSubst t2nosub [(x, e1)]
  let t2sub = undefined
  insConstraintEnv t2 t2sub
  wrapTypeWithUniv u1 (NeutSigma (x, t1) t2nosub) >>= returnMeta meta -- Sigma (x : A). B
infer (meta :< NeutSigmaElim e1 (x, y) e2) = do
  t1 <- infer e1
  u1 <- infer t1
  tx <- newHole
  ux <- infer tx
  ty <- newHole
  uy <- infer ty
  t2 <- infer e2
  u2 <- infer t2
  insTypeEnv x tx
  insTypeEnv y ty
  insConstraintEnv u1 u2
  insConstraintEnv u1 ux
  insConstraintEnv ux uy
  sigmaType <- wrapType $ NeutSigma (x, tx) ty
  insConstraintEnv t1 sigmaType
  z <- newNameOfType t1
  pair <- constructPair x y
  holeName <- newName
  resultHole <- wrapType $ NeutHole holeName
  -- insConstraintEnv t2 $ explicitSubst resultHole [(z, pair)]
  insEqEnv $ EquationSigmaElim e1 (t2, (x, y)) holeName
  returnMeta meta $ undefined
  -- returnMeta meta $ explicitSubst resultHole [(z, e1)]
infer (meta :< NeutBox t) = do
  u <- infer t
  returnMeta meta u
infer (meta :< NeutBoxIntro e) = do
  t <- infer e
  affineConstraint e
  u <- infer t
  wrapTypeWithUniv u (NeutBox t) >>= returnMeta meta
infer (meta :< NeutBoxElim e) = do
  t <- infer e
  holeName <- newName
  resultHole <- wrapType $ NeutHole holeName
  boxType <- wrapType $ NeutBox resultHole
  insConstraintEnv t boxType
  returnMeta meta resultHole
infer (meta :< NeutMu s e) = do
  trec <- newHole
  insTypeEnv s trec
  te <- infer e
  insConstraintEnv te trec
  returnMeta meta te
infer (meta :< NeutIndex _) = do
  hole <- newName
  wrap (NeutUniv (UnivLevelHole hole)) >>= returnMeta meta
infer (meta :< NeutIndexIntro l) = do
  mk <- lookupKind l
  case mk of
    Just k -> do
      t <- wrapType $ NeutIndex k
      returnMeta meta t
    Nothing -> undefined -- shouldn't occur
infer (_ :< NeutIndexElim _ []) = lift $ throwE "empty branch"
infer (meta :< NeutIndexElim e branchList) = do
  t <- infer e
  let (labelList, es) = unzip branchList
  tls <- mapM inferIndex labelList
  let tls' = join $ map maybeToList tls
  constrainList tls'
  headConstraint t tls'
  tes <- mapM infer es
  constrainList tes
  returnMeta meta $ head tes
infer (meta :< NeutUniv l) =
  wrap (NeutUniv (UnivLevelNext l)) >>= returnMeta meta
infer (meta :< NeutHole _) = do
  hole <- newName
  wrap (NeutUniv (UnivLevelHole hole)) >>= returnMeta meta

inferIndex :: Index -> WithEnv (Maybe Neut)
inferIndex name = do
  mk <- lookupKind name
  case mk of
    Just k  -> Just <$> wrapType (NeutIndex k)
    Nothing -> return Nothing

constrainList :: [Neut] -> WithEnv ()
constrainList [] = return ()
constrainList [_] = return ()
constrainList (t1:t2:ts) = do
  insConstraintEnv t1 t2
  constrainList $ t2 : ts

headConstraint :: Neut -> [Neut] -> WithEnv ()
headConstraint _ []      = return ()
headConstraint t1 (t2:_) = insConstraintEnv t1 t2

inferBinder :: Identifier -> Identifier -> Neut -> Neut -> WithEnv Neut
inferBinder meta s tdom tcod = do
  udom <- infer tdom
  insTypeEnv s tdom
  ucod <- infer tcod
  insConstraintEnv udom ucod
  returnMeta meta udom

constructPair :: Identifier -> Identifier -> WithEnv Neut
constructPair x y = do
  eMeta <- newName
  xMeta <- newName
  yMeta <- newName
  let pair = eMeta :< NeutSigmaIntro (xMeta :< NeutVar x) (yMeta :< NeutVar y)
  _ <- infer pair
  return pair

newNameOfType :: Neut -> WithEnv Identifier
newNameOfType t = do
  i <- newName
  insTypeEnv i t
  return i

-- explicitSubst :: Neut -> [(Identifier, Neut)] -> Neut
-- explicitSubst e1 sub = "" :< NeutSubst e1 sub
newHole :: WithEnv Neut
newHole = do
  i <- newName
  wrapType $ NeutHole i

returnMeta :: Identifier -> Neut -> WithEnv Neut
returnMeta meta t = do
  insTypeEnv meta t
  return t

type Constraint = [(Neut, Neut)]

unifyLoop :: Constraint -> Int -> WithEnv Subst
unifyLoop [] _ = return []
unifyLoop ((e1, e2):cs) loopCount = do
  e1' <- reduce e1
  e2' <- reduce e2
  (s, tmpConstraint) <- unify ((e1', e2') : cs)
  liftIO $ putStrLn $ "subst:\n " ++ Pr.ppShow s
  case tmpConstraint of
    [] -> return s
    (e1'', e2''):cs' -> do
      let loopCount' = nextLoopCount (length cs) (length cs') loopCount
      if didFinishLoop (length cs') loopCount'
        then do
          env <- get
          eqEnv' <- mapM (substEq s) $ eqEnv env
          (eqEnv'', sEq) <- unifyEq eqEnv'
          case sEq of
            [] -> do
              liftIO $ putStrLn $ "failing unification. subst:\n" ++ Pr.ppShow s
              unificationFailed e1'' e2'' cs'
            _ -> do
              liftIO $ putStrLn $ "additionalSubst:\n " ++ Pr.ppShow sEq
              eqEnv''' <- mapM (substEq sEq) eqEnv''
              modify (\e -> e {eqEnv = eqEnv'''})
              newConstraints <- sConstraint sEq (cs' ++ [(e1'', e2'')])
              s' <- unifyLoop newConstraints 0
              return (s ++ s')
        else do
          s' <- unifyLoop (cs' ++ [(e1'', e2'')]) loopCount'
          return (s ++ s')

unificationFailed :: Neut -> Neut -> Constraint -> WithEnv Subst
unificationFailed e1 e2 cs = do
  env <- get
  lift $
    throwE $
    "unification failed for\n" ++
    Pr.ppShow e1 ++
    "\nand\n" ++
    Pr.ppShow e2 ++
    "\nwith constraints:\n" ++
    Pr.ppShow cs ++
    "\ntypeEnv:\n" ++
    Pr.ppShow (typeEnv env) ++ "\neqEnv:\n" ++ Pr.ppShow (eqEnv env)

nextLoopCount :: Int -> Int -> Int -> Int
nextLoopCount i j loopCount = do
  let lenOld = i + 1
  let lenNew = j + 1
  if lenOld <= lenNew
    then loopCount + 1
    else 0

didFinishLoop :: Int -> Int -> Bool
didFinishLoop j loopCount' = loopCount' >= j + 2

unify :: Constraint -> WithEnv (Subst, Constraint)
unify [] = return ([], [])
unify ((_ :< NeutHole s, t2):cs) = do
  liftIO $ putStrLn $ "found a substition:\n" ++ Pr.ppShow (s, t2)
  cs' <- sConstraint [(s, t2)] cs
  (sub, cs'') <- unify cs'
  let sub' = compose sub [(s, t2)]
  return (sub', cs'')
unify ((t1, _ :< NeutHole s):cs) = do
  liftIO $ putStrLn $ "found a substition:\n" ++ Pr.ppShow (s, t1)
  cs' <- sConstraint [(s, t1)] cs
  (sub, cs'') <- unify cs'
  let sub' = compose sub [(s, t1)]
  return (sub', cs'')
unify ((_ :< NeutVar s1, _ :< NeutVar s2):cs)
  | s1 == s2 = unify cs
unify ((_ :< NeutPi (_, tdom1) tcod1, _ :< NeutPi (_, tdom2) tcod2):cs) =
  unify $ (tdom1, tdom2) : (tcod1, tcod2) : cs
unify ((_ :< NeutSigma (_, tdom1) tcod1, _ :< NeutSigma (_, tdom2) tcod2):cs) =
  unify $ (tdom1, tdom2) : (tcod1, tcod2) : cs
unify ((_ :< NeutBox t1, _ :< NeutBox t2):cs) = unify $ (t1, t2) : cs
unify ((_ :< NeutIndex l1, _ :< NeutIndex l2):cs)
  | l1 == l2 = unify cs
unify ((_ :< NeutUniv i, _ :< NeutUniv j):cs) = do
  insUnivConstraintEnv i j
  unify cs
unify cs = return ([], cs)

sConstraint :: Subst -> Constraint -> WithEnv Constraint
sConstraint s cs = do
  let (ts1, ts2) = unzip cs
  let ts1' = map (subst s) ts1
  let ts2' = map (subst s) ts2
  return $ zip ts1' ts2'

-- e is strong <=> e does not contain any holes
isStrong :: Neut -> WithEnv Bool
isStrong (_ :< NeutVar _) = return True
isStrong (_ :< NeutPi (_, tdom) tcod) = do
  b1 <- isStrong tdom
  b2 <- isStrong tcod
  return $ b1 && b2
isStrong (_ :< NeutPiIntro (_, tdom) e) = do
  b1 <- isStrong tdom
  b2 <- isStrong e
  return $ b1 && b2
isStrong (_ :< NeutPiElim e1 e2) = do
  b1 <- isStrong e1
  b2 <- isStrong e2
  return $ b1 && b2
isStrong (_ :< NeutSigma (_, t1) t2) = do
  b1 <- isStrong t1
  b2 <- isStrong t2
  return $ b1 && b2
isStrong (_ :< NeutSigmaIntro e1 e2) = do
  b1 <- isStrong e1
  b2 <- isStrong e2
  return $ b1 && b2
isStrong (_ :< NeutSigmaElim e1 (_, _) e2) = do
  b1 <- isStrong e1
  b2 <- isStrong e2
  return $ b1 && b2
isStrong (_ :< NeutBox e) = isStrong e
isStrong (_ :< NeutBoxIntro e) = isStrong e
isStrong (_ :< NeutBoxElim e) = isStrong e
isStrong (_ :< NeutMu _ e) = isStrong e
isStrong (_ :< NeutIndex _) = return True
isStrong (_ :< NeutIndexIntro _) = return True
isStrong (_ :< NeutIndexElim e1 branchList) = do
  let (_, es) = unzip branchList
  b1 <- isStrong e1
  bs <- mapM isStrong es
  return $ b1 && and bs
isStrong (_ :< NeutUniv _) = return True
isStrong (_ :< NeutHole _) = return False

substEq :: Subst -> Equation -> WithEnv Equation
substEq sub (EquationPiElim t1 e2 hole) = do
  let t1' = subst sub t1
  let e2' = subst sub e2
  return $ EquationPiElim t1' e2' hole
substEq sub (EquationSigmaElim e1 (t2, (x, y)) hole) = do
  let e1' = subst sub e1
  let t2' = subst sub t2
  return $ EquationSigmaElim e1' (t2', (x, y)) hole

unifyEq :: [Equation] -> WithEnv ([Equation], Subst)
unifyEq [] = return ([], [])
unifyEq (eq@(EquationPiElim t1 e2 hole):rest) = do
  b <- isStrong t1
  if not b
    then do
      (eqs, s) <- unifyEq rest
      return (eq : eqs, s)
    else case t1 of
           _ :< NeutPi (x, _) tcod -> do
             let t2' = subst [(x, e2)] tcod
             (eqs, s) <- unifyEq rest
             return (eqs, (hole, t2') : s)
           _ ->
             lift $
             throwE $
             "the type " ++
             Pr.ppShow t1 ++ " is expected to be a pi-type, but not."
unifyEq (eq@(EquationSigmaElim e1 (t2, (x, y)) hole):rest) = do
  b <- isStrong t2
  if not b
    then do
      (eqs, s) <- unifyEq rest
      return (eq : eqs, s)
    else do
      t2' <- substPair (x, y) e1 t2
      (eqs, s) <- unifyEq rest
      return (eqs, (hole, t2') : s)

substPair :: (Identifier, Identifier) -> Neut -> Neut -> WithEnv Neut
substPair _ _ e@(_ :< NeutVar _) = return e
substPair (x, y) dest (meta :< NeutPi (z, tdom) tcod) = do
  tdom' <- substPair (x, y) dest tdom
  tcod' <- substPair (x, y) dest tcod
  return $ meta :< NeutPi (z, tdom') tcod'
substPair (x, y) dest (meta :< NeutPiIntro (z, tdom) body) = do
  tdom' <- substPair (x, y) dest tdom
  body' <- substPair (x, y) dest body
  return $ meta :< NeutPiIntro (z, tdom') body'
substPair (x, y) dest (meta :< NeutPiElim e1 e2) = do
  e1' <- substPair (x, y) dest e1
  e2' <- substPair (x, y) dest e2
  return $ meta :< NeutPiElim e1' e2'
substPair (x, y) dest (meta :< NeutSigma (z, tl) tr) = do
  tl' <- substPair (x, y) dest tl
  tr' <- substPair (x, y) dest tr
  return $ meta :< NeutSigma (z, tl') tr'
substPair (x, y) dest (_ :< NeutSigmaIntro (_ :< NeutVar p) (_ :< NeutVar q))
  | p == x && q == y = return dest
substPair (x, y) dest (meta :< NeutSigmaIntro e1 e2) = do
  e1' <- substPair (x, y) dest e1
  e2' <- substPair (x, y) dest e2
  return $ meta :< NeutSigmaIntro e1' e2'
substPair (x, y) dest (meta :< NeutSigmaElim e1 (p, q) e2) = do
  e1' <- substPair (x, y) dest e1
  e2' <- substPair (x, y) dest e2
  return $ meta :< NeutSigmaElim e1' (p, q) e2'
substPair (x, y) dest (meta :< NeutBox e) = do
  e' <- substPair (x, y) dest e
  return $ meta :< NeutBox e'
substPair (x, y) dest (meta :< NeutBoxIntro e) = do
  e' <- substPair (x, y) dest e
  return $ meta :< NeutBoxIntro e'
substPair (x, y) dest (meta :< NeutBoxElim e) = do
  e' <- substPair (x, y) dest e
  return $ meta :< NeutBoxElim e'
substPair (x, y) dest (meta :< NeutMu z e) = do
  e' <- substPair (x, y) dest e
  return $ meta :< NeutMu z e'
substPair _ _ e@(_ :< NeutIndex _) = return e
substPair _ _ e@(_ :< NeutIndexIntro _) = return e
substPair (x, y) dest (meta :< NeutIndexElim e branchList) = do
  e' <- substPair (x, y) dest e
  let (labelList, es) = unzip branchList
  es' <- mapM (substPair (x, y) dest) es
  return $ meta :< NeutIndexElim e' (zip labelList es')
substPair _ _ e@(_ :< NeutUniv _) = return e
substPair _ _ e@(_ :< NeutHole _) = return e -- shouldn't occur

occursMoreThanTwice :: Eq a => [a] -> [a]
occursMoreThanTwice xs = do
  let ys = nub xs
  nub $ occursMoreThanTwice' ys xs

occursMoreThanTwice' :: Eq a => [a] -> [a] -> [a]
occursMoreThanTwice' ys xs = foldl (flip delete) xs ys

affineConstraint :: Neut -> WithEnv ()
affineConstraint e = do
  varList <- var e
  affineConstraint0 $ nub varList

affineConstraint' :: Neut -> WithEnv ()
affineConstraint' e = do
  varList <- var' e
  let xs = occursMoreThanTwice varList
  affineConstraint0 xs

affineConstraint0 :: [Identifier] -> WithEnv ()
affineConstraint0 xs =
  forM_ xs $ \x -> do
    t <- lookupTypeEnv' x
    h <- newHole
    boxType <- wrapType $ NeutBox h
    insConstraintEnv t boxType
