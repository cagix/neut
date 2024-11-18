module Entity.RawProgram
  ( RawProgram (..),
    RawStmt (..),
    RawConsInfo,
    RawImport (..),
    RawImportItem (..),
    compareImportItem,
    isImportEmpty,
    mergeImportList,
    RawForeignItemF (..),
    RawForeignItem,
  )
where

import Data.Text qualified as T
import Entity.BaseName qualified as BN
import Entity.C
import Entity.ExternalName qualified as EN
import Entity.ForeignCodType qualified as F
import Entity.Hint
import Entity.IsConstLike
import Entity.LocalLocator qualified as LL
import Entity.RawBinder
import Entity.RawTerm qualified as RT
import Entity.StmtKind qualified as SK
import Entity.Syntax.Series qualified as SE

data RawProgram
  = RawProgram Hint [(RawImport, C)] [(RawStmt, C)]

data RawStmt
  = RawStmtDefine
      C
      (SK.RawStmtKind BN.BaseName)
      RT.TopDef
  | RawStmtDefineConst
      C
      Hint
      (BN.BaseName, C)
      (C, (RT.RawTerm, C))
      (C, (RT.RawTerm, C))
  | RawStmtDefineData
      C
      Hint
      (BN.BaseName, C)
      (Maybe (RT.Args RT.RawTerm))
      (SE.Series (RawConsInfo BN.BaseName))
      Loc
  | RawStmtDefineResource
      C
      Hint
      (BN.BaseName, C)
      (C, RT.RawTerm)
      (C, RT.RawTerm)
      C
  | RawStmtNominal C Hint (SE.Series (RT.TopGeist, Loc))
  | RawStmtForeign C (SE.Series RawForeignItem)

type RawConsInfo a =
  (Hint, (a, C), IsConstLike, SE.Series (RawBinder RT.RawTerm), Loc)

data RawImport
  = RawImport C Hint (SE.Series RawImportItem) Loc

data RawImportItem
  = RawImportItem Hint (T.Text, C) (SE.Series (Hint, LL.LocalLocator))
  | RawStaticKey Hint C (SE.Series (Hint, T.Text))

compareImportItem :: RawImportItem -> RawImportItem -> Ordering
compareImportItem item1 item2 = do
  case (item1, item2) of
    (RawImportItem _ locator1 _, RawImportItem _ locator2 _) ->
      compare locator1 locator2
    (RawImportItem {}, RawStaticKey {}) ->
      LT
    (RawStaticKey {}, RawImportItem {}) ->
      GT
    (RawStaticKey {}, RawStaticKey {}) ->
      EQ

data RawForeignItemF a
  = RawForeignItemF Hint EN.ExternalName C (SE.Series a) C C (F.ForeignCodType a)
  deriving (Functor, Foldable, Traversable)

type RawForeignItem =
  RawForeignItemF RT.RawTerm

-- data RawForeignItemF a
--   = RawForeignItemF Hint EN.ExternalName C (SE.Series RT.RawTerm) C C (F.ForeignCodType RT.RawTerm)

isImportEmpty :: RawImport -> Bool
isImportEmpty rawImport =
  case rawImport of
    RawImport [] _ series _
      | SE.isEmpty series ->
          True
    _ ->
      False

mergeImportList :: Hint -> [(RawImport, C)] -> (RawImport, C)
mergeImportList headHint importList =
  case importList of
    [] -> do
      let beginningOfFile = (1, 1)
      (RawImport [] headHint (SE.emptySeries (Just SE.Brace) SE.Comma) beginningOfFile, [])
    (RawImport c1 m importItems loc, c) : rest -> do
      let (RawImport c1' _ importItems' _, c') = mergeImportList headHint rest
      (RawImport (c1 ++ c1') m (SE.appendLeftBiased importItems importItems') loc, c ++ c')
