module Entity.Stmt where

import Control.Comonad.Cofree
import Data.Binary
import qualified Data.Set as S
import Entity.Binder
import qualified Entity.DefiniteDescription as DD
import Entity.EnumInfo
import Entity.Hint
import qualified Entity.ImpArgNum as I
import Entity.Opacity
import qualified Entity.PreTerm as PT
import qualified Entity.Section as Section
import qualified Entity.Source as Source
import Entity.Term
import Entity.WeakTerm
import GHC.Generics
import Path

type PreProgram =
  (Path Abs File, [PreStmt])

data PreStmt
  = PreStmtDefine Opacity Hint DD.DefiniteDescription I.ImpArgNum [BinderF PT.PreTerm] PT.PreTerm PT.PreTerm
  | PreStmtDefineResource Hint DD.DefiniteDescription PT.PreTerm PT.PreTerm
  | PreStmtSection Section.Section [PreStmt]

data WeakStmt
  = WeakStmtDefine Opacity Hint DD.DefiniteDescription I.ImpArgNum [BinderF WeakTerm] WeakTerm WeakTerm
  | WeakStmtDefineResource Hint DD.DefiniteDescription WeakTerm WeakTerm

type Program =
  (Source.Source, [Stmt])

data Stmt
  = StmtDefine Opacity Hint DD.DefiniteDescription I.ImpArgNum [BinderF Term] Term Term
  | StmtDefineResource Hint DD.DefiniteDescription Term Term
  deriving (Generic)

instance Binary Stmt

type PathSet = S.Set (Path Abs File)

data Cache = Cache
  { cacheStmtList :: [Stmt],
    cacheEnumInfo :: [EnumInfo]
  }
  deriving (Generic)

instance Binary Cache

compress :: Stmt -> Stmt
compress stmt =
  case stmt of
    StmtDefine opacity m functionName impArgNum args codType _ ->
      case opacity of
        OpacityOpaque ->
          StmtDefine opacity m functionName impArgNum args codType (m :< TermTau)
        _ ->
          stmt
    StmtDefineResource {} ->
      stmt

-- saveCache :: Source.Context m => Program -> [EnumInfo] -> m ()
-- saveCache (source, stmtList) enumInfoList = do
--   cachePath <- Source.getSourceCachePath source
--   ensureDir $ parent cachePath
--   encodeFile (toFilePath cachePath) (stmtList, enumInfoList)

-- loadCache :: Source.Source -> PathSet -> IO (Maybe Cache)
-- loadCache source hasCacheSet = do
--   cachePath <- Source.getSourceCachePath source
--   hasCache <- doesFileExist cachePath
--   if not hasCache
--     then return Nothing
--     else do
--       if S.notMember (Source.sourceFilePath source) hasCacheSet
--         then return Nothing
--         else do
--           dataOrErr <- decodeFileOrFail (toFilePath cachePath)
--           case dataOrErr of
--             Left _ -> do
--               removeFile cachePath
--               return Nothing
--             Right content ->
--               return $ Just content
