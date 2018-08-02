module Polarize where

import           Control.Monad

import           Control.Comonad.Cofree

import           Data

polarize :: WeakTerm -> Either String Term
polarize (i :< WeakTermVar s) = return $ TermValue $ Value (i :< ValueVar s)
polarize (i :< WeakTermConst s) = return $ TermValue $ Value (i :< ValueConst s)
polarize (i :< WeakTermLam (s, _) e) = do
  mc <- polarize e
  case mc of
    TermComp (Comp c) -> return $ TermComp $ Comp (i :< CompLam s c)
    _                 -> Left $ "the polarity of " ++ show e ++ " is wrong"
polarize (i :< WeakTermApp e1 e2) = do
  mc <- polarize e1
  mv <- polarize e2
  case (mc, mv) of
    (TermComp (Comp c), TermValue v) ->
      return $ TermComp $ Comp (i :< CompApp c v)
    _ ->
      Left $ "the polarity of " ++ show e1 ++ " or " ++ show e2 ++ " is wrong"
polarize (i :< WeakTermRet e) = do
  mv <- polarize e
  case mv of
    TermValue v -> return $ TermComp $ Comp (i :< CompRet v)
    _           -> Left $ "the polarity of " ++ show e ++ " is wrong"
polarize (i :< WeakTermBind (s, _) e1 e2) = do
  mc1 <- polarize e1
  mc2 <- polarize e2
  case (mc1, mc2) of
    (TermComp (Comp c1), TermComp (Comp c2)) ->
      return $ TermComp $ Comp (i :< CompBind s c1 c2)
    _ ->
      Left $
      "foo the polarity of " ++ show e1 ++ " or " ++ show e2 ++ " is wrong"
polarize (i :< WeakTermThunk e) = do
  mc <- polarize e
  case mc of
    TermComp c -> return $ TermValue $ Value (i :< ValueThunk c)
    _          -> Left $ "the polarity of " ++ show e ++ " is wrong"
polarize (i :< WeakTermUnthunk e) = do
  mv <- polarize e
  case mv of
    TermValue v -> return $ TermComp $ Comp (i :< CompUnthunk v)
    _           -> Left $ "the polarity of " ++ show e ++ " is wrong"
polarize (i :< WeakTermMu (s, _) e) = do
  mc <- polarize e
  case mc of
    TermComp (Comp c) -> return $ TermComp $ Comp (i :< CompMu s c)
    _                 -> Left $ "the polarity of " ++ show e ++ " is wrong"
polarize (i :< WeakTermCase e ves) = do
  ves' <-
    forM ves $ \(v, e) -> do
      e' <- polarize e
      case e' of
        TermComp (Comp c) -> return (v, c)
        _ ->
          Left $ "the polarity of " ++ show v ++ " or " ++ show e ++ " is wrong"
  e' <- polarize e
  case e' of
    TermValue v -> return $ TermComp $ Comp (i :< CompCase v ves')
polarize (i :< WeakTermAsc e t) = polarize e
