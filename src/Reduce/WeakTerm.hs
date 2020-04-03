{-# LANGUAGE OverloadedStrings #-}

module Reduce.WeakTerm
  ( reduceWeakTermPlus
  , reduceWeakTermIdentPlus
  ) where

import Data.WeakTerm

reduceWeakTermPlus :: WeakTermPlus -> WeakTermPlus
reduceWeakTermPlus (m, WeakTermPi mName xts cod) = do
  let (ms, xs, ts) = unzip3 xts
  let ts' = map reduceWeakTermPlus ts
  let cod' = reduceWeakTermPlus cod
  (m, WeakTermPi mName (zip3 ms xs ts') cod')
reduceWeakTermPlus (m, WeakTermPiIntro xts e) = do
  let (ms, xs, ts) = unzip3 xts
  let ts' = map reduceWeakTermPlus ts
  let e' = reduceWeakTermPlus e
  (m, WeakTermPiIntro (zip3 ms xs ts') e')
reduceWeakTermPlus (m, WeakTermPiIntroNoReduce xts e) = do
  let (ms, xs, ts) = unzip3 xts
  let ts' = map reduceWeakTermPlus ts
  let e' = reduceWeakTermPlus e
  (m, WeakTermPiIntroNoReduce (zip3 ms xs ts') e')
reduceWeakTermPlus (m, WeakTermPiIntroPlus ind (name, is, args1, args2) xts e) = do
  let args1' = map reduceWeakTermIdentPlus args1
  let args2' = map reduceWeakTermIdentPlus args2
  let xts' = map reduceWeakTermIdentPlus xts
  let e' = reduceWeakTermPlus e
  (m, WeakTermPiIntroPlus ind (name, is, args1', args2') xts' e')
reduceWeakTermPlus (m, WeakTermPiElim e es) = do
  let e' = reduceWeakTermPlus e
  let es' = map reduceWeakTermPlus es
  let app = WeakTermPiElim e' es'
  case e' of
    (_, WeakTermPiIntro xts body)
      | length xts == length es' -> do
        let xs = map (\(_, x, _) -> x) xts
        reduceWeakTermPlus $ substWeakTermPlus (zip xs es') body
    (_, WeakTermPiIntroPlus _ _ xts body)
      | length xts == length es' -> do
        let xs = map (\(_, x, _) -> x) xts
        reduceWeakTermPlus $ substWeakTermPlus (zip xs es') body
    _ -> (m, app)
reduceWeakTermPlus (m, WeakTermIter (mx, x, t) xts e)
  | x `notElem` varWeakTermPlus e = do
    reduceWeakTermPlus (m, WeakTermPiIntro xts e)
  | otherwise = do
    let t' = reduceWeakTermPlus t
    let e' = reduceWeakTermPlus e
    let (ms, xs, ts) = unzip3 xts
    let ts' = map reduceWeakTermPlus ts
    (m, WeakTermIter (mx, x, t') (zip3 ms xs ts') e')
reduceWeakTermPlus (m, WeakTermEnumElim (e, t) les) = do
  let e' = reduceWeakTermPlus e
  let (ls, es) = unzip les
  let es' = map reduceWeakTermPlus es
  let les' = zip ls es'
  let les'' = zip (map snd ls) es'
  let t' = reduceWeakTermPlus t
  case e' of
    (_, WeakTermEnumIntro l) ->
      case lookup (weakenEnumValue l) les'' of
        Just body -> reduceWeakTermPlus body
        Nothing ->
          case lookup WeakCaseDefault les'' of
            Just body -> reduceWeakTermPlus body
            Nothing -> (m, WeakTermEnumElim (e', t') les')
    _ -> (m, WeakTermEnumElim (e', t') les')
reduceWeakTermPlus (m, WeakTermArray dom k) = do
  let dom' = reduceWeakTermPlus dom
  (m, WeakTermArray dom' k)
reduceWeakTermPlus (m, WeakTermArrayIntro k es) = do
  let es' = map reduceWeakTermPlus es
  (m, WeakTermArrayIntro k es')
reduceWeakTermPlus (m, WeakTermArrayElim k xts e1 e2) = do
  let e1' = reduceWeakTermPlus e1
  case e1' of
    (_, WeakTermArrayIntro k' es)
      | length es == length xts
      , k == k' -> do
        let (_, xs, _) = unzip3 xts
        reduceWeakTermPlus $ substWeakTermPlus (zip xs es) e2
    _ -> (m, WeakTermArrayElim k xts e1' e2)
reduceWeakTermPlus (m, WeakTermStructIntro eks) = do
  let (es, ks) = unzip eks
  let es' = map reduceWeakTermPlus es
  (m, WeakTermStructIntro $ zip es' ks)
reduceWeakTermPlus (m, WeakTermStructElim xks e1 e2) = do
  let e1' = reduceWeakTermPlus e1
  case e1' of
    (_, WeakTermStructIntro eks)
      | (_, xs, ks1) <- unzip3 xks
      , (es, ks2) <- unzip eks
      , ks1 == ks2 -> reduceWeakTermPlus $ substWeakTermPlus (zip xs es) e2
    _ -> (m, WeakTermStructElim xks e1' e2)
reduceWeakTermPlus (m, WeakTermCase (e, t) cxtes) = do
  let e' = reduceWeakTermPlus e
  let t' = reduceWeakTermPlus t
  let cxtes'' =
        flip map cxtes $ \((c, xts), body) -> do
          let (ms, xs, ts) = unzip3 xts
          let ts' = map reduceWeakTermPlus ts
          let body' = reduceWeakTermPlus body
          ((c, zip3 ms xs ts'), body')
  (m, WeakTermCase (e', t') cxtes'')
reduceWeakTermPlus e = e

reduceWeakTermIdentPlus :: IdentifierPlus -> IdentifierPlus
reduceWeakTermIdentPlus (m, x, t) = (m, x, reduceWeakTermPlus t)
