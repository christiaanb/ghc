-- (c) The University of Glasgow, 1997-2006

{-# LANGUAGE BangPatterns, CPP, DeriveDataTypeable, MagicHash, UnboxedTuples #-}
{-# OPTIONS_GHC -O -funbox-strict-fields #-}
-- We always optimise this, otherwise performance of a non-optimised
-- compiler is severely affected

-- |
-- There are two principal string types used internally by GHC:
--
-- ['FastString']
--
--   * A compact, hash-consed, representation of character strings.
--   * Comparison is O(1), and you can get a 'Unique.Unique' from them.
--   * Generated by 'fsLit'.
--   * Turn into 'Outputable.SDoc' with 'Outputable.ftext'.
--
-- ['LitString']
--
--   * Just a wrapper for the @Addr#@ of a C string (@Ptr CChar@).
--   * Practically no operations.
--   * Outputing them is fast.
--   * Generated by 'sLit'.
--   * Turn into 'Outputable.SDoc' with 'Outputable.ptext'
--
-- Use 'LitString' unless you want the facilities of 'FastString'.
module FastString
       (
        -- * ByteString
        fastStringToByteString,
        mkFastStringByteString,
        fastZStringToByteString,
        unsafeMkByteString,
        hashByteString,

        -- * FastZString
        FastZString,
        hPutFZS,
        zString,
        lengthFZS,

        -- * FastStrings
        FastString(..),     -- not abstract, for now.

        -- ** Construction
        fsLit,
        mkFastString,
        mkFastStringBytes,
        mkFastStringByteList,
        mkFastStringForeignPtr,
        mkFastString#,

        -- ** Deconstruction
        unpackFS,           -- :: FastString -> String
        bytesFS,            -- :: FastString -> [Word8]

        -- ** Encoding
        zEncodeFS,

        -- ** Operations
        uniqueOfFS,
        lengthFS,
        nullFS,
        appendFS,
        headFS,
        tailFS,
        concatFS,
        consFS,
        nilFS,

        -- ** Outputing
        hPutFS,

        -- ** Internal
        getFastStringTable,
        hasZEncoding,

        -- * LitStrings
        LitString,

        -- ** Construction
        sLit,
        mkLitString#,
        mkLitString,

        -- ** Deconstruction
        unpackLitString,

        -- ** Operations
        lengthLS
       ) where

#include "HsVersions.h"

import Encoding
import FastTypes
import FastFunctions
import Panic
import Util

import Control.Monad
import Data.ByteString (ByteString)
import qualified Data.ByteString          as BS
import qualified Data.ByteString.Char8    as BSC
import qualified Data.ByteString.Internal as BS
import qualified Data.ByteString.Unsafe   as BS
import Foreign.C
import ExtsCompat46
import System.IO
import System.IO.Unsafe ( unsafePerformIO )
import Data.Data
import Data.IORef       ( IORef, newIORef, readIORef, atomicModifyIORef' )
import Data.Maybe       ( isJust )
import Data.Char
import Data.List        ( elemIndex )

import GHC.IO           ( IO(..), unsafeDupablePerformIO )

#if __GLASGOW_HASKELL__ >= 709
import Foreign
#else
import Foreign.Safe
#endif

#if STAGE >= 2
import GHC.Conc.Sync    (sharedCAF)
#endif

import GHC.Base         ( unpackCString# )

#define hASH_TBL_SIZE          4091
#define hASH_TBL_SIZE_UNBOXED  4091#


fastStringToByteString :: FastString -> ByteString
fastStringToByteString f = fs_bs f

fastZStringToByteString :: FastZString -> ByteString
fastZStringToByteString (FastZString bs) = bs

-- This will drop information if any character > '\xFF'
unsafeMkByteString :: String -> ByteString
unsafeMkByteString = BSC.pack

hashByteString :: ByteString -> Int
hashByteString bs
    = inlinePerformIO $ BS.unsafeUseAsCStringLen bs $ \(ptr, len) ->
      return $ hashStr (castPtr ptr) len

-- -----------------------------------------------------------------------------

newtype FastZString = FastZString ByteString

hPutFZS :: Handle -> FastZString -> IO ()
hPutFZS handle (FastZString bs) = BS.hPut handle bs

zString :: FastZString -> String
zString (FastZString bs) =
    inlinePerformIO $ BS.unsafeUseAsCStringLen bs peekCAStringLen

lengthFZS :: FastZString -> Int
lengthFZS (FastZString bs) = BS.length bs

mkFastZStringString :: String -> FastZString
mkFastZStringString str = FastZString (BSC.pack str)

-- -----------------------------------------------------------------------------

{-|
A 'FastString' is an array of bytes, hashed to support fast O(1)
comparison.  It is also associated with a character encoding, so that
we know how to convert a 'FastString' to the local encoding, or to the
Z-encoding used by the compiler internally.

'FastString's support a memoized conversion to the Z-encoding via zEncodeFS.
-}

data FastString = FastString {
      uniq    :: {-# UNPACK #-} !Int, -- unique id
      n_chars :: {-# UNPACK #-} !Int, -- number of chars
      fs_bs   :: {-# UNPACK #-} !ByteString,
      fs_ref  :: {-# UNPACK #-} !(IORef (Maybe FastZString))
  } deriving Typeable

instance Eq FastString where
  f1 == f2  =  uniq f1 == uniq f2

instance Ord FastString where
    -- Compares lexicographically, not by unique
    a <= b = case cmpFS a b of { LT -> True;  EQ -> True;  GT -> False }
    a <  b = case cmpFS a b of { LT -> True;  EQ -> False; GT -> False }
    a >= b = case cmpFS a b of { LT -> False; EQ -> True;  GT -> True  }
    a >  b = case cmpFS a b of { LT -> False; EQ -> False; GT -> True  }
    max x y | x >= y    =  x
            | otherwise =  y
    min x y | x <= y    =  x
            | otherwise =  y
    compare a b = cmpFS a b

instance Show FastString where
   show fs = show (unpackFS fs)

instance Data FastString where
  -- don't traverse?
  toConstr _   = abstractConstr "FastString"
  gunfold _ _  = error "gunfold"
  dataTypeOf _ = mkNoRepType "FastString"

cmpFS :: FastString -> FastString -> Ordering
cmpFS f1@(FastString u1 _ _ _) f2@(FastString u2 _ _ _) =
  if u1 == u2 then EQ else
  compare (fastStringToByteString f1) (fastStringToByteString f2)

foreign import ccall unsafe "ghc_memcmp"
  memcmp :: Ptr a -> Ptr b -> Int -> IO Int

-- -----------------------------------------------------------------------------
-- Construction

{-
Internally, the compiler will maintain a fast string symbol table, providing
sharing and fast comparison. Creation of new @FastString@s then covertly does a
lookup, re-using the @FastString@ if there was a hit.

The design of the FastString hash table allows for lockless concurrent reads
and updates to multiple buckets with low synchronization overhead.

See Note [Updating the FastString table] on how it's updated.
-}
data FastStringTable =
 FastStringTable
    {-# UNPACK #-} !(IORef Int)  -- the unique ID counter shared with all buckets
    (MutableArray# RealWorld (IORef [FastString])) -- the array of mutable buckets

string_table :: FastStringTable
{-# NOINLINE string_table #-}
string_table = unsafePerformIO $ do
  uid <- newIORef 603979776 -- ord '$' * 0x01000000
  tab <- IO $ \s1# -> case newArray# hASH_TBL_SIZE_UNBOXED (panic "string_table") s1# of
                          (# s2#, arr# #) ->
                              (# s2#, FastStringTable uid arr# #)
  forM_ [0.. hASH_TBL_SIZE-1] $ \i -> do
     bucket <- newIORef []
     updTbl tab i bucket

  -- use the support wired into the RTS to share this CAF among all images of
  -- libHSghc
#if STAGE < 2
  return tab
#else
  sharedCAF tab getOrSetLibHSghcFastStringTable

-- from the RTS; thus we cannot use this mechanism when STAGE<2; the previous
-- RTS might not have this symbol
foreign import ccall unsafe "getOrSetLibHSghcFastStringTable"
  getOrSetLibHSghcFastStringTable :: Ptr a -> IO (Ptr a)
#endif

{-

We include the FastString table in the `sharedCAF` mechanism because we'd like
FastStrings created by a Core plugin to have the same uniques as corresponding
strings created by the host compiler itself.  For example, this allows plugins
to lookup known names (eg `mkTcOcc "MySpecialType"`) in the GlobalRdrEnv or
even re-invoke the parser.

In particular, the following little sanity test was failing in a plugin
prototyping safe newtype-coercions: GHC.NT.Type.NT was imported, but could not
be looked up /by the plugin/.

   let rdrName = mkModuleName "GHC.NT.Type" `mkRdrQual` mkTcOcc "NT"
   putMsgS $ showSDoc dflags $ ppr $ lookupGRE_RdrName rdrName $ mg_rdr_env guts

`mkTcOcc` involves the lookup (or creation) of a FastString.  Since the
plugin's FastString.string_table is empty, constructing the RdrName also
allocates new uniques for the FastStrings "GHC.NT.Type" and "NT".  These
uniques are almost certainly unequal to the ones that the host compiler
originally assigned to those FastStrings.  Thus the lookup fails since the
domain of the GlobalRdrEnv is affected by the RdrName's OccName's FastString's
unique.

The old `reinitializeGlobals` mechanism is enough to provide the plugin with
read-access to the table, but it insufficient in the general case where the
plugin may allocate FastStrings. This mutates the supply for the FastStrings'
unique, and that needs to be propagated back to the compiler's instance of the
global variable.  Such propagation is beyond the `reinitializeGlobals`
mechanism.

Maintaining synchronization of the two instances of this global is rather
difficult because of the uses of `unsafePerformIO` in this module.  Not
synchronizing them risks breaking the rather major invariant that two
FastStrings with the same unique have the same string. Thus we use the
lower-level `sharedCAF` mechanism that relies on Globals.c.

-}

lookupTbl :: FastStringTable -> Int -> IO (IORef [FastString])
lookupTbl (FastStringTable _ arr#) (I# i#) =
  IO $ \ s# -> readArray# arr# i# s#

updTbl :: FastStringTable -> Int -> IORef [FastString] -> IO ()
updTbl (FastStringTable _uid arr#) (I# i#) ls = do
  (IO $ \ s# -> case writeArray# arr# i# ls s# of { s2# -> (# s2#, () #) })

mkFastString# :: Addr# -> FastString
mkFastString# a# = mkFastStringBytes ptr (ptrStrLength ptr)
  where ptr = Ptr a#

{- Note [Updating the FastString table]

The procedure goes like this:

1. Read the relevant bucket and perform a look up of the string.
2. If it exists, return it.
3. Otherwise grab a unique ID, create a new FastString and atomically attempt
   to update the relevant bucket with this FastString:

   * Double check that the string is not in the bucket. Another thread may have
     inserted it while we were creating our string.
   * Return the existing FastString if it exists. The one we preemptively
     created will get GCed.
   * Otherwise, insert and return the string we created.
-}

{- Note [Double-checking the bucket]

It is not necessary to check the entire bucket the second time. We only have to
check the strings that are new to the bucket since the last time we read it.
-}

mkFastStringWith :: (Int -> IO FastString) -> Ptr Word8 -> Int -> IO FastString
mkFastStringWith mk_fs !ptr !len = do
    let hash = hashStr ptr len
    bucket <- lookupTbl string_table hash
    ls1 <- readIORef bucket
    res <- bucket_match ls1 len ptr
    case res of
        Just v  -> return v
        Nothing -> do
            n <- get_uid
            new_fs <- mk_fs n

            atomicModifyIORef' bucket $ \ls2 ->
                -- Note [Double-checking the bucket]
                let delta_ls = case ls1 of
                        []  -> ls2
                        l:_ -> case l `elemIndex` ls2 of
                            Nothing  -> panic "mkFastStringWith"
                            Just idx -> take idx ls2

                -- NB: Might as well use inlinePerformIO, since the call to
                -- bucket_match doesn't perform any IO that could be floated
                -- out of this closure or erroneously duplicated.
                in case inlinePerformIO (bucket_match delta_ls len ptr) of
                    Nothing -> (new_fs:ls2, new_fs)
                    Just fs -> (ls2,fs)
  where
    !(FastStringTable uid _arr) = string_table

    get_uid = atomicModifyIORef' uid $ \n -> (n+1,n)

mkFastStringBytes :: Ptr Word8 -> Int -> FastString
mkFastStringBytes !ptr !len =
    -- NB: Might as well use unsafeDupablePerformIO, since mkFastStringWith is
    -- idempotent.
    unsafeDupablePerformIO $
        mkFastStringWith (copyNewFastString ptr len) ptr len

-- | Create a 'FastString' from an existing 'ForeignPtr'; the difference
-- between this and 'mkFastStringBytes' is that we don't have to copy
-- the bytes if the string is new to the table.
mkFastStringForeignPtr :: Ptr Word8 -> ForeignPtr Word8 -> Int -> IO FastString
mkFastStringForeignPtr ptr !fp len
    = mkFastStringWith (mkNewFastString fp ptr len) ptr len

-- | Create a 'FastString' from an existing 'ForeignPtr'; the difference
-- between this and 'mkFastStringBytes' is that we don't have to copy
-- the bytes if the string is new to the table.
mkFastStringByteString :: ByteString -> FastString
mkFastStringByteString bs =
    inlinePerformIO $
      BS.unsafeUseAsCStringLen bs $ \(ptr, len) -> do
        let ptr' = castPtr ptr
        mkFastStringWith (mkNewFastStringByteString bs ptr' len) ptr' len

-- | Creates a UTF-8 encoded 'FastString' from a 'String'
mkFastString :: String -> FastString
mkFastString str =
  inlinePerformIO $ do
    let l = utf8EncodedLength str
    buf <- mallocForeignPtrBytes l
    withForeignPtr buf $ \ptr -> do
      utf8EncodeString ptr str
      mkFastStringForeignPtr ptr buf l

-- | Creates a 'FastString' from a UTF-8 encoded @[Word8]@
mkFastStringByteList :: [Word8] -> FastString
mkFastStringByteList str =
  inlinePerformIO $ do
    let l = Prelude.length str
    buf <- mallocForeignPtrBytes l
    withForeignPtr buf $ \ptr -> do
      pokeArray (castPtr ptr) str
      mkFastStringForeignPtr ptr buf l

-- | Creates a Z-encoded 'FastString' from a 'String'
mkZFastString :: String -> FastZString
mkZFastString = mkFastZStringString

bucket_match :: [FastString] -> Int -> Ptr Word8 -> IO (Maybe FastString)
bucket_match [] _ _ = return Nothing
bucket_match (v@(FastString _ _ bs _):ls) len ptr
      | len == BS.length bs = do
         b <- BS.unsafeUseAsCString bs $ \buf ->
             cmpStringPrefix ptr (castPtr buf) len
         if b then return (Just v)
              else bucket_match ls len ptr
      | otherwise =
         bucket_match ls len ptr

mkNewFastString :: ForeignPtr Word8 -> Ptr Word8 -> Int -> Int
                -> IO FastString
mkNewFastString fp ptr len uid = do
  ref <- newIORef Nothing
  n_chars <- countUTF8Chars ptr len
  return (FastString uid n_chars (BS.fromForeignPtr fp 0 len) ref)

mkNewFastStringByteString :: ByteString -> Ptr Word8 -> Int -> Int
                          -> IO FastString
mkNewFastStringByteString bs ptr len uid = do
  ref <- newIORef Nothing
  n_chars <- countUTF8Chars ptr len
  return (FastString uid n_chars bs ref)

copyNewFastString :: Ptr Word8 -> Int -> Int -> IO FastString
copyNewFastString ptr len uid = do
  fp <- copyBytesToForeignPtr ptr len
  ref <- newIORef Nothing
  n_chars <- countUTF8Chars ptr len
  return (FastString uid n_chars (BS.fromForeignPtr fp 0 len) ref)

copyBytesToForeignPtr :: Ptr Word8 -> Int -> IO (ForeignPtr Word8)
copyBytesToForeignPtr ptr len = do
  fp <- mallocForeignPtrBytes len
  withForeignPtr fp $ \ptr' -> copyBytes ptr' ptr len
  return fp

cmpStringPrefix :: Ptr Word8 -> Ptr Word8 -> Int -> IO Bool
cmpStringPrefix ptr1 ptr2 len =
 do r <- memcmp ptr1 ptr2 len
    return (r == 0)


hashStr  :: Ptr Word8 -> Int -> Int
 -- use the Addr to produce a hash value between 0 & m (inclusive)
hashStr (Ptr a#) (I# len#) = loop 0# 0#
   where
    loop h n | n ExtsCompat46.==# len# = I# h
             | otherwise  = loop h2 (n ExtsCompat46.+# 1#)
          where !c = ord# (indexCharOffAddr# a# n)
                !h2 = (c ExtsCompat46.+# (h ExtsCompat46.*# 128#)) `remInt#`
                      hASH_TBL_SIZE#

-- -----------------------------------------------------------------------------
-- Operations

-- | Returns the length of the 'FastString' in characters
lengthFS :: FastString -> Int
lengthFS f = n_chars f

-- | Returns @True@ if this 'FastString' is not Z-encoded but already has
-- a Z-encoding cached (used in producing stats).
hasZEncoding :: FastString -> Bool
hasZEncoding (FastString _ _ _ ref) =
      inlinePerformIO $ do
        m <- readIORef ref
        return (isJust m)

-- | Returns @True@ if the 'FastString' is empty
nullFS :: FastString -> Bool
nullFS f = BS.null (fs_bs f)

-- | Unpacks and decodes the FastString
unpackFS :: FastString -> String
unpackFS (FastString _ _ bs _) =
  inlinePerformIO $ BS.unsafeUseAsCStringLen bs $ \(ptr, len) ->
        utf8DecodeString (castPtr ptr) len

-- | Gives the UTF-8 encoded bytes corresponding to a 'FastString'
bytesFS :: FastString -> [Word8]
bytesFS fs = BS.unpack $ fastStringToByteString fs

-- | Returns a Z-encoded version of a 'FastString'.  This might be the
-- original, if it was already Z-encoded.  The first time this
-- function is applied to a particular 'FastString', the results are
-- memoized.
--
zEncodeFS :: FastString -> FastZString
zEncodeFS fs@(FastString _ _ _ ref) =
      inlinePerformIO $ do
        m <- readIORef ref
        case m of
          Just zfs -> return zfs
          Nothing -> do
            atomicModifyIORef' ref $ \m' -> case m' of
              Nothing  -> let zfs = mkZFastString (zEncodeString (unpackFS fs))
                          in (Just zfs, zfs)
              Just zfs -> (m', zfs)

appendFS :: FastString -> FastString -> FastString
appendFS fs1 fs2 = mkFastStringByteString
                 $ BS.append (fastStringToByteString fs1)
                             (fastStringToByteString fs2)

concatFS :: [FastString] -> FastString
concatFS ls = mkFastString (Prelude.concat (map unpackFS ls)) -- ToDo: do better

headFS :: FastString -> Char
headFS (FastString _ 0 _ _) = panic "headFS: Empty FastString"
headFS (FastString _ _ bs _) =
  inlinePerformIO $ BS.unsafeUseAsCString bs $ \ptr ->
         return (fst (utf8DecodeChar (castPtr ptr)))

tailFS :: FastString -> FastString
tailFS (FastString _ 0 _ _) = panic "tailFS: Empty FastString"
tailFS (FastString _ _ bs _) =
    inlinePerformIO $ BS.unsafeUseAsCString bs $ \ptr ->
    do let (_, n) = utf8DecodeChar (castPtr ptr)
       return $! mkFastStringByteString (BS.drop n bs)

consFS :: Char -> FastString -> FastString
consFS c fs = mkFastString (c : unpackFS fs)

uniqueOfFS :: FastString -> FastInt
uniqueOfFS (FastString u _ _ _) = iUnbox u

nilFS :: FastString
nilFS = mkFastString ""

-- -----------------------------------------------------------------------------
-- Stats

getFastStringTable :: IO [[FastString]]
getFastStringTable = do
  buckets <- forM [0.. hASH_TBL_SIZE-1] $ \idx -> do
    bucket <- lookupTbl string_table idx
    readIORef bucket
  return buckets

-- -----------------------------------------------------------------------------
-- Outputting 'FastString's

-- |Outputs a 'FastString' with /no decoding at all/, that is, you
-- get the actual bytes in the 'FastString' written to the 'Handle'.
hPutFS :: Handle -> FastString -> IO ()
hPutFS handle fs = BS.hPut handle $ fastStringToByteString fs

-- ToDo: we'll probably want an hPutFSLocal, or something, to output
-- in the current locale's encoding (for error messages and suchlike).

-- -----------------------------------------------------------------------------
-- LitStrings, here for convenience only.

-- hmm, not unboxed (or rather FastPtr), interesting
--a.k.a. Ptr CChar, Ptr Word8, Ptr (), hmph.  We don't
--really care about C types in naming, where we can help it.
type LitString = Ptr Word8
--Why do we recalculate length every time it's requested?
--If it's commonly needed, we should perhaps have
--data LitString = LitString {-#UNPACK#-}!(FastPtr Word8) {-#UNPACK#-}!FastInt

mkLitString# :: Addr# -> LitString
mkLitString# a# = Ptr a#
--can/should we use FastTypes here?
--Is this likely to be memory-preserving if only used on constant strings?
--should we inline it? If lucky, that would make a CAF that wouldn't
--be computationally repeated... although admittedly we're not
--really intending to use mkLitString when __GLASGOW_HASKELL__...
--(I wonder, is unicode / multi-byte characters allowed in LitStrings
-- at all?)
{-# INLINE mkLitString #-}
mkLitString :: String -> LitString
mkLitString s =
 unsafePerformIO (do
   p <- mallocBytes (length s + 1)
   let
     loop :: Int -> String -> IO ()
     loop !n [] = pokeByteOff p n (0 :: Word8)
     loop n (c:cs) = do
        pokeByteOff p n (fromIntegral (ord c) :: Word8)
        loop (1+n) cs
   loop 0 s
   return p
 )

unpackLitString :: LitString -> String
unpackLitString p_ = case pUnbox p_ of
 p -> unpack (_ILIT(0))
  where
    unpack n = case indexWord8OffFastPtrAsFastChar p n of
      ch -> if ch `eqFastChar` _CLIT('\0')
            then [] else cBox ch : unpack (n +# _ILIT(1))

lengthLS :: LitString -> Int
lengthLS = ptrStrLength

-- for now, use a simple String representation
--no, let's not do that right now - it's work in other places
#if 0
type LitString = String

mkLitString :: String -> LitString
mkLitString = id

unpackLitString :: LitString -> String
unpackLitString = id

lengthLS :: LitString -> Int
lengthLS = length

#endif

-- -----------------------------------------------------------------------------
-- under the carpet

foreign import ccall unsafe "ghc_strlen"
  ptrStrLength :: Ptr Word8 -> Int

{-# NOINLINE sLit #-}
sLit :: String -> LitString
sLit x  = mkLitString x

{-# NOINLINE fsLit #-}
fsLit :: String -> FastString
fsLit x = mkFastString x

{-# RULES "slit"
    forall x . sLit  (unpackCString# x) = mkLitString#  x #-}
{-# RULES "fslit"
    forall x . fsLit (unpackCString# x) = mkFastString# x #-}
