module Data.MetaTerm where

import Data.Basic
import qualified Data.HashMap.Lazy as Map
import qualified Data.IntMap as IntMap
import Data.Maybe (catMaybes)
import qualified Data.Text as T
import Data.Tree

-- untyped lambda calculus with AST values (node / leaf)
data MetaTerm
  = MetaTermVar Ident
  | MetaTermImpIntro (Maybe Ident) [Ident] (Maybe Ident) MetaTermPlus
  | MetaTermImpElim MetaTermPlus [MetaTermPlus]
  | MetaTermLeaf T.Text
  | MetaTermNode [MetaTermPlus]
  | MetaTermConst T.Text
  | MetaTermInteger Integer
  | MetaTermIf MetaTermPlus MetaTermPlus MetaTermPlus
  deriving (Show)

type MetaTermPlus =
  (Hint, MetaTerm)

type SubstMetaTerm =
  IntMap.IntMap MetaTermPlus

data Arg
  = ArgLeaf
  | ArgNode
  | ArgInt
  | ArgLam
  | ArgAny
  deriving (Ord, Eq, Show)

substMetaTerm :: SubstMetaTerm -> MetaTermPlus -> MetaTermPlus
substMetaTerm sub term =
  case term of
    (_, MetaTermVar x)
      | Just e <- IntMap.lookup (asInt x) sub ->
        e
      | otherwise ->
        term
    (m, MetaTermImpIntro mf xs mx e) -> do
      let sub' = foldr IntMap.delete sub (map asInt (catMaybes [mf] ++ xs ++ catMaybes [mx]))
      let e' = substMetaTerm sub' e
      (m, MetaTermImpIntro mf xs mx e')
    (m, MetaTermImpElim e es) -> do
      let e' = substMetaTerm sub e
      let es' = map (substMetaTerm sub) es
      (m, MetaTermImpElim e' es')
    (_, MetaTermLeaf _) ->
      term
    (m, MetaTermNode es) -> do
      let es' = map (substMetaTerm sub) es
      (m, MetaTermNode es')
    (_, MetaTermConst _) ->
      term
    (_, MetaTermInteger _) ->
      term
    (m, MetaTermIf cond onTrue onFalse) -> do
      let cond' = substMetaTerm sub cond
      let onTrue' = substMetaTerm sub onTrue
      let onFalse' = substMetaTerm sub onFalse
      (m, MetaTermIf cond' onTrue' onFalse')

showMetaTerm :: MetaTermPlus -> T.Text
showMetaTerm e =
  showAsSExp (toTree e)

toTree :: MetaTermPlus -> TreePlus
toTree term =
  case term of
    (m, MetaTermVar x) ->
      (m, TreeLeaf $ asText x) -- ホントはmeta専用の名前にするべき
    (m, MetaTermImpIntro Nothing xs Nothing e) -> do
      let e' = toTree e
      let xs' = map (\i -> (m, TreeLeaf $ asText i)) xs
      (m, TreeNode [(m, TreeLeaf "lambda-meta"), (m, TreeNode xs'), e'])
    (m, MetaTermImpIntro Nothing xs (Just rest) e) -> do
      let e' = toTree e
      let args = map (\i -> (m, TreeLeaf $ asText i)) $ xs ++ [rest]
      (m, TreeNode [(m, TreeLeaf "lambda-meta-variadic"), (m, TreeNode args), e'])
    (m, MetaTermImpIntro (Just f) xs Nothing e) -> do
      let e' = toTree e
      let xs' = map (\i -> (m, TreeLeaf $ asText i)) xs
      (m, TreeNode [(m, TreeLeaf "fix-meta"), (m, TreeLeaf (asText f)), (m, TreeNode xs'), e'])
    (m, MetaTermImpIntro (Just f) xs (Just rest) e) -> do
      let e' = toTree e
      let args = map (\i -> (m, TreeLeaf $ asText i)) $ xs ++ [rest]
      (m, TreeNode [(m, TreeLeaf "fix-meta-variadic"), (m, TreeLeaf (asText f)), (m, TreeNode args), e'])
    (m, MetaTermImpElim e es) -> do
      let e' = toTree e
      let es' = map toTree es
      (m, TreeNode ((m, TreeLeaf "apply-meta") : e' : es'))
    (m, MetaTermLeaf x) ->
      (m, TreeLeaf x)
    (m, MetaTermNode es) -> do
      let es' = map toTree es
      (m, TreeNode es')
    (m, MetaTermConst c) ->
      (m, TreeLeaf c)
    (m, MetaTermInteger i) ->
      (m, TreeLeaf $ T.pack $ show i)
    (m, MetaTermIf cond onTrue onFalse) -> do
      let cond' = toTree cond
      let onTrue' = toTree onTrue
      let onFalse' = toTree onFalse
      (m, TreeNode [(m, TreeLeaf "if-meta"), cond', onTrue', onFalse'])

showArgForm :: Arg -> T.Text
showArgForm arg =
  case arg of
    ArgLeaf ->
      "leaf"
    ArgNode ->
      "node"
    ArgInt ->
      "int"
    ArgLam ->
      "lambda-term"
    ArgAny ->
      "(any)"

metaConstants :: Map.HashMap T.Text [Arg]
metaConstants =
  Map.unions [metaTreeConstants, metaArithConstants, metaCmpConstants]

-- some of the constants here can be definable in the meta-language of course,
-- but nevertheless defined in the compiler to achieve better performance
metaTreeConstants :: Map.HashMap T.Text [Arg]
metaTreeConstants =
  Map.fromList
    [ ("meta.dump", [ArgAny]),
      ("meta.size-of", [ArgAny]),
      ("meta.is-leaf", [ArgAny]),
      ("meta.is-nil", [ArgNode]),
      ("meta.is-node", [ArgAny]),
      ("meta.leaf.equal", [ArgLeaf, ArgLeaf]),
      ("meta.leaf.from-int", [ArgInt]),
      ("meta.leaf.mul", [ArgLeaf, ArgLeaf]),
      ("meta.leaf.new-symbol", [ArgLeaf]),
      ("meta.leaf.string-to-i8-list", [ArgLeaf]),
      ("meta.leaf.uncons", [ArgLeaf]),
      ("meta.node.cons", [ArgAny, ArgNode]),
      ("meta.node.head", [ArgNode]),
      ("meta.node.take", [ArgInt, ArgNode]),
      ("meta.node.take-while", [ArgLam, ArgNode]),
      ("meta.node.drop", [ArgInt, ArgNode]),
      ("meta.node.drop-while", [ArgLam, ArgNode]),
      ("meta.node.nth", [ArgInt, ArgNode]),
      ("meta.node.filter", [ArgLam, ArgNode]),
      ("meta.node.append", [ArgNode, ArgNode]),
      ("meta.node.return", [ArgAny]),
      ("meta.node.reverse", [ArgNode]),
      ("meta.node.replicate", [ArgInt, ArgAny]),
      ("meta.node.join", [ArgNode]),
      ("meta.node.init", [ArgNode]),
      ("meta.node.last", [ArgNode]),
      ("meta.node.length", [ArgNode]),
      ("meta.node.list", [ArgNode]),
      ("meta.node.map", [ArgLam, ArgNode]),
      ("meta.node.tail", [ArgNode]),
      ("meta.node.intersperse", [ArgAny, ArgNode])
    ]

metaArithConstants :: Map.HashMap T.Text [Arg]
metaArithConstants =
  Map.fromList
    [ ("meta.int.add", [ArgInt, ArgInt]),
      ("meta.int.sub", [ArgInt, ArgInt]),
      ("meta.int.mul", [ArgInt, ArgInt]),
      ("meta.int.div", [ArgInt, ArgInt])
    ]

metaCmpConstants :: Map.HashMap T.Text [Arg]
metaCmpConstants =
  Map.fromList
    [ ("meta.int.gt", [ArgInt, ArgInt]),
      ("meta.int.ge", [ArgInt, ArgInt]),
      ("meta.int.lt", [ArgInt, ArgInt]),
      ("meta.int.le", [ArgInt, ArgInt]),
      ("meta.int.eq", [ArgInt, ArgInt])
    ]
