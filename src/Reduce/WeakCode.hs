module Reduce.WeakCode
  ( reduceWeakCodePlus
  ) where

import           Control.Monad.Trans

import           Data.Basic
import           Data.Env
import           Data.WeakCode

reduceWeakCodePlus :: WeakCodePlus -> WithEnv WeakCodePlus
reduceWeakCodePlus (m, WeakCodeTheta theta) =
  case theta of
    ThetaArith ArithAdd (m1, WeakDataEpsilonIntro (LiteralInteger i1)) (_, WeakDataEpsilonIntro (LiteralInteger i2)) ->
      return
        ( m
        , WeakCodeUpIntro (m1, WeakDataEpsilonIntro (LiteralInteger $ i1 + i2)))
    ThetaArith ArithSub (m1, WeakDataEpsilonIntro (LiteralInteger i1)) (_, WeakDataEpsilonIntro (LiteralInteger i2)) ->
      return
        ( m
        , WeakCodeUpIntro (m1, WeakDataEpsilonIntro (LiteralInteger $ i1 - i2)))
    ThetaArith ArithMul (m1, WeakDataEpsilonIntro (LiteralInteger i1)) (_, WeakDataEpsilonIntro (LiteralInteger i2)) ->
      return
        ( m
        , WeakCodeUpIntro (m1, WeakDataEpsilonIntro (LiteralInteger $ i1 * i2)))
    ThetaArith ArithDiv (m1, WeakDataEpsilonIntro (LiteralInteger i1)) (_, WeakDataEpsilonIntro (LiteralInteger i2)) ->
      return
        ( m
        , WeakCodeUpIntro
            (m1, WeakDataEpsilonIntro (LiteralInteger $ i1 `div` i2)))
    ThetaPrint (_, WeakDataEpsilonIntro (LiteralInteger i)) -> do
      liftIO $ putStr $ show i
      let topType = (WeakDataMetaTerminal Nothing, WeakDataEpsilon "top")
      let topMeta = WeakDataMetaNonTerminal topType Nothing
      return
        ( m
        , WeakCodeUpIntro (topMeta, WeakDataEpsilonIntro (LiteralLabel "unit")))
    _ -> return (m, WeakCodeTheta theta)
reduceWeakCodePlus (m, WeakCodeEpsilonElim (x, t) v branchList) =
  case v of
    (_, WeakDataEpsilonIntro l) ->
      case lookup (CaseLiteral l) branchList of
        Just body -> reduceWeakCodePlus $ substWeakCodePlus [(x, v)] body
        Nothing ->
          case lookup CaseDefault branchList of
            Just body -> reduceWeakCodePlus $ substWeakCodePlus [(x, v)] body
            Nothing   -> return (m, WeakCodeEpsilonElim (x, t) v branchList)
    _ -> return (m, WeakCodeEpsilonElim (x, t) v branchList)
reduceWeakCodePlus (m, WeakCodePiElim e vs) = do
  e' <- reduceWeakCodePlus e
  case e' of
    (_, WeakCodePiIntro xts body)
      | length xts == length vs -> do
        let xs = map fst xts
        reduceWeakCodePlus $ substWeakCodePlus (zip xs vs) body
    self@(m', WeakCodeMu (x, t) body) -> do
      let meta = WeakDataMetaNonTerminal t (obtainLocation m')
      let x' = (meta, WeakDataDownIntro self)
      let self' = substWeakCodePlus [(x, x')] body
      reduceWeakCodePlus (m, WeakCodePiElim self' vs)
    _ -> return (m, WeakCodePiElim e' vs)
reduceWeakCodePlus (m, WeakCodeSigmaElim xts v e) =
  case v of
    (_, WeakDataSigmaIntro es)
      | length es == length xts -> do
        let xs = map fst xts
        reduceWeakCodePlus $ substWeakCodePlus (zip xs es) e
    _ -> return (m, WeakCodeSigmaElim xts v e)
reduceWeakCodePlus (m, WeakCodeUpElim (x, t) e1 e2) = do
  e1' <- reduceWeakCodePlus e1
  case e1' of
    (_, WeakCodeUpIntro v) -> reduceWeakCodePlus $ substWeakCodePlus [(x, v)] e2
    _ -> return (m, WeakCodeUpElim (x, t) e1' e2)
reduceWeakCodePlus (m, WeakCodeDownElim v) =
  case v of
    (_, WeakDataDownIntro e) -> reduceWeakCodePlus e
    _                        -> return (m, WeakCodeDownElim v)
reduceWeakCodePlus t = return t

obtainLocation :: WeakCodeMeta -> Maybe (Int, Int)
obtainLocation (WeakCodeMetaTerminal ml)      = ml
obtainLocation (WeakCodeMetaNonTerminal _ ml) = ml
