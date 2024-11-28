module Scene.Parse.Program
  ( parseProgram,
    parseImport,
  )
where

import Context.Throw qualified as Throw
import Control.Monad
import Control.Monad.Trans
import Data.Maybe
import Data.Set qualified as S
import Data.Text qualified as T
import Entity.BaseName qualified as BN
import Entity.C
import Entity.ExternalName qualified as EN
import Entity.ForeignCodType qualified as F
import Entity.Hint
import Entity.LocalLocator qualified as LL
import Entity.Name
import Entity.Opacity qualified as O
import Entity.RawBinder
import Entity.RawProgram
import Entity.RawTerm qualified as RT
import Entity.StmtKind qualified as SK
import Entity.Syntax.Series qualified as SE
import Scene.Parse.Core (asLabel)
import Scene.Parse.Core qualified as P
import Scene.Parse.RawTerm
import Text.Megaparsec

parseProgram :: P.Parser RawProgram
parseProgram = do
  m <- P.getCurrentHint
  importList <- parseImport
  stmtList <- many parseStmt
  return $ RawProgram m importList stmtList

parseImport :: P.Parser [(RawImport, C)]
parseImport =
  many parseSingleImport

parseSingleImport :: P.Parser (RawImport, C)
parseSingleImport = do
  c1 <- P.keyword "import"
  m <- P.getCurrentHint
  (importItems, loc, c) <- P.seriesBrace' $ do
    mImportItem <- P.getCurrentHint
    locator <- P.symbol
    case fst locator of
      "static" -> do
        (ks, c) <- parseStaticKeyList
        return (RawStaticKey m c1 ks, c)
      _ -> do
        (lls, c) <- parseLocalLocatorList'
        return (RawImportItem mImportItem locator lls, c)
  return (RawImport c1 m importItems loc, c)

parseStmt :: P.Parser (RawStmt, C)
parseStmt = do
  choice
    [ parseDefine,
      parseData,
      parseInline,
      parseConstant,
      parseNominal,
      parseResource,
      parseForeign
    ]

parseLocalLocatorList' :: P.Parser (SE.Series (Hint, LL.LocalLocator), C)
parseLocalLocatorList' = do
  choice
    [ P.seriesBrace parseLocalLocator,
      return (SE.emptySeries (Just SE.Brace) SE.Comma, [])
    ]

parseStaticKeyList :: P.Parser (SE.Series (Hint, T.Text), C)
parseStaticKeyList = do
  choice
    [ P.seriesBrace $ do
        m <- P.getCurrentHint
        (k, c) <- P.symbol
        return ((m, k), c),
      return (SE.emptySeries (Just SE.Brace) SE.Comma, [])
    ]

parseLocalLocator :: P.Parser ((Hint, LL.LocalLocator), C)
parseLocalLocator = do
  m <- P.getCurrentHint
  (ll, c) <- P.baseName
  return ((m, LL.new ll), c)

parseForeign :: P.Parser (RawStmt, C)
parseForeign = do
  c1 <- P.keyword "foreign"
  (val, c) <- P.seriesBrace parseForeignItem
  return (RawStmtForeign c1 val, c)

parseForeignItem :: P.Parser (RawForeignItem, C)
parseForeignItem = do
  m <- P.getCurrentHint
  (funcName, c1) <- P.symbol
  (domList, c2) <- P.seriesParen rawTerm
  c3 <- P.delimiter ":"
  (cod, c) <-
    choice
      [ do
          c <- P.keyword "void"
          return (F.Void, c),
        do
          (lt, c) <- rawTerm
          return (F.Cod lt, c)
      ]
  return (RawForeignItemF m (EN.ExternalName funcName) c1 domList c2 c3 cod, c)

parseDefine :: P.Parser (RawStmt, C)
parseDefine =
  parseDefine' O.Opaque

parseInline :: P.Parser (RawStmt, C)
parseInline =
  parseDefine' O.Clear

parseDefine' :: O.Opacity -> P.Parser (RawStmt, C)
parseDefine' opacity = do
  c1 <-
    case opacity of
      O.Opaque ->
        P.keyword "define"
      O.Clear ->
        P.keyword "inline"
  (def, c) <- parseDef P.baseName
  return (RawStmtDefine c1 (SK.Normal opacity) def, c)

parseData :: P.Parser (RawStmt, C)
parseData = do
  c1 <- P.keyword "data"
  m <- P.getCurrentHint
  (dataName, c2) <- P.baseName
  dataArgsOrNone <- parseDataArgs
  (consSeries, loc, c) <- P.seriesBraceList' parseDefineDataClause
  return (RawStmtDefineData c1 m (dataName, c2) dataArgsOrNone consSeries loc, c)

parseNominal :: P.Parser (RawStmt, C)
parseNominal = do
  c1 <- P.keyword "nominal"
  m <- P.getCurrentHint
  (geists, c) <- P.seriesBrace $ do
    (geist, c) <- parseGeist P.baseName
    loc <- P.getCurrentLoc
    return ((geist, loc), c)
  return (RawStmtNominal c1 m geists, c)

parseDataArgs :: P.Parser (Maybe (RT.Args RT.RawTerm))
parseDataArgs = do
  choice
    [ Just <$> try (P.seriesParen preBinder),
      return Nothing
    ]

parseDefineDataClause :: P.Parser (RawConsInfo BN.BaseName, C)
parseDefineDataClause = do
  m <- P.getCurrentHint
  consName@(consName', _) <- P.baseName
  unless (isConsName (BN.reify consName')) $ do
    lift $ Throw.raiseError m "The name of a constructor must be capitalized"
  (consArgsOrNone, loc, c) <- parseConsArgs
  let consArgs = fromMaybe SE.emptySeriesPC consArgsOrNone
  let isConstLike = isNothing consArgsOrNone
  return ((m, consName, isConstLike, consArgs, loc), c)

parseConsArgs :: P.Parser (Maybe (SE.Series (RawBinder RT.RawTerm)), Loc, C)
parseConsArgs = do
  choice
    [ do
        (series, loc, c) <- P.seriesParen' parseDefineDataClauseArg
        return (Just series, loc, c),
      do
        loc <- P.getCurrentLoc
        return (Nothing, loc, [])
    ]

parseDefineDataClauseArg :: P.Parser (RawBinder RT.RawTerm, C)
parseDefineDataClauseArg = do
  choice
    [ try $ var >>= preAscription,
      typeWithoutIdent
    ]

parseResource :: P.Parser (RawStmt, C)
parseResource = do
  c1 <- P.keyword "resource"
  m <- P.getCurrentHint
  (name, c2) <- P.baseName
  (handlers, c) <- P.seriesBrace rawExpr
  case SE.elems handlers of
    [discarder, copier] -> do
      return (RawStmtDefineResource c1 m (name, c2) discarder copier (SE.trailingComment handlers), c)
    _ ->
      failure Nothing (S.fromList [asLabel "discarder and copier"])

parseConstant :: P.Parser (RawStmt, C)
parseConstant = do
  c1 <- P.keyword "constant"
  m <- P.getCurrentHint
  (constName, c2) <- P.baseName
  impArgs <- parseImplicitArgs
  t <- parseDefInfoCod m
  (c3, (v, c4)) <- P.betweenBrace rawExpr
  endLoc <- P.getCurrentLoc
  return (RawStmtDefineConst c1 m (constName, c2) impArgs t (c3, v) endLoc, c4)
