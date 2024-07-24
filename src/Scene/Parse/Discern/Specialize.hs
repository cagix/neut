module Scene.Parse.Discern.Specialize
  ( specialize,
    Specializer (..),
  )
where

import Context.App
import Context.Gensym qualified as Gensym
import Context.OptimizableData qualified as OptimizableData
import Context.Throw qualified as Throw
import Control.Comonad.Cofree
import Data.Vector qualified as V
import Entity.ArgNum qualified as AN
import Entity.Binder
import Entity.Ident
import Entity.Noema qualified as N
import Entity.OptimizableData qualified as OD
import Entity.Pattern
import Entity.WeakTerm qualified as WT
import Scene.Parse.Discern.Noema

-- `cursor` is the variable `x` in `match x, y, z with (...) end`.
specialize ::
  N.IsNoetic ->
  Ident ->
  Specializer ->
  PatternMatrix ([Ident], [(BinderF WT.WeakTerm, WT.WeakTerm)], WT.WeakTerm) ->
  App (PatternMatrix ([Ident], [(BinderF WT.WeakTerm, WT.WeakTerm)], WT.WeakTerm))
specialize isNoetic cursor cons mat = do
  mapMaybeRowM (specializeRow isNoetic cursor cons) mat

specializeRow ::
  N.IsNoetic ->
  Ident ->
  Specializer ->
  PatternRow ([Ident], [(BinderF WT.WeakTerm, WT.WeakTerm)], WT.WeakTerm) ->
  App (Maybe (PatternRow ([Ident], [(BinderF WT.WeakTerm, WT.WeakTerm)], WT.WeakTerm)))
specializeRow isNoetic cursor specializer (patternVector, (freedVars, baseSeq, body@(mBody :< _))) =
  case V.uncons patternVector of
    Nothing ->
      Throw.raiseCritical' "Specialization against the empty pattern matrix should not happen"
    Just ((m, WildcardVar), rest) -> do
      case specializer of
        LiteralSpecializer _ -> do
          return $ Just (rest, (freedVars, baseSeq, body))
        ConsSpecializer (ConsInfo {consArgNum}) -> do
          let wildcards = V.fromList $ replicate (AN.reify consArgNum) (m, WildcardVar)
          return $ Just (V.concat [wildcards, rest], (freedVars, baseSeq, body))
    Just ((_, Var x), rest) -> do
      case specializer of
        LiteralSpecializer _ -> do
          h <- Gensym.newHole mBody []
          adjustedCursor <- castToNoemaIfNecessary isNoetic (mBody :< WT.Var cursor)
          return $ Just (rest, (freedVars, ((mBody, x, h), adjustedCursor) : baseSeq, body))
        ConsSpecializer (ConsInfo {consArgNum}) -> do
          let wildcards = V.fromList $ replicate (AN.reify consArgNum) (mBody, WildcardVar)
          h <- Gensym.newHole mBody []
          adjustedCursor <- castToNoemaIfNecessary isNoetic (mBody :< WT.Var cursor)
          return $ Just (V.concat [wildcards, rest], (freedVars, ((mBody, x, h), adjustedCursor) : baseSeq, body))
    Just ((_, Cons (ConsInfo {..})), rest) -> do
      case specializer of
        LiteralSpecializer {} ->
          return Nothing
        ConsSpecializer (ConsInfo {consDD = dd}) -> do
          if dd == consDD
            then do
              od <- OptimizableData.lookup consDD
              case od of
                Just OD.Enum ->
                  return $ Just (V.concat [V.fromList args, rest], (freedVars, baseSeq, body))
                Just OD.Unary ->
                  return $ Just (V.concat [V.fromList args, rest], (freedVars, baseSeq, body))
                _ ->
                  return $ Just (V.concat [V.fromList args, rest], (cursor : freedVars, baseSeq, body))
            else return Nothing
    Just ((_, Literal l), rest) -> do
      case specializer of
        LiteralSpecializer l' ->
          if l == l'
            then return $ Just (rest, (freedVars, baseSeq, body))
            else return Nothing
        _ ->
          return Nothing
