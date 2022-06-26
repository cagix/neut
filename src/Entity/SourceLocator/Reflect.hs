module Entity.SourceLocator.Reflect (fromText) where

import Data.List
import qualified Data.Text as T
import Entity.Hint
import Entity.Log
import Entity.Module
import Entity.Module.Locator
import Entity.ModuleAlias
import Entity.SourceLocator

fromText :: Hint -> Module -> T.Text -> IO SourceLocator
fromText m currentModule sectionString = do
  case getHeadMiddleLast $ T.splitOn "." sectionString of
    Just (nextModuleName, dirNameList, fileName) -> do
      nextModule <- getNextModule m currentModule $ ModuleAlias nextModuleName
      return $
        SourceLocator
          { sourceLocatorModule = nextModule,
            sourceLocatorDirNameList = map (DirName . T.unpack) dirNameList,
            sourceLocatorFileName = FileName . T.unpack $ fileName
          }
    Nothing ->
      raiseError m "found a malformed module signature"

getHeadMiddleLast :: [a] -> Maybe (a, [a], a)
getHeadMiddleLast xs = do
  (y, ys) <- uncons xs
  (zs, z) <- unsnoc ys
  return (y, zs, z)

unsnoc :: [a] -> Maybe ([a], a)
unsnoc =
  foldr go Nothing
  where
    go x acc =
      case acc of
        Nothing ->
          Just ([], x)
        Just (ys, y) ->
          Just (x : ys, y)
