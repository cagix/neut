module Entity.Term.Reduce (reduce) where

import Control.Comonad.Cofree
import Control.Monad
import qualified Data.IntMap as IntMap
import Entity.Basic
import Entity.Term
import Entity.Term.Subst

-- reduce given term assuming its purity
reduce :: Term -> IO Term
reduce term =
  case term of
    (m :< TermPi xts cod) -> do
      let (ms, xs, ts) = unzip3 xts
      ts' <- mapM reduce ts
      cod' <- reduce cod
      return (m :< TermPi (zip3 ms xs ts') cod')
    (m :< TermPiIntro kind xts e) -> do
      let (ms, xs, ts) = unzip3 xts
      ts' <- mapM reduce ts
      e' <- reduce e
      case kind of
        LamKindFix (mx, x, t) -> do
          t' <- reduce t
          return (m :< TermPiIntro (LamKindFix (mx, x, t')) (zip3 ms xs ts') e')
        _ ->
          return (m :< TermPiIntro kind (zip3 ms xs ts') e')
    (m :< TermPiElim e es) -> do
      e' <- reduce e
      es' <- mapM reduce es
      let app = TermPiElim e' es'
      case e' of
        -- (_ :< TermPiIntro opacity LamKindNormal xts body)
        (_ :< TermPiIntro LamKindNormal xts (_ :< body))
          | length xts == length es' -> do
            let xs = map (\(_, x, _) -> asInt x) xts
            let sub = IntMap.fromList $ zip xs es'
            subst sub (m :< body) >>= reduce
        _ ->
          return (m :< app)
    m :< TermSigma xts -> do
      let (ms, xs, ts) = unzip3 xts
      ts' <- mapM reduce ts
      return $ m :< TermSigma (zip3 ms xs ts')
    m :< TermSigmaIntro es -> do
      es' <- mapM reduce es
      return $ m :< TermSigmaIntro es'
    m :< TermSigmaElim xts e1 e2 -> do
      e1' <- reduce e1
      case e1' of
        _ :< TermSigmaIntro es
          | length xts == length es -> do
            let xs = map (\(_, x, _) -> asInt x) xts
            let sub = IntMap.fromList $ zip xs es
            subst sub e2 >>= reduce
        _ -> do
          e2' <- reduce e2
          return $ m :< TermSigmaElim xts e1' e2'
    _ :< TermLet (_, x, _) e1 e2 -> do
      e1' <- reduce e1
      let sub = IntMap.fromList [(asInt x, e1')]
      subst sub e2
    (m :< TermEnumElim (e, t) les) -> do
      e' <- reduce e
      let (ls, es) = unzip les
      es' <- mapM reduce es
      let les' = zip ls es'
      let les'' = zip (map unwrap ls) es'
      t' <- reduce t
      case e' of
        (_ :< TermEnumIntro l) ->
          case lookup (EnumCaseLabel l) les'' of
            Just (_ :< body) ->
              reduce (m :< body)
            Nothing ->
              case lookup EnumCaseDefault les'' of
                Just (_ :< body) ->
                  reduce (m :< body)
                Nothing ->
                  return (m :< TermEnumElim (e', t') les')
        _ ->
          return (m :< TermEnumElim (e', t') les')
    (m :< TermMagic der) -> do
      der' <- traverse reduce der
      return (m :< TermMagic der')
    (m :< TermMatch mSubject (e, t) clauseList) -> do
      e' <- reduce e
      -- let lamList = map (toLamList m) clauseList
      -- dataEnv <- readIORef dataEnvRef
      -- case e' of
      -- (_ :< TermPiIntro (LamKindCons dataName consName _ _) _ _)
      --   | Just consNameList <- Map.lookup dataName dataEnv,
      --     consName `elem` consNameList,
      --     checkClauseListSanity consNameList clauseList -> do
      --     let app = m :< TermPiElim e' lamList
      --     reduce app
      -- _ -> do
      mSubject' <- mapM reduce mSubject
      t' <- reduce t
      clauseList' <- forM clauseList $ \((mPat, name, xts), body) -> do
        body' <- reduce body
        return ((mPat, name, xts), body')
      return (m :< TermMatch mSubject' (e', t') clauseList')
    m :< TermNoema s e -> do
      s' <- reduce s
      e' <- reduce e
      return $ m :< TermNoema s' e'
    m :< TermNoemaIntro s e -> do
      e' <- reduce e
      return $ m :< TermNoemaIntro s e'
    m :< TermNoemaElim s e -> do
      e' <- reduce e
      return $ m :< TermNoemaElim s e'
    _ :< TermArray _ ->
      return term
    m :< TermArrayIntro elemType elems -> do
      elems' <- mapM reduce elems
      return $ m :< TermArrayIntro elemType elems'
    m :< TermArrayAccess subject elemType array index -> do
      subject' <- reduce subject
      array' <- reduce array
      index' <- reduce index
      return $ m :< TermArrayAccess subject' elemType array' index'
    _ ->
      return term

-- checkClauseListSanity :: [T.Text] -> [(PatternF Term, Term)] -> Bool
-- checkClauseListSanity consNameList clauseList =
--   case (consNameList, clauseList) of
--     ([], []) ->
--       True
--     (consName : restConsNameList, ((_, name, _), _) : restClauseList)
--       | consName == name ->
--         checkClauseListSanity restConsNameList restClauseList
--     _ ->
--       False

-- toLamList :: Hint -> (PatternF Term, Term) -> Term
-- toLamList m ((_, _, xts), body) =
--   m :< TermPiIntro LamKindNormal xts body
