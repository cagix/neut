module Entity.DecisionTree
  ( DecisionTree (..),
    CaseList,
    Case (..),
    getConstructors,
    isUnreachable,
    findCase,
    getCont,
  )
where

import Data.Binary
import Entity.Binder
import Entity.DefiniteDescription qualified as DD
import Entity.Discriminant qualified as D
import Entity.Hint
import Entity.Ident
import Entity.IsConstLike
import Entity.Literal qualified as L
import GHC.Generics (Generic)

data DecisionTree a
  = Leaf [Ident] [(BinderF a, a)] a
  | Unreachable
  | Switch (Ident, a) (CaseList a)
  deriving (Show, Generic)

type CaseList a = (DecisionTree a, [Case a])

data Case a
  = ConsCase
      { mCons :: Hint,
        consDD :: DD.DefiniteDescription,
        isConstLike :: IsConstLike,
        disc :: D.Discriminant,
        dataArgs :: [(a, a)],
        consArgs :: [BinderF a],
        cont :: DecisionTree a
      }
  | LiteralCase Hint L.Literal (DecisionTree a)
  deriving (Show, Generic)

instance (Binary a) => Binary (DecisionTree a)

instance (Binary a) => Binary (Case a)

getConstructors :: [Case a] -> [(DD.DefiniteDescription, IsConstLike)]
getConstructors clauseList = do
  map (\c -> (consDD c, isConstLike c)) clauseList

isUnreachable :: DecisionTree a -> Bool
isUnreachable tree =
  case tree of
    Unreachable ->
      True
    _ ->
      False

findCase :: D.Discriminant -> Case a -> Maybe ([(Ident, a)], DecisionTree a)
findCase consDisc decisionCase =
  if consDisc == disc decisionCase
    then return (map (\(_, x, t) -> (x, t)) (consArgs decisionCase), cont decisionCase)
    else Nothing

getCont :: Case a -> DecisionTree a
getCont c =
  case c of
    ConsCase {..} ->
      cont
    LiteralCase _ _ cont ->
      cont
