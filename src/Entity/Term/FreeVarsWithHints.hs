module Entity.Term.FreeVarsWithHints (freeVarsWithHints) where

import Control.Comonad.Cofree
import Data.Maybe
import Data.Set qualified as S
import Entity.Attr.Lam qualified as AttrL
import Entity.Binder
import Entity.DecisionTree qualified as DT
import Entity.Hint
import Entity.Ident
import Entity.Prim qualified as P
import Entity.PrimValue qualified as PV
import Entity.Term qualified as TM

freeVarsWithHints :: TM.Term -> S.Set (Hint, Ident)
freeVarsWithHints term =
  case term of
    _ :< TM.Tau ->
      S.empty
    m :< TM.Var x ->
      S.singleton (m, x)
    _ :< TM.VarGlobal {} ->
      S.empty
    _ :< TM.Pi impArgs expArgs t ->
      freeVarsWithHints' (impArgs ++ expArgs) (freeVarsWithHints t)
    _ :< TM.PiIntro k impArgs expArgs e ->
      freeVarsWithHints' (impArgs ++ expArgs ++ catMaybes [AttrL.fromAttr k]) (freeVarsWithHints e)
    _ :< TM.PiElim e es -> do
      let xs = freeVarsWithHints e
      let ys = S.unions $ map freeVarsWithHints es
      S.union xs ys
    _ :< TM.Data _ _ es ->
      S.unions $ map freeVarsWithHints es
    _ :< TM.DataIntro _ _ dataArgs consArgs -> do
      S.unions $ map freeVarsWithHints $ dataArgs ++ consArgs
    m :< TM.DataElim _ oets decisionTree -> do
      let (os, es, ts) = unzip3 oets
      let xs1 = S.unions $ map freeVarsWithHints es
      let binder = zipWith (\o t -> (m, o, t)) os ts
      let xs2 = freeVarsWithHints' binder (freeVarsWithHintsDecisionTree decisionTree)
      S.union xs1 xs2
    _ :< TM.Box t ->
      freeVarsWithHints t
    _ :< TM.BoxNoema t ->
      freeVarsWithHints t
    _ :< TM.BoxIntro letSeq e -> do
      let (xts, es) = unzip letSeq
      freeVarsWithHints' xts (S.unions $ map freeVarsWithHints (e : es))
    _ :< TM.BoxElim castSeq mxt e1 uncastSeq e2 -> do
      let (xts, es) = unzip $ castSeq ++ [(mxt, e1)] ++ uncastSeq
      freeVarsWithHints' xts (S.unions $ map freeVarsWithHints $ es ++ [e2])
    _ :< TM.Let _ mxt e1 e2 -> do
      let set1 = freeVarsWithHints e1
      let set2 = freeVarsWithHints' [mxt] (freeVarsWithHints e2)
      S.union set1 set2
    _ :< TM.Prim prim ->
      case prim of
        P.Value (PV.StaticText t _) ->
          freeVarsWithHints t
        _ ->
          S.empty
    _ :< TM.Magic der ->
      foldMap freeVarsWithHints der
    _ :< TM.Resource _ _ discarder copier -> do
      let xs1 = freeVarsWithHints discarder
      let xs2 = freeVarsWithHints copier
      S.union xs1 xs2
    _ :< TM.Void ->
      S.empty

freeVarsWithHints' :: [BinderF TM.Term] -> S.Set (Hint, Ident) -> S.Set (Hint, Ident)
freeVarsWithHints' binder zs =
  case binder of
    [] ->
      zs
    ((_, x, t) : xts) -> do
      let hs1 = freeVarsWithHints t
      let hs2 = freeVarsWithHints' xts zs
      S.union hs1 $ S.filter (\(_, y) -> y /= x) hs2

freeVarsWithHintsDecisionTree :: DT.DecisionTree TM.Term -> S.Set (Hint, Ident)
freeVarsWithHintsDecisionTree tree =
  case tree of
    DT.Leaf _ letSeq e ->
      freeVarsWithHints (TM.fromLetSeq letSeq e)
    DT.Unreachable ->
      S.empty
    DT.Switch (_, cursor) caseList ->
      S.union (freeVarsWithHints cursor) (freeVarsWithHintsCaseList caseList)

freeVarsWithHintsCaseList :: DT.CaseList TM.Term -> S.Set (Hint, Ident)
freeVarsWithHintsCaseList (fallbackClause, clauseList) = do
  let xs1 = freeVarsWithHintsDecisionTree fallbackClause
  let xs2 = S.unions $ map freeVarsWithHintsCase clauseList
  S.union xs1 xs2

freeVarsWithHintsCase :: DT.Case TM.Term -> S.Set (Hint, Ident)
freeVarsWithHintsCase decisionCase = do
  case decisionCase of
    DT.LiteralCase _ _ cont -> do
      freeVarsWithHintsDecisionTree cont
    DT.ConsCase {..} -> do
      let (dataTerms, dataTypes) = unzip dataArgs
      S.unions $ freeVarsWithHints' consArgs (freeVarsWithHintsDecisionTree cont) : map freeVarsWithHints dataTerms ++ map freeVarsWithHints dataTypes
