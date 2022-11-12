module Entity.Term.Weaken
  ( weaken,
    weakenBinder,
  )
where

import Control.Comonad.Cofree
import Entity.Hint
import Entity.Ident
import qualified Entity.LamKind as LK
import qualified Entity.Prim as P
import qualified Entity.PrimType as PT
import qualified Entity.PrimValue as PV
import qualified Entity.Term as TM
import Entity.Term.FromPrimNum
import qualified Entity.WeakPrim as WP
import qualified Entity.WeakPrimValue as WPV
import qualified Entity.WeakTerm as WT

weaken :: TM.Term -> WT.WeakTerm
weaken term =
  case term of
    m :< TM.Tau ->
      m :< WT.Tau
    m :< TM.Var x ->
      m :< WT.Var x
    m :< TM.VarGlobal g arity ->
      m :< WT.VarGlobal g arity
    m :< TM.Pi xts t ->
      m :< WT.Pi (map weakenBinder xts) (weaken t)
    m :< TM.PiIntro kind xts e -> do
      let kind' = weakenKind kind
      let xts' = map weakenBinder xts
      let e' = weaken e
      m :< WT.PiIntro kind' xts' e'
    m :< TM.PiElim e es -> do
      let e' = weaken e
      let es' = map weaken es
      m :< WT.PiElim e' es'
    m :< TM.Sigma xts ->
      m :< WT.Sigma (map weakenBinder xts)
    m :< TM.SigmaIntro es ->
      m :< WT.SigmaIntro (map weaken es)
    m :< TM.SigmaElim xts e1 e2 -> do
      m :< WT.SigmaElim (map weakenBinder xts) (weaken e1) (weaken e2)
    m :< TM.Let mxt e1 e2 ->
      m :< WT.Let (weakenBinder mxt) (weaken e1) (weaken e2)
    m :< TM.Prim prim ->
      m :< WT.Prim (weakenPrim m prim)
    m :< TM.Enum x ->
      m :< WT.Enum x
    m :< TM.EnumIntro label ->
      m :< WT.EnumIntro label
    m :< TM.EnumElim (e, t) branchList -> do
      let t' = weaken t
      let e' = weaken e
      let (caseList, es) = unzip branchList
      -- let caseList' = map (\(me, ec) -> (me, weakenEnumCase ec)) caseList
      let es' = map weaken es
      m :< WT.EnumElim (e', t') (zip caseList es')
    m :< TM.Magic der -> do
      m :< WT.Magic (fmap weaken der)
    m :< TM.Match (e, t) patList -> do
      let e' = weaken e
      let t' = weaken t
      let patList' = map (\((mp, p, arity, xts), body) -> ((mp, p, arity, map weakenBinder xts), weaken body)) patList
      m :< WT.Match (e', t') patList'

weakenBinder :: (Hint, Ident, TM.Term) -> (Hint, Ident, WT.WeakTerm)
weakenBinder (m, x, t) =
  (m, x, weaken t)

weakenKind :: LK.LamKindF TM.Term -> LK.LamKindF WT.WeakTerm
weakenKind kind =
  case kind of
    LK.Normal ->
      LK.Normal
    LK.Cons dataName consName consNumber dataType ->
      LK.Cons dataName consName consNumber (weaken dataType)
    LK.Fix xt ->
      LK.Fix (weakenBinder xt)

weakenPrim :: Hint -> P.Prim -> WP.WeakPrim WT.WeakTerm
weakenPrim m prim =
  case prim of
    P.Type t ->
      WP.Type t
    P.Value v ->
      WP.Value $
        case v of
          PV.Int size integer ->
            WPV.Int (weaken (fromPrimNum m (PT.Int size))) integer
          PV.Float size float ->
            WPV.Float (weaken (fromPrimNum m (PT.Float size))) float
          PV.Op op ->
            WPV.Op op
