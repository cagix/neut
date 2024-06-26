module Entity.RawImportSummary
  ( RawImportSummary,
    fromRawImport,
  )
where

import Data.Maybe (catMaybes)
import Data.Text qualified as T
import Entity.Hint
import Entity.LocalLocator qualified as LL
import Entity.RawProgram (RawImport (..), RawImportItem (..))
import Entity.Syntax.Series qualified as SE

type RawImportSummary = ([(T.Text, [T.Text])], Loc)

fromRawImport :: RawImport -> RawImportSummary
fromRawImport (RawImport _ _ itemSeries loc) =
  (catMaybes $ SE.extract $ fmap fromRawImportItem itemSeries, loc)

fromRawImportItem :: RawImportItem -> Maybe (T.Text, [T.Text])
fromRawImportItem rawImportItem = do
  case rawImportItem of
    RawImportItem _ (gl, _) llSeries -> do
      let llList = map (LL.reify . snd) $ SE.extract llSeries
      Just (gl, llList)
    RawStaticKey {} ->
      Nothing
