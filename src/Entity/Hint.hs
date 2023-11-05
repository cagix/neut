module Entity.Hint where

import Data.Binary
import GHC.Generics

data Hint = Hint
  { metaFileName :: FilePath,
    metaLocation :: Loc
  }
  deriving (Generic)

type Line =
  Int

type Column =
  Int

type Loc =
  (Line, Column)

instance Binary Hint where
  put _ = put ()
  get = return internalHint

instance Show Hint where
  show _ =
    "_"

instance Ord Hint where
  _ `compare` _ = EQ

instance Eq Hint where
  _ == _ = True

newtype SavedHint = SavedHint Hint deriving (Generic)

instance Show SavedHint where
  show (SavedHint m) = show m

instance Binary SavedHint where
  put (SavedHint val) = do
    put $ metaFileName val
    put $ metaLocation val
  get = do
    SavedHint <$> (Hint <$> get <*> get)

new :: Int -> Int -> FilePath -> Hint
new l c path =
  Hint
    { metaFileName = path,
      metaLocation = (l, c)
    }

internalHint :: Hint
internalHint =
  Hint
    { metaFileName = "",
      metaLocation = (0, 0)
    }
