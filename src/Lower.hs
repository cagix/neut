{-# LANGUAGE TupleSections #-}

module Lower
  ( lowerMain,
    lowerOther,
  )
where

import Control.Comonad.Cofree (Cofree (..))
import Control.Monad (forM_, unless, (>=>))
import Data.Basic (CompEnumCase, EnumCaseF (..), Ident (..), asText)
import Data.Comp (Comp (..), CompDef, Primitive (..), Value (..))
import Data.Global
  ( cartClsName,
    cartImmName,
    compDefEnvRef,
    initialLowDeclEnv,
    lowDeclEnvRef,
    lowDefEnvRef,
    lowNameSetRef,
    newCount,
    newIdentFromIdent,
    newIdentFromText,
    newValueVarLocalWith,
    revEnumEnvRef,
  )
import qualified Data.HashMap.Lazy as Map
import Data.IORef (modifyIORef', readIORef, writeIORef)
import Data.Log (raiseCritical')
import Data.LowComp
  ( LowComp (..),
    LowOp (..),
    LowValue (..),
    SizeInfo,
  )
import Data.LowType
  ( FloatSize (..),
    LowType (..),
    Magic (..),
    PrimNum (..),
    PrimOp (..),
    primNumToLowType,
    sizeAsInt,
    voidPtr,
  )
import qualified Data.Set as S
import qualified Data.Text as T

lowerMain :: ([CompDef], Comp) -> IO LowComp
lowerMain (defList, mainTerm) = do
  initialize $ cartImmName : cartClsName : map fst defList
  registerCartesian cartImmName
  registerCartesian cartClsName
  forM_ defList $ \(name, (_, args, e)) ->
    lowerComp e >>= insLowDefEnv name args
  mainTerm'' <- lowerComp mainTerm
  -- the result of "main" must be i64, not i8*
  (result, resultVar) <- newValueVarLocalWith "result"
  (cast, castThen) <- llvmCast (Just "cast") resultVar (LowTypeInt 64)
  castResult <- castThen (LowCompReturn cast)
  -- let result: i8* := (main-term) in {cast result to i64}
  commConv result mainTerm'' castResult

lowerOther :: [CompDef] -> IO ()
lowerOther defList = do
  initialize $ map fst defList
  insDeclEnv cartImmName [(), ()]
  insDeclEnv cartClsName [(), ()]
  lowDeclEnv <- readIORef lowDeclEnvRef
  forM_ defList $ \(name, (_, args, e)) ->
    unless (Map.member name lowDeclEnv) $
      lowerComp e >>= insLowDefEnv name args

initialize :: [T.Text] -> IO ()
initialize nameList = do
  writeIORef lowDeclEnvRef initialLowDeclEnv
  writeIORef lowDefEnvRef Map.empty
  writeIORef lowNameSetRef $ S.fromList nameList

lowerComp :: Comp -> IO LowComp
lowerComp term =
  case term of
    CompPrimitive theta ->
      lowerCompPrimitive theta
    CompPiElimDownElim v ds -> do
      (xs, vs) <- unzip <$> mapM (newValueLocal . takeBaseName) ds
      (fun, castThen) <- llvmCast (Just $ takeBaseName v) v $ toFunPtrType ds
      castThenCall <- castThen $ LowCompCall fun vs
      lowerValueLet' (zip xs ds) castThenCall
    CompSigmaElim isNoetic xs v e -> do
      let basePtrType = LowTypePointer $ LowTypeArray (length xs) voidPtr -- base pointer type  ([(length xs) x ARRAY_ELEM_TYPE])
      let idxList = map (\i -> (LowValueInt i, LowTypeInt 32)) [0 ..]
      ys <- mapM newIdentFromIdent xs
      let xts' = zip xs (repeat voidPtr)
      loadContent isNoetic v basePtrType (zip idxList (zip ys xts')) e
    CompUpIntro d -> do
      result <- newIdentFromText $ takeBaseName d
      lowerValueLet result d $ LowCompReturn $ LowValueVarLocal result
    CompUpElim x e1 e2 -> do
      e1' <- lowerComp e1
      e2' <- lowerComp e2
      commConv x e1' e2'
    CompEnumElim v branchList -> do
      m <- constructSwitch branchList
      case m of
        Nothing ->
          return LowCompUnreachable
        Just (defaultCase, caseList) -> do
          let t = LowTypeInt 64
          (cast, castThen) <- llvmCast (Just "enum-base") v t
          castThen $ LowCompSwitch (cast, t) defaultCase caseList
    CompArrayAccess elemType v index -> do
      -- v + 8 + size(elemType) * indexをload.
      let i64 = LowTypeInt 64
      (arrayOffset, arrayOffsetVar) <- newValueLocal $ takeBaseName index
      (realOffset, realOffsetVar) <- newValueLocal $ takeBaseName index
      (elemAddress, elemAddressVar) <- newValueLocal $ takeBaseName v
      (result, resultVar) <- newValueLocal $ takeBaseName v
      (indexVar, calculateIndexThen) <- llvmCast (Just $ takeBaseName v) index $ LowTypeInt 64
      (arrayVar, castArrayThen) <- llvmCast (Just $ takeBaseName v) v $ LowTypeInt 64
      (pointer, pointerVar) <- newValueLocal $ takeBaseName v
      (uncastedResult, uncastedResultVar) <- newValueLocal $ takeBaseName v
      let elemType' = primNumToLowType elemType
      castArrayThenLoad <-
        castArrayThen $
          LowCompLet
            elemAddress
            ( LowOpPrimOp
                (PrimOp "add" [i64, i64] i64)
                [arrayVar, realOffsetVar]
            )
            $ LowCompLet pointer (LowOpIntToPointer elemAddressVar i64 (LowTypePointer elemType')) $
              LowCompLet
                result
                (LowOpLoad pointerVar elemType')
                $ LowCompLet
                  uncastedResult
                  (LowOpIntToPointer resultVar elemType' voidPtr)
                  (LowCompReturn uncastedResultVar)
      calculateIndexThen $
        LowCompLet
          arrayOffset
          ( LowOpPrimOp
              (PrimOp "mul" [i64, i64] i64)
              [LowValueInt (primNumToSizeInByte elemType), indexVar]
          )
          $ LowCompLet
            realOffset
            ( LowOpPrimOp
                (PrimOp "add" [i64, i64] i64)
                [LowValueInt 8, arrayOffsetVar]
            )
            castArrayThenLoad

primNumToSizeInByte :: PrimNum -> Integer
primNumToSizeInByte primNum =
  case primNum of
    PrimNumInt size ->
      toInteger $ size `div` 8
    PrimNumFloat size ->
      toInteger $ sizeAsInt size `div` 8

uncastList :: [(Ident, (Ident, LowType))] -> Comp -> IO LowComp
uncastList args e =
  case args of
    [] ->
      lowerComp e
    ((y, (x, et)) : yxs) -> do
      e' <- uncastList yxs e
      llvmUncastLet x (LowValueVarLocal y) et e'

takeBaseName :: Value -> T.Text
takeBaseName term =
  case term of
    ValueVarGlobal s ->
      s
    ValueVarLocal (I (s, _)) ->
      s
    ValueVarLocalIdeal (I (s, _)) ->
      s
    ValueSigmaIntro ds ->
      "array" <> T.pack (show (length ds))
    ValueArrayIntro _ ds ->
      "array" <> T.pack (show (length ds))
    ValueInt size _ ->
      "i" <> T.pack (show size)
    ValueFloat FloatSize16 _ ->
      "half"
    ValueFloat FloatSize32 _ ->
      "float"
    ValueFloat FloatSize64 _ ->
      "double"
    ValueEnumIntro {} ->
      "i64"

takeBaseName' :: LowValue -> T.Text
takeBaseName' lowerValue =
  case lowerValue of
    LowValueVarLocal (I (s, _)) ->
      s
    LowValueVarGlobal s ->
      s
    LowValueInt _ ->
      "int"
    LowValueFloat FloatSize16 _ ->
      "half"
    LowValueFloat FloatSize32 _ ->
      "float"
    LowValueFloat FloatSize64 _ ->
      "double"
    LowValueNull ->
      "null"

loadContent ::
  Bool -> -- noetic-or-not
  Value -> -- base pointer
  LowType -> -- the type of base pointer
  [((LowValue, LowType), (Ident, (Ident, LowType)))] -> -- [(the index of an element, the variable to load the element)]
  Comp -> -- continuation
  IO LowComp
loadContent isNoetic v bt iyxs cont =
  case iyxs of
    [] ->
      lowerComp cont
    _ -> do
      let ixs = map (\(i, (y, (_, k))) -> (i, (y, k))) iyxs
      (bp, castThen) <- llvmCast (Just $ takeBaseName v) v bt
      let yxs = map snd iyxs
      uncastThenCont <- uncastList yxs cont
      extractThenFreeThenUncastThenCont <- loadContent' isNoetic bp bt ixs uncastThenCont
      castThen extractThenFreeThenUncastThenCont

loadContent' ::
  Bool -> -- noetic-or-not
  LowValue -> -- base pointer
  LowType -> -- the type of base pointer
  [((LowValue, LowType), (Ident, LowType))] -> -- [(the index of an element, the variable to keep the loaded content)]
  LowComp -> -- continuation
  IO LowComp
loadContent' isNoetic bp bt values cont =
  case values of
    []
      | isNoetic ->
        return cont
      | otherwise -> do
        l <- llvmUncast (Just $ takeBaseName' bp) bp bt
        tmp <- newNameWith $ Just $ takeBaseName' bp
        j <- newCount
        commConv tmp l $ LowCompCont (LowOpFree (LowValueVarLocal tmp) bt j) cont
    (i, (x, et)) : xis -> do
      cont' <- loadContent' isNoetic bp bt xis cont
      (posName, pos) <- newValueLocal' (Just $ asText x)
      return $
        LowCompLet
          posName
          (LowOpGetElementPtr (bp, bt) [(LowValueInt 0, LowTypeInt 32), i])
          $ LowCompLet x (LowOpLoad pos et) cont'

lowerCompPrimitive :: Primitive -> IO LowComp
lowerCompPrimitive codeOp =
  case codeOp of
    PrimitivePrimOp op vs ->
      lowerCompPrimOp op vs
    PrimitiveMagic der -> do
      case der of
        MagicCast _ _ value -> do
          (x, v) <- newValueLocal "cast-arg"
          lowerValueLet x value $ LowCompReturn v
        MagicStore valueLowType pointer value -> do
          (ptrVar, castPtrThen) <- llvmCast (Just $ takeBaseName pointer) pointer (LowTypePointer valueLowType)
          (valVar, castValThen) <- llvmCast (Just $ takeBaseName value) value valueLowType
          (castPtrThen >=> castValThen) $
            LowCompCont (LowOpStore valueLowType valVar ptrVar) $
              LowCompReturn LowValueNull
        MagicLoad valueLowType pointer -> do
          (ptrVar, castPtrThen) <- llvmCast (Just $ takeBaseName pointer) pointer (LowTypePointer valueLowType)
          resName <- newIdentFromText "result"
          uncast <- llvmUncast (Just $ asText resName) (LowValueVarLocal resName) valueLowType
          castPtrThen $
            LowCompLet resName (LowOpLoad ptrVar valueLowType) uncast
        MagicSyscall i args -> do
          (xs, vs) <- unzip <$> mapM (const $ newValueLocal "sys-call-arg") args
          res <- newIdentFromText "result"
          lowerValueLet' (zip xs args) $
            LowCompLet res (LowOpSyscall i vs) $
              LowCompReturn (LowValueVarLocal res)
        MagicExternal name args -> do
          (xs, vs) <- unzip <$> mapM (const $ newValueLocal "ext-call-arg") args
          insDeclEnv name vs
          lowerValueLet' (zip xs args) $ LowCompCall (LowValueVarGlobal name) vs
        MagicCreateArray elemType args -> do
          let arrayType = AggPtrTypeArray (length args) elemType
          let argTypeList = zip args (repeat elemType)
          resName <- newIdentFromText "result"
          storeContent resName arrayType argTypeList (LowCompReturn (LowValueVarLocal resName))

lowerCompPrimOp :: PrimOp -> [Value] -> IO LowComp
lowerCompPrimOp op@(PrimOp _ domList cod) vs = do
  (argVarList, castArgsThen) <- llvmCastPrimArgs $ zip vs domList
  result <- newIdentFromText "prim-op-result"
  uncast <- llvmUncast (Just $ asText result) (LowValueVarLocal result) cod
  castArgsThen $ LowCompLet result (LowOpPrimOp op argVarList) uncast

llvmCastPrimArgs :: [(Value, LowType)] -> IO ([LowValue], LowComp -> IO LowComp)
llvmCastPrimArgs dts =
  case dts of
    [] ->
      return ([], return)
    ((d, t) : rest) -> do
      (argVarList, cont) <- llvmCastPrimArgs rest
      (argVar, castThen) <- llvmCast (Just "prim-op") d t
      return (argVar : argVarList, castThen >=> cont)

llvmCast ::
  Maybe T.Text ->
  Value ->
  LowType ->
  IO (LowValue, LowComp -> IO LowComp)
llvmCast mName v lowType =
  case lowType of
    LowTypeInt _ ->
      llvmCastInt mName v lowType
    LowTypeFloat i ->
      llvmCastFloat mName v i
    _ -> do
      tmp <- newNameWith mName
      x <- newNameWith mName
      return
        ( LowValueVarLocal x,
          lowerValueLet tmp v
            . LowCompLet x (LowOpBitcast (LowValueVarLocal tmp) voidPtr lowType)
        )

llvmCastInt ::
  Maybe T.Text -> -- base name for newly created variables
  Value ->
  LowType ->
  IO (LowValue, LowComp -> IO LowComp)
llvmCastInt mName v lowType = do
  x <- newNameWith mName
  y <- newNameWith mName
  return
    ( LowValueVarLocal y,
      lowerValueLet x v
        . LowCompLet
          y
          (LowOpPointerToInt (LowValueVarLocal x) voidPtr lowType)
    )

llvmCastFloat ::
  Maybe T.Text -> -- base name for newly created variables
  Value ->
  FloatSize ->
  IO (LowValue, LowComp -> IO LowComp)
llvmCastFloat mName v size = do
  let floatType = LowTypeFloat size
  let intType = LowTypeInt $ sizeAsInt size
  (xName, x) <- newValueLocal' mName
  (yName, y) <- newValueLocal' mName
  z <- newNameWith mName
  return
    ( LowValueVarLocal z,
      lowerValueLet xName v
        . LowCompLet yName (LowOpPointerToInt x voidPtr intType)
        . LowCompLet z (LowOpBitcast y intType floatType)
    )

-- uncast: {some-concrete-type} -> voidPtr
llvmUncast :: Maybe T.Text -> LowValue -> LowType -> IO LowComp
llvmUncast mName result lowType =
  case lowType of
    LowTypeInt _ ->
      llvmUncastInt mName result lowType
    LowTypeFloat i ->
      llvmUncastFloat mName result i
    _ -> do
      x <- newNameWith mName
      return $
        LowCompLet x (LowOpBitcast result lowType voidPtr) $
          LowCompReturn (LowValueVarLocal x)

llvmUncastInt :: Maybe T.Text -> LowValue -> LowType -> IO LowComp
llvmUncastInt mName result lowType = do
  x <- newNameWith mName
  return $
    LowCompLet x (LowOpIntToPointer result lowType voidPtr) $
      LowCompReturn (LowValueVarLocal x)

llvmUncastFloat :: Maybe T.Text -> LowValue -> FloatSize -> IO LowComp
llvmUncastFloat mName floatResult i = do
  let floatType = LowTypeFloat i
  let intType = LowTypeInt $ sizeAsInt i
  tmp <- newNameWith mName
  x <- newNameWith mName
  return $
    LowCompLet tmp (LowOpBitcast floatResult floatType intType) $
      LowCompLet x (LowOpIntToPointer (LowValueVarLocal tmp) intType voidPtr) $
        LowCompReturn (LowValueVarLocal x)

llvmUncastLet :: Ident -> LowValue -> LowType -> LowComp -> IO LowComp
llvmUncastLet x@(I (s, _)) d lowType cont = do
  l <- llvmUncast (Just s) d lowType
  commConv x l cont

-- `lowerValueLet x d cont` binds the data `d` to the variable `x`, and computes the
-- continuation `cont`.
lowerValueLet :: Ident -> Value -> LowComp -> IO LowComp
lowerValueLet x lowerValue cont =
  case lowerValue of
    ValueVarGlobal y -> do
      compDefEnv <- readIORef compDefEnvRef
      case Map.lookup y compDefEnv of
        Nothing ->
          raiseCritical' $ "no such global variable is defined: " <> y
        Just (_, args, _) -> do
          insDeclEnvIfNecessary y args
          llvmUncastLet x (LowValueVarGlobal y) (toFunPtrType args) cont
    ValueVarLocal y ->
      llvmUncastLet x (LowValueVarLocal y) voidPtr cont
    ValueVarLocalIdeal y ->
      llvmUncastLet x (LowValueVarLocal y) voidPtr cont
    ValueSigmaIntro ds -> do
      let arrayType = AggPtrTypeArray (length ds) voidPtr
      let dts = zip ds (repeat voidPtr)
      storeContent x arrayType dts cont
    ValueInt size l ->
      llvmUncastLet x (LowValueInt l) (LowTypeInt size) cont
    ValueFloat size f ->
      llvmUncastLet x (LowValueFloat size f) (LowTypeFloat size) cont
    ValueEnumIntro l -> do
      i <- toInteger <$> enumValueToInteger l
      llvmUncastLet x (LowValueInt i) (LowTypeInt 64) cont
    ValueArrayIntro elemType vs -> do
      let i64 = LowTypeInt 64
      (arrayLength, arrayLengthVar) <- newValueLocal "array"
      (realLength, realLengthVar) <- newValueLocal "array"
      (castedRealLength, castedRealLengthVar) <- newValueLocal "array"
      (pointer, pointerVar) <- newValueLocal "array"
      let elemType' = primNumToLowType elemType
      let pointerType = LowTypePointer $ LowTypeStruct [i64, LowTypeArray (length vs) elemType']
      (castedPointer, castedPointerVar) <- newValueLocal "array"
      (lenInfo, lenInfoVar) <- newValueLocal "array"
      (array, arrayVar) <- newValueLocal "array"
      let lenValue = LowValueInt (toInteger $ length vs)
      let elemInfoList = zip [0 ..] $ map (,elemType') vs
      let arrayType = LowTypePointer $ LowTypeArray (length vs) elemType'
      storeThenReturn <- storeContent' arrayVar arrayType elemInfoList $ LowCompReturn (LowValueVarLocal pointer)
      return $
        LowCompLet
          arrayLength
          ( LowOpPrimOp
              (PrimOp "mul" [i64, i64] i64)
              [LowValueInt (primNumToSizeInByte elemType), lenValue]
          )
          $ LowCompLet
            realLength
            ( LowOpPrimOp
                (PrimOp "add" [i64, i64] i64)
                [LowValueInt 8, arrayLengthVar]
            )
            $ LowCompLet
              castedRealLength
              (LowOpIntToPointer realLengthVar i64 voidPtr)
              $ LowCompLet
                pointer
                (LowOpCall (LowValueVarGlobal "malloc") [castedRealLengthVar])
                $ LowCompLet
                  castedPointer
                  (LowOpBitcast pointerVar voidPtr pointerType)
                  $ LowCompLet
                    lenInfo
                    ( LowOpGetElementPtr
                        (castedPointerVar, pointerType)
                        [ (LowValueInt 0, LowTypeInt 32),
                          (LowValueInt 0, LowTypeInt 32)
                        ]
                    )
                    $ LowCompCont
                      (LowOpStore i64 lenValue lenInfoVar)
                      $ LowCompLet
                        array
                        ( LowOpGetElementPtr
                            (castedPointerVar, pointerType)
                            [ (LowValueInt 0, LowTypeInt 32),
                              (LowValueInt 1, LowTypeInt 32)
                            ]
                        )
                        storeThenReturn

insDeclEnvIfNecessary :: T.Text -> [a] -> IO ()
insDeclEnvIfNecessary symbol args = do
  lowNameSet <- readIORef lowNameSetRef
  if S.member symbol lowNameSet
    then return ()
    else insDeclEnv symbol args

lowerValueLet' :: [(Ident, Value)] -> LowComp -> IO LowComp
lowerValueLet' binder cont =
  case binder of
    [] ->
      return cont
    (x, d) : rest -> do
      cont' <- lowerValueLet' rest cont
      lowerValueLet x d cont'

-- returns Nothing iff the branch list is empty
constructSwitch :: [(CompEnumCase, Comp)] -> IO (Maybe (LowComp, [(Int, LowComp)]))
constructSwitch switch =
  case switch of
    [] ->
      return Nothing
    (_ :< EnumCaseDefault, code) : _ -> do
      code' <- lowerComp code
      return $ Just (code', [])
    [(m :< _, code)] -> do
      constructSwitch [(m :< EnumCaseDefault, code)]
    (m :< EnumCaseLabel l, code) : rest -> do
      i <- enumValueToInteger l
      constructSwitch $ (m :< EnumCaseInt i, code) : rest
    (_ :< EnumCaseInt i, code) : rest -> do
      code' <- lowerComp code
      mSwitch <- constructSwitch rest
      return $ do
        (defaultCase, caseList) <- mSwitch
        return (defaultCase, (i, code') : caseList)

data AggPtrType
  = AggPtrTypeArray Int LowType
  | AggPtrTypeStruct [LowType]

toLowType :: AggPtrType -> LowType
toLowType aggPtrType =
  case aggPtrType of
    AggPtrTypeArray i t ->
      LowTypePointer $ LowTypeArray i t
    AggPtrTypeStruct ts ->
      LowTypePointer $ LowTypeStruct ts

storeContent ::
  Ident ->
  AggPtrType ->
  [(Value, LowType)] ->
  LowComp ->
  IO LowComp
storeContent reg aggPtrType dts cont = do
  let lowType = toLowType aggPtrType
  (cast, castThen) <- llvmCast (Just $ asText reg) (ValueVarLocal reg) lowType
  storeThenCont <- storeContent' cast lowType (zip [0 ..] dts) cont
  castThenStoreThenCont <- castThen storeThenCont
  case aggPtrType of
    AggPtrTypeStruct ts ->
      storeContent'' reg (LowTypeStruct ts) lowType 1 castThenStoreThenCont
    AggPtrTypeArray len t ->
      storeContent'' reg t lowType len castThenStoreThenCont

storeContent' ::
  LowValue -> -- base pointer
  LowType -> -- the type of base pointer (like [n x u8]*, {i8*, i8*}*, etc.)
  [(Integer, (Value, LowType))] -> -- [(the index of an element, the element to be stored)]
  LowComp -> -- continuation
  IO LowComp
storeContent' bp bt values cont =
  case values of
    [] ->
      return cont
    (i, (d, et)) : ids -> do
      cont' <- storeContent' bp bt ids cont
      (locName, loc) <- newValueLocal $ takeBaseName d <> "-location"
      (cast, castThen) <- llvmCast (Just $ takeBaseName d) d et
      let it = indexTypeOf bt
      castThen $
        LowCompLet
          locName
          (LowOpGetElementPtr (bp, bt) [(LowValueInt 0, LowTypeInt 32), (LowValueInt i, it)])
          $ LowCompCont (LowOpStore et cast loc) cont'

storeContent'' :: Ident -> LowType -> SizeInfo -> Int -> LowComp -> IO LowComp
storeContent'' reg elemType sizeInfo len cont = do
  (tmp, tmpVar) <- newValueLocal $ "sizeof-" <> asText reg
  (c, cVar) <- newValueLocal $ "sizeof-" <> asText reg
  uncastThenAllocThenCont <- llvmUncastLet c tmpVar (LowTypePointer elemType) (LowCompLet reg (LowOpAlloc cVar sizeInfo) cont)
  return $
    LowCompLet
      tmp
      ( LowOpGetElementPtr
          (LowValueNull, LowTypePointer elemType)
          [(LowValueInt (toInteger len), LowTypeInt 64)]
      )
      uncastThenAllocThenCont

indexTypeOf :: LowType -> LowType
indexTypeOf lowType =
  case lowType of
    LowTypePointer (LowTypeStruct _) ->
      LowTypeInt 32
    _ ->
      LowTypeInt 64

toFunPtrType :: [a] -> LowType
toFunPtrType xs =
  LowTypePointer (LowTypeFunction (map (const voidPtr) xs) voidPtr)

newValueLocal :: T.Text -> IO (Ident, LowValue)
newValueLocal name = do
  x <- newIdentFromText name
  return (x, LowValueVarLocal x)

newValueLocal' :: Maybe T.Text -> IO (Ident, LowValue)
newValueLocal' mName = do
  x <- newNameWith mName
  return (x, LowValueVarLocal x)

newNameWith :: Maybe T.Text -> IO Ident
newNameWith mName =
  case mName of
    Nothing ->
      newIdentFromText "var"
    Just name ->
      newIdentFromText name

enumValueToInteger :: T.Text -> IO Int
enumValueToInteger label = do
  revEnumEnv <- readIORef revEnumEnvRef
  case Map.lookup label revEnumEnv of
    Just (_, i) ->
      return i
    _ -> do
      print revEnumEnv
      raiseCritical' $ "no such enum is defined: " <> label

insLowDefEnv :: T.Text -> [Ident] -> LowComp -> IO ()
insLowDefEnv funName args e =
  modifyIORef' lowDefEnvRef $ Map.insert funName (args, e)

commConv :: Ident -> LowComp -> LowComp -> IO LowComp
commConv x llvm cont2 =
  case llvm of
    LowCompReturn d ->
      return $ LowCompLet x (LowOpBitcast d voidPtr voidPtr) cont2 -- nop
    LowCompLet y op cont1 -> do
      cont <- commConv x cont1 cont2
      return $ LowCompLet y op cont
    LowCompCont op cont1 -> do
      cont <- commConv x cont1 cont2
      return $ LowCompCont op cont
    LowCompSwitch (d, t) defaultCase caseList -> do
      let (ds, es) = unzip caseList
      es' <- mapM (\e -> commConv x e cont2) es
      let caseList' = zip ds es'
      defaultCase' <- commConv x defaultCase cont2
      return $ LowCompSwitch (d, t) defaultCase' caseList'
    LowCompCall d ds ->
      return $ LowCompLet x (LowOpCall d ds) cont2
    LowCompUnreachable ->
      return LowCompUnreachable

insDeclEnv :: T.Text -> [a] -> IO ()
insDeclEnv name args = do
  lowDeclEnv <- readIORef lowDeclEnvRef
  unless (name `Map.member` lowDeclEnv) $ do
    let dom = map (const voidPtr) args
    let cod = voidPtr
    modifyIORef' lowDeclEnvRef $ Map.insert name (dom, cod)

registerCartesian :: T.Text -> IO ()
registerCartesian name = do
  compDefEnv <- readIORef compDefEnvRef
  case Map.lookup name compDefEnv of
    Just (_, args, e) ->
      lowerComp e >>= insLowDefEnv name args
    _ ->
      return ()
