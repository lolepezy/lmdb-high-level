{-# LANGUAGE GADTs #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE RankNTypes #-}

module Lmdb.Internal where

import Database.LMDB.Raw
import Lmdb.Types
import Data.Word
import Foreign.Storable
import Data.Coerce
import Data.Functor
import Data.Bits
import Control.Concurrent (runInBoundThread,isCurrentThreadBound)
import Data.Bool (bool)
import System.IO (withFile,IOMode(ReadMode))
import Foreign.C.Types (CSize(..))
import Foreign.Ptr (Ptr,plusPtr)
import Foreign.Marshal.Alloc (allocaBytes,alloca)
import Control.Monad
import Control.Exception (finally, bracketOnError, bracket)

-- | Alternative to 'withKVPtrs' that allows us to not initialize the key or the
--   value.
withKVPtrsNoInit :: (Ptr MDB_val -> Ptr MDB_val -> IO a) -> IO a
withKVPtrsNoInit fn =
  allocaBytes (unsafeShiftL mdb_val_size 1) $ \pK ->
    let pV = pK `plusPtr` mdb_val_size
     in fn pK pV
{-# INLINE withKVPtrsNoInit #-}

withKVPtrsInitKey :: MDB_val -> (Ptr MDB_val -> Ptr MDB_val -> IO a) -> IO a
withKVPtrsInitKey k fn =
  allocaBytes (unsafeShiftL mdb_val_size 1) $ \pK ->
    let pV = pK `plusPtr` mdb_val_size
     in poke pK k >> fn pK pV
{-# INLINE withKVPtrsInitKey #-}


sizeOfMachineWord :: CSize
sizeOfMachineWord = fromIntegral (sizeOf (undefined :: Word))

mdb_val_size :: Int
mdb_val_size = sizeOf (undefined :: MDB_val)

runEncoding :: Encoding s a -> a -> SizedPoke
runEncoding x a = case x of
  EncodingVariable f -> f a
  EncodingFixed sz f -> SizedPoke sz (getFixedPoke (f a))
  EncodingMachineWord f -> SizedPoke sizeOfMachineWord (getFixedPoke (f a))

mdb_cursor_put_X :: MDB_WriteFlags -> CursorByFfi -> MDB_val -> MDB_val -> IO Bool
mdb_cursor_put_X flags x k v = case x of
  CursorSafe cur -> mdb_cursor_put flags cur k v
  CursorUnsafe cur -> mdb_cursor_put' flags cur k v

mdb_put_X :: MDB_WriteFlags -> MDB_txn -> DbiByFfi -> MDB_val -> MDB_val -> IO Bool
mdb_put_X flags txn x k v = case x of
  DbiSafe dbi -> mdb_put flags txn dbi k v
  DbiUnsafe dbi -> mdb_put' flags txn dbi k v

mdb_get_X :: MDB_txn -> DbiByFfi -> MDB_val -> IO (Maybe MDB_val)
mdb_get_X txn x k = case x of
  DbiSafe dbi -> mdb_get txn dbi k
  DbiUnsafe dbi -> mdb_get' txn dbi k

mdb_cursor_get_X :: MDB_cursor_op -> CursorByFfi -> Ptr MDB_val -> Ptr MDB_val -> IO Bool
mdb_cursor_get_X op x k v = case x of
  CursorSafe cur -> mdb_cursor_get op cur k v
  CursorUnsafe cur -> mdb_cursor_get' op cur k v

mdb_cursor_del_X :: MDB_WriteFlags -> CursorByFfi -> IO ()
mdb_cursor_del_X op x = case x of
  CursorSafe cur -> mdb_cursor_del op cur
  CursorUnsafe cur -> mdb_cursor_del' op cur

mdb_dbi_close_X :: MDB_env -> DbiByFfi -> IO ()
mdb_dbi_close_X env x = case x of
  DbiSafe dbi -> mdb_dbi_close env dbi
  DbiUnsafe dbi -> mdb_dbi_close' env dbi

mdb_cursor_open_X :: MDB_txn -> DbiByFfi -> IO CursorByFfi
mdb_cursor_open_X txn x = case x of
  DbiSafe dbi -> fmap CursorSafe $ mdb_cursor_open txn dbi
  DbiUnsafe dbi -> fmap CursorUnsafe $ mdb_cursor_open' txn dbi

mdb_cursor_close_X :: CursorByFfi -> IO ()
mdb_cursor_close_X x = case x of
  CursorSafe cur -> mdb_cursor_close cur
  CursorUnsafe cur -> mdb_cursor_close' cur

mdb_cmp_X :: MDB_txn -> DbiByFfi -> MDB_val -> MDB_val -> IO Ordering
mdb_cmp_X txn x k1 k2 = case x of
  DbiSafe dbi -> mdb_dcmp txn dbi k1 k2
  DbiUnsafe dbi -> mdb_dcmp' txn dbi k1 k2
  

-- | This one is a little different. The first argument is a 'Bool'
--   that is 'True' if we want we use safe FFI calls and 'False'
--   if we want unsafe FFI calls.
mdb_dbi_open_X :: Bool -> MDB_txn -> Maybe String -> [MDB_DbFlag] -> IO DbiByFfi
mdb_dbi_open_X safeFfi txn mname flags = if safeFfi
  then fmap DbiSafe $ mdb_dbi_open txn mname flags
  else fmap DbiUnsafe $ mdb_dbi_open' txn mname flags

doesSortRequireSafety :: Sort s a -> Bool
doesSortRequireSafety x = case x of
  SortNative _ -> False
  _ -> True

isEncodingDupFixed :: Encoding s a -> Bool
isEncodingDupFixed x = case x of
  EncodingVariable _ -> False
  _ -> True

downgradeSettings :: MultiDatabaseSettings k v -> DatabaseSettings k v
downgradeSettings (MultiDatabaseSettings a b c d e f) = DatabaseSettings a c d e f
{-# INLINE downgradeSettings #-}

downgradeCursor :: MultiCursor s k v -> Cursor s k v
downgradeCursor (MultiCursor ref settings) = Cursor ref (downgradeSettings settings)
{-# INLINE downgradeCursor #-}

insertInternalCursorNeutral :: MDB_WriteFlags -> (Either (Transaction 'ReadWrite,Database k v) (Cursor 'ReadWrite k v)) -> k -> v -> IO Bool
insertInternalCursorNeutral flags e k v = do
  let settings = case e of
        Left (_,Database _ s) -> s
        Right (Cursor _ s) -> s
      (SizedPoke keyCSize@(CSize keySize) keyPoke, SizedPoke valCSize@(CSize valSize) valPoke) =
        case settings of
          DatabaseSettings _ keyEncoding _ valEncoding _ ->
            ( runEncoding keyEncoding k
            , runEncoding valEncoding v
            )
  -- Consider writing a function to improve performance of
  -- double allocations like this.
  allocaBytes (fromIntegral keySize) $ \keyPtr -> do
    allocaBytes (fromIntegral valSize) $ \valPtr -> do
      keyPoke keyPtr
      valPoke valPtr
      let kdata = MDB_val keyCSize keyPtr
          vdata = MDB_val valCSize valPtr
      case e of
        Left (Transaction txn, Database dbi _) -> mdb_put_X flags txn dbi kdata vdata
        Right (Cursor cur _) -> mdb_cursor_put_X flags cur kdata vdata
{-# INLINE insertInternalCursorNeutral #-}

lookupInternal :: Transaction 'ReadOnly -> Database k v -> k -> IO (Maybe v)
lookupInternal (Transaction txn) (Database dbi settings) k = do
  let Decoding decodeValue = databaseSettingsDecodeValue settings
  case settings of
    DatabaseSettings _ keyEncoding _ _ _ -> do
      let SizedPoke (CSize keySize) keyPoke = runEncoding keyEncoding k
      m <- allocaBytes (fromIntegral keySize) $ \keyPtr -> do
        keyPoke keyPtr
        mdb_get_X txn dbi (MDB_val (CSize $ fromIntegral keySize) keyPtr)
      case m of
        Nothing -> return Nothing
        Just (MDB_val valSize valPtr) -> fmap Just $ decodeValue valSize valPtr


insertInternal :: MDB_WriteFlags -> Transaction 'ReadWrite -> Database k v -> k -> v -> IO Bool
insertInternal flags txn db k v =
  insertInternalCursorNeutral flags (Left (txn,db)) k v

insertInternal' :: MDB_WriteFlags -> Transaction 'ReadWrite -> Database k v -> k -> v -> IO ()
insertInternal' a b c d e = insertInternal a b c d e $> ()

noWriteFlags :: MDB_WriteFlags
noWriteFlags = compileWriteFlags []

noOverwriteFlags :: MDB_WriteFlags
noOverwriteFlags = compileWriteFlags [MDB_NOOVERWRITE]

appendFlags :: MDB_WriteFlags
appendFlags = compileWriteFlags [MDB_APPEND]

noDupDataFlags :: MDB_WriteFlags
noDupDataFlags = compileWriteFlags [MDB_NODUPDATA]

decodeOne :: (CSize -> Ptr Word8 -> IO a) -> Bool -> Ptr MDB_val -> IO (Maybe a)
decodeOne decode success keyPtr = if success
  then do
    MDB_val aSize aWordPtr <- peek keyPtr
    a <- decode aSize aWordPtr
    return (Just a)
  else return Nothing
{-# INLINE decodeOne #-}

decodeOne' :: (CSize -> Ptr Word8 -> IO a) -> Bool -> Ptr MDB_val -> Ptr MDB_val -> IO (Maybe a)
decodeOne' a b _ c = decodeOne a b c
{-# INLINE decodeOne' #-}


-- getWithKey :: MDB_cursor_op -> Cursor e k v -> k -> IO (Maybe (KeyValue k v))
-- getWithKey op (Cursor cur settings) k = do
--   let SizedPoke keySize keyPoke = case settings of
--         DatabaseSettings _ keyEncoding _ _ _ -> runEncoding keyEncoding k
--   allocaBytes (fromIntegral keySize) $ \(keyDataPtr :: Ptr Word8) -> do
--     keyPoke keyDataPtr
--     withKVPtrsInitKey (MDB_val keySize keyDataPtr) $ \keyPtr valPtr -> do
--       success <- mdb_cursor_get_X op cur keyPtr valPtr
--       decodeResults success settings keyPtr valPtr

getWithKey :: MDB_cursor_op -> Cursor e k v -> k -> IO (Maybe (KeyValue k v))
getWithKey op c@(Cursor cur settings) = getWithKeyGeneral (decodeResults settings) op c

getValueWithKey :: MDB_cursor_op -> Cursor e k v -> k -> IO (Maybe v)
getValueWithKey op c@(Cursor cur settings) = getWithKeyGeneral (decodeOne' $ getDecoding $ databaseSettingsDecodeValue settings) op c

getWithKeyGeneral :: (Bool -> Ptr MDB_val -> Ptr MDB_val -> IO a) -> MDB_cursor_op -> Cursor e k v -> k -> IO a
getWithKeyGeneral extractResult op (Cursor cur settings) k = do
  let SizedPoke keySize keyPoke = case settings of
        DatabaseSettings _ keyEncoding _ _ _ -> runEncoding keyEncoding k
  allocaBytes (fromIntegral keySize) $ \(keyDataPtr :: Ptr Word8) -> do
    keyPoke keyDataPtr
    withKVPtrsInitKey (MDB_val keySize keyDataPtr) $ \keyPtr valPtr -> do
      success <- mdb_cursor_get_X op cur keyPtr valPtr
      extractResult success keyPtr valPtr

getValueWithoutKey :: MDB_cursor_op -> Cursor e k v -> IO (Maybe v)
getValueWithoutKey op (Cursor cur settings) = do
  withKVPtrsNoInit $ \(keyPtr :: Ptr MDB_val) (valPtr :: Ptr MDB_val) -> do
    success <- mdb_cursor_get_X op cur keyPtr valPtr
    decodeOne (getDecoding $ databaseSettingsDecodeValue settings) success valPtr

decodeResults :: DatabaseSettings k v -> Bool -> Ptr MDB_val -> Ptr MDB_val -> IO (Maybe (KeyValue k v))
decodeResults settings success keyPtr valPtr = if success
  then do
    MDB_val keySize keyWordPtr <- peek keyPtr
    MDB_val valSize valWordPtr <- peek valPtr
    key <- getDecoding (databaseSettingsDecodeKey settings) keySize keyWordPtr
    val <- getDecoding (databaseSettingsDecodeValue settings) valSize valWordPtr
    return (Just (KeyValue key val))
  else return Nothing
{-# INLINE decodeResults #-}

decodeResultsMulti :: MultiDatabaseSettings k v -> Bool -> Ptr MDB_val -> Ptr MDB_val -> IO (Maybe (KeyValue k v))
decodeResultsMulti settings success keyPtr valPtr = if success
  then do
    MDB_val keySize keyWordPtr <- peek keyPtr
    MDB_val valSize valWordPtr <- peek valPtr
    key <- getDecoding (multiDatabaseSettingsDecodeKey settings) keySize keyWordPtr
    val <- getDecoding (multiDatabaseSettingsDecodeValue settings) valSize valWordPtr
    return (Just (KeyValue key val))
  else return Nothing
{-# INLINE decodeResultsMulti #-}


getWithoutKey :: MDB_cursor_op -> Cursor e k v -> IO (Maybe (KeyValue k v))
getWithoutKey op (Cursor cur settings) = do
  withKVPtrsNoInit $ \(keyPtr :: Ptr MDB_val) (valPtr :: Ptr MDB_val) -> do
    success <- mdb_cursor_get_X op cur keyPtr valPtr
    decodeResults settings success keyPtr valPtr
    
getWithoutKeyMulti :: MDB_cursor_op -> MultiCursor e k v -> IO (Maybe (KeyValue k v))
getWithoutKeyMulti op (MultiCursor cur settings) = do
  withKVPtrsNoInit $ \(keyPtr :: Ptr MDB_val) (valPtr :: Ptr MDB_val) -> do
    success <- mdb_cursor_get_X op cur keyPtr valPtr
    decodeResultsMulti settings success keyPtr valPtr
    


deleteInternal :: Transaction 'ReadWrite -> Database k v -> k -> IO ()
deleteInternal (Transaction txn) (Database dbi settings) k = do
  let SizedPoke keySize keyPoke = case settings of
        DatabaseSettings _ keyEncoding _ _ _ -> runEncoding keyEncoding k
  bracket
    (mdb_cursor_open_X txn dbi)
     mdb_cursor_close_X
    (\cur -> 
      allocaBytes (fromIntegral keySize) $ \(keyDataPtr :: Ptr Word8) -> do
        keyPoke keyDataPtr
        withKVPtrsInitKey (MDB_val keySize keyDataPtr) $ \keyPtr valPtr -> do
          success <- mdb_cursor_get_X MDB_SET_KEY cur keyPtr valPtr
          if success 
            then mdb_cursor_del_X noWriteFlags cur
            else return ())

deleteMultiInternal :: Transaction 'ReadWrite -> MultiDatabase k v -> k -> v -> IO ()
deleteMultiInternal (Transaction txn) (MultiDatabase dbi settings) k v =
  bracket
    (mdb_cursor_open_X txn dbi)
     mdb_cursor_close_X
    (\cur -> findAndDelete cur)
    where
      (SizedPoke keyCSize keyPoke, SizedPoke valCSize valPoke) = case settings of
        MultiDatabaseSettings _ _ keyEncoding _ valEncoding _ -> 
          (runEncoding keyEncoding k, runEncoding valEncoding v)

      findAndDelete cur = do 
        allocaBytes (fromIntegral valCSize) $ \valueToFindPtr -> do
          valPoke valueToFindPtr
          let valueToFind = MDB_val valCSize valueToFindPtr

          cmp <- allocaBytes (fromIntegral keyCSize) $ \keyDataPtr -> do
            keyPoke keyDataPtr
            withKVPtrsInitKey (MDB_val keyCSize keyDataPtr) $ \keyPtr valPtr -> do
              success <- mdb_cursor_get_X MDB_SET_KEY cur keyPtr valPtr                        
              compare valueToFind success valPtr              

          deleteOrContinue valueToFind cmp        
          where
            deleteOrContinue valueToFind cmp = 
              case cmp of
                Nothing -> pure ()
                Just EQ -> mdb_cursor_del_X noWriteFlags cur >> moveToNext
                Just _  -> moveToNext
                where
                  moveToNext = do 
                    cmp' <- withKVPtrsNoInit $ \keyPtr valPtr -> do
                      success <- mdb_cursor_get_X MDB_NEXT_DUP cur keyPtr valPtr        
                      compare valueToFind success valPtr
                    deleteOrContinue valueToFind cmp'

      compare valueToFind = decodeOne $ \size ptr -> mdb_cmp_X txn dbi (MDB_val size ptr) valueToFind          

