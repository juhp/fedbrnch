module Cmd.Local (installCmd, localCmd) where

import Branches
import Common
import Common.System
import Git
import Package

-- FIXME --force
installCmd :: (Maybe Branch,[String]) -> IO ()
installCmd (mbr,pkgs) =
  withPackageBranches NoGitRepo installPkg (maybeToList mbr,pkgs)

installPkg :: String -> Branch -> IO ()
installPkg pkg br = do
  spec <- localBranchSpecFile pkg br
  rpms <- rpmsNameVerRel br spec
  buildRPMs br spec
  sudo_ "dnf" $ "install" : rpms

localCmd :: (Maybe Branch,[String]) -> IO ()
localCmd (mbr,pkgs) =
  withPackageBranches NoGitRepo localBuildPkg (maybeToList mbr,pkgs)

localBuildPkg :: String -> Branch -> IO ()
localBuildPkg pkg br = do
  spec <- localBranchSpecFile pkg br
  buildRPMs br spec

localBranchSpecFile :: String -> Branch -> IO FilePath
localBranchSpecFile pkg br = do
  gitdir <- isPkgGitDir
  when gitdir $ do
    putPkgBrnchHdr pkg br
    gitSwitchBranch br
  if gitdir
    then return $ pkg <.> "spec"
    else findSpecfile
