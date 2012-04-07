module Paths_Workflow (
    version,
    getBinDir, getLibDir, getDataDir, getLibexecDir,
    getDataFileName
  ) where

import Data.Version (Version(..))
import System.Environment (getEnv)

version :: Version
version = Version {versionBranch = [0,6,0,0], versionTags = []}

bindir, libdir, datadir, libexecdir :: FilePath

bindir     = "C:\\Users\\agocorona\\AppData\\Roaming\\cabal\\bin"
libdir     = "C:\\Users\\agocorona\\AppData\\Roaming\\cabal\\Workflow-0.6.0.0\\ghc-7.0.3"
datadir    = "C:\\Users\\agocorona\\AppData\\Roaming\\cabal\\Workflow-0.6.0.0"
libexecdir = "C:\\Users\\agocorona\\AppData\\Roaming\\cabal\\Workflow-0.6.0.0"

getBinDir, getLibDir, getDataDir, getLibexecDir :: IO FilePath
getBinDir = catch (getEnv "Workflow_bindir") (\_ -> return bindir)
getLibDir = catch (getEnv "Workflow_libdir") (\_ -> return libdir)
getDataDir = catch (getEnv "Workflow_datadir") (\_ -> return datadir)
getLibexecDir = catch (getEnv "Workflow_libexecdir") (\_ -> return libexecdir)

getDataFileName :: FilePath -> IO FilePath
getDataFileName name = do
  dir <- getDataDir
  return (dir ++ "\\" ++ name)
