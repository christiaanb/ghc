{-# LANGUAGE CPP #-}
-- This module deliberately defines orphan instances for now (Binary Version).
{-# OPTIONS_GHC -fno-warn-orphans -fno-warn-name-shadowing #-}
-----------------------------------------------------------------------------
-- |
-- Module      :  GHC.PackageDb
-- Copyright   :  (c) The University of Glasgow 2009, Duncan Coutts 2014
--
-- Maintainer  :  ghc-devs@haskell.org
-- Portability :  portable
--
-- This module provides the view of GHC's database of registered packages that
-- is shared between GHC the compiler\/library, and the ghc-pkg program. It
-- defines the database format that is shared between GHC and ghc-pkg.
--
-- The database format, and this library are constructed so that GHC does not
-- have to depend on the Cabal library. The ghc-pkg program acts as the
-- gateway between the external package format (which is defined by Cabal) and
-- the internal package format which is specialised just for GHC.
--
-- GHC the compiler only needs some of the information which is kept about
-- registerd packages, such as module names, various paths etc. On the other
-- hand ghc-pkg has to keep all the information from Cabal packages and be able
-- to regurgitate it for users and other tools.
--
-- The first trick is that we duplicate some of the information in the package
-- database. We essentially keep two versions of the datbase in one file, one
-- version used only by ghc-pkg which keeps the full information (using the
-- serialised form of the 'InstalledPackageInfo' type defined by the Cabal
-- library); and a second version written by ghc-pkg and read by GHC which has
-- just the subset of information that GHC needs.
--
-- The second trick is that this module only defines in detail the format of
-- the second version -- the bit GHC uses -- and the part managed by ghc-pkg
-- is kept in the file but here we treat it as an opaque blob of data. That way
-- this library avoids depending on Cabal.
--
module GHC.PackageDb (
       InstalledPackageInfo(..),
       ModuleExport(..),
       BinaryStringRep(..),
       emptyInstalledPackageInfo,
       readPackageDbForGhc,
       readPackageDbForGhcPkg,
       writePackageDb
  ) where

import Data.Version (Version(..))
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BS.Char8
import qualified Data.ByteString.Lazy as BS.Lazy
import qualified Data.ByteString.Lazy.Internal as BS.Lazy (defaultChunkSize)
import Data.Binary as Bin
import Data.Binary.Put as Bin
import Data.Binary.Get as Bin
import Control.Exception as Exception
import Control.Monad (when)
import System.FilePath
import System.IO
import System.IO.Error
import GHC.IO.Exception (IOErrorType(InappropriateType))
import System.Directory


-- | This is a subset of Cabal's 'InstalledPackageInfo', with just the bits
-- that GHC is interested in.
--
data InstalledPackageInfo instpkgid srcpkgid srcpkgname pkgkey modulename
   = InstalledPackageInfo {
       installedPackageId :: instpkgid,
       sourcePackageId    :: srcpkgid,
       packageName        :: srcpkgname,
       packageVersion     :: Version,
       packageKey         :: pkgkey,
       depends            :: [instpkgid],
       importDirs         :: [FilePath],
       hsLibraries        :: [String],
       extraLibraries     :: [String],
       extraGHCiLibraries :: [String],
       libraryDirs        :: [FilePath],
       frameworks         :: [String],
       frameworkDirs      :: [FilePath],
       ldOptions          :: [String],
       ccOptions          :: [String],
       includes           :: [String],
       includeDirs        :: [FilePath],
       haddockInterfaces  :: [FilePath],
       haddockHTMLs       :: [FilePath],
       exposedModules     :: [modulename],
       hiddenModules      :: [modulename],
       reexportedModules  :: [ModuleExport instpkgid modulename],
       exposed            :: Bool,
       trusted            :: Bool
     }
  deriving (Eq, Show)

class BinaryStringRep a where
  fromStringRep :: BS.ByteString -> a
  toStringRep   :: a -> BS.ByteString

data ModuleExport instpkgid modulename
   = ModuleExport {
       exportModuleName         :: modulename,
       exportOriginalPackageId  :: instpkgid,
       exportOriginalModuleName :: modulename
     }
  deriving (Eq, Show)

emptyInstalledPackageInfo :: (BinaryStringRep a, BinaryStringRep b,
                              BinaryStringRep c, BinaryStringRep d)
                          => InstalledPackageInfo a b c d e
emptyInstalledPackageInfo =
  InstalledPackageInfo {
       installedPackageId = fromStringRep BS.empty,
       sourcePackageId    = fromStringRep BS.empty,
       packageName        = fromStringRep BS.empty,
       packageVersion     = Version [] [],
       packageKey         = fromStringRep BS.empty,
       depends            = [],
       importDirs         = [],
       hsLibraries        = [],
       extraLibraries     = [],
       extraGHCiLibraries = [],
       libraryDirs        = [],
       frameworks         = [],
       frameworkDirs      = [],
       ldOptions          = [],
       ccOptions          = [],
       includes           = [],
       includeDirs        = [],
       haddockInterfaces  = [],
       haddockHTMLs       = [],
       exposedModules     = [],
       hiddenModules      = [],
       reexportedModules  = [],
       exposed            = False,
       trusted            = False
  }

-- | Read the part of the package DB that GHC is interested in.
--
readPackageDbForGhc :: (BinaryStringRep a, BinaryStringRep b, BinaryStringRep c,
                        BinaryStringRep d, BinaryStringRep e) =>
                       FilePath -> IO [InstalledPackageInfo a b c d e]
readPackageDbForGhc file =
    decodeFromFile file getDbForGhc
  where
    getDbForGhc = do
      _version    <- getHeader
      _ghcPartLen <- get :: Get Word32
      ghcPart     <- get
      -- the next part is for ghc-pkg, but we stop here.
      return ghcPart

-- | Read the part of the package DB that ghc-pkg is interested in
--
readPackageDbForGhcPkg :: Binary pkgs => FilePath -> IO pkgs
readPackageDbForGhcPkg file =
    decodeFromFile file getDbForGhcPkg
  where
    getDbForGhcPkg = do
      _version    <- getHeader
      -- skip over the ghc part
      ghcPartLen  <- get :: Get Word32
      _ghcPart    <- skip (fromIntegral ghcPartLen)
      -- the next part is for ghc-pkg
      ghcPkgPart  <- get
      return ghcPkgPart

-- | Write the whole of the package DB, both parts.
--
writePackageDb :: (Binary pkgs, BinaryStringRep a, BinaryStringRep b,
                   BinaryStringRep c, BinaryStringRep d, BinaryStringRep e) =>
                  FilePath -> [InstalledPackageInfo a b c d e] -> pkgs -> IO ()
writePackageDb file ghcPkgs ghcPkgPart =
    writeFileAtomic file (runPut putDbForGhcPkg)
  where
    putDbForGhcPkg = do
        putHeader
        put               ghcPartLen
        putLazyByteString ghcPart
        put               ghcPkgPart
      where
        ghcPartLen :: Word32
        ghcPartLen = fromIntegral (BS.Lazy.length ghcPart)
        ghcPart    = encode ghcPkgs

getHeader :: Get (Word32, Word32)
getHeader = do
    magic <- getByteString (BS.length headerMagic)
    when (magic /= headerMagic) $
      fail "not a ghc-pkg db file, wrong file magic number"

    majorVersion <- get :: Get Word32
    -- The major version is for incompatible changes

    minorVersion <- get :: Get Word32
    -- The minor version is for compatible extensions

    when (majorVersion /= 1) $
      fail "unsupported ghc-pkg db format version"
    -- If we ever support multiple major versions then we'll have to change
    -- this code

    -- The header can be extended without incrementing the major version,
    -- we ignore fields we don't know about (currently all).
    headerExtraLen <- get :: Get Word32
    skip (fromIntegral headerExtraLen)

    return (majorVersion, minorVersion)

putHeader :: Put
putHeader = do
    putByteString headerMagic
    put majorVersion
    put minorVersion
    put headerExtraLen
  where
    majorVersion   = 1 :: Word32
    minorVersion   = 0 :: Word32
    headerExtraLen = 0 :: Word32

headerMagic :: BS.ByteString
headerMagic = BS.Char8.pack "\0ghcpkg\0"


-- | Feed a 'Get' decoder with data chunks from a file.
--
decodeFromFile :: FilePath -> Get a -> IO a
decodeFromFile file decoder =
    withBinaryFile file ReadMode $ \hnd ->
      feed hnd (runGetIncremental decoder)
  where
    feed hnd (Partial k)  = do chunk <- BS.hGet hnd BS.Lazy.defaultChunkSize
                               if BS.null chunk
                                 then feed hnd (k Nothing)
                                 else feed hnd (k (Just chunk))
    feed _ (Done _ _ res) = return res
    feed _ (Fail _ _ msg) = ioError err
      where
        err = mkIOError InappropriateType loc Nothing (Just file)
              `ioeSetErrorString` msg
        loc = "GHC.PackageDb.readPackageDb"

writeFileAtomic :: FilePath -> BS.Lazy.ByteString -> IO ()
writeFileAtomic targetPath content = do
  let (targetDir, targetName) = splitFileName targetPath
  Exception.bracketOnError
    (openBinaryTempFileWithDefaultPermissions targetDir $ targetName <.> "tmp")
    (\(tmpPath, hnd) -> hClose hnd >> removeFile tmpPath)
    (\(tmpPath, hnd) -> do
        BS.Lazy.hPut hnd content
        hClose hnd
#if mingw32_HOST_OS || mingw32_TARGET_OS
        renameFile tmpPath targetPath
          -- If the targetPath exists then renameFile will fail
          `catchIO` \err -> do
            exists <- doesFileExist targetPath
            if exists
              then do removeFile targetPath
                      -- Big fat hairy race condition
                      renameFile newFile targetPath
                      -- If the removeFile succeeds and the renameFile fails
                      -- then we've lost the atomic property.
              else throwIOIO err
#else
        renameFile tmpPath targetPath
#endif
        )


instance (BinaryStringRep a, BinaryStringRep b, BinaryStringRep c,
          BinaryStringRep d, BinaryStringRep e) =>
         Binary (InstalledPackageInfo a b c d e) where
  put (InstalledPackageInfo
         installedPackageId sourcePackageId
         packageName packageVersion packageKey
         depends importDirs
         hsLibraries extraLibraries extraGHCiLibraries libraryDirs
         frameworks frameworkDirs
         ldOptions ccOptions
         includes includeDirs
         haddockInterfaces haddockHTMLs
         exposedModules hiddenModules reexportedModules
         exposed trusted) = do
    put (toStringRep installedPackageId)
    put (toStringRep sourcePackageId)
    put (toStringRep packageName)
    put packageVersion
    put (toStringRep packageKey)
    put (map toStringRep depends)
    put importDirs
    put hsLibraries
    put extraLibraries
    put extraGHCiLibraries
    put libraryDirs
    put frameworks
    put frameworkDirs
    put ldOptions
    put ccOptions
    put includes
    put includeDirs
    put haddockInterfaces
    put haddockHTMLs
    put (map toStringRep exposedModules)
    put (map toStringRep hiddenModules)
    put reexportedModules
    put exposed
    put trusted

  get = do
    installedPackageId <- get
    sourcePackageId    <- get
    packageName        <- get
    packageVersion     <- get
    packageKey         <- get
    depends            <- get
    importDirs         <- get
    hsLibraries        <- get
    extraLibraries     <- get
    extraGHCiLibraries <- get
    libraryDirs        <- get
    frameworks         <- get
    frameworkDirs      <- get
    ldOptions          <- get
    ccOptions          <- get
    includes           <- get
    includeDirs        <- get
    haddockInterfaces  <- get
    haddockHTMLs       <- get
    exposedModules     <- get
    hiddenModules      <- get
    reexportedModules  <- get
    exposed            <- get
    trusted            <- get
    return (InstalledPackageInfo
              (fromStringRep installedPackageId)
              (fromStringRep sourcePackageId)
              (fromStringRep packageName) packageVersion
              (fromStringRep packageKey)
              (map fromStringRep depends)
              importDirs
              hsLibraries extraLibraries extraGHCiLibraries libraryDirs
              frameworks frameworkDirs
              ldOptions ccOptions
              includes includeDirs
              haddockInterfaces haddockHTMLs
              (map fromStringRep exposedModules)
              (map fromStringRep hiddenModules)
              reexportedModules
              exposed trusted)

instance Binary Version where
  put (Version a b) = do
    put a
    put b
  get = do
    a <- get
    b <- get
    return (Version a b)

instance (BinaryStringRep a, BinaryStringRep b) =>
         Binary (ModuleExport a b) where
  put (ModuleExport a b c) = do
    put (toStringRep a)
    put (toStringRep b)
    put (toStringRep c)
  get = do
    a <- get
    b <- get
    c <- get
    return (ModuleExport (fromStringRep a)
                         (fromStringRep b)
                         (fromStringRep c))
