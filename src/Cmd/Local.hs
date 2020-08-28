module Cmd.Local (
  installCmd,
  installDepsCmd,
  localCmd,
  mockCmd,
  nvrCmd,
  prepCmd,
  sortCmd,
  RpmWith(..),
  srpmCmd
  ) where

import Distribution.RPM.Build.Order (dependencySortRpmOpts)

import Branches
import Common
import Common.System
import Git
import Package

-- FIXME package countdown
-- FIXME --ignore-uninstalled subpackages
installCmd :: Maybe ForceShort -> Bool -> [String] -> IO ()
installCmd mforceshort reinstall = do
  withPackageByBranches Nothing Nothing Nothing oneBranch installPkg
  where
    installPkg :: Package -> AnyBranch -> IO ()
    installPkg pkg br = do
      spec <- localBranchSpecFile pkg br
      rpms <- builtRpms br spec
      -- removing arch
      let packages = map takeNVRName rpms
      installed <- filterM pkgInstalled packages
      if isJust mforceshort || null installed || reinstall
        then doInstallPkg spec rpms installed
        else putStrLn $ unwords installed ++ " already installed!\n"
      where
        doInstallPkg spec rpms installed = do
          putStrLn $ takeBaseName (head rpms) ++ "\n"
          buildRPMs True mforceshort rpms br spec
          putStrLn ""
          unless (mforceshort == Just ShortCircuit) $
            if reinstall then do
              let reinstalls = filter (\ f -> takeNVRName f `elem` installed) rpms
              unless (null reinstalls) $
                sudo_ "/usr/bin/dnf" $ "reinstall" : "-q" : "-y" : reinstalls
              let remaining = filterDebug $ rpms \\ reinstalls
              unless (null remaining) $
                sudo_ "/usr/bin/dnf" $ "install" : "-q" : "-y" : remaining
              else sudo_ "/usr/bin/dnf" $ "install" : "-q" : "-y" : filterDebug rpms

        filterDebug = filter (\p -> not (any (`isInfixOf` p) ["-debuginfo-", "-debugsource-"]))

takeNVRName :: FilePath -> String
takeNVRName = takeBaseName . takeBaseName

localCmd :: Maybe ForceShort -> [String] -> IO ()
localCmd mforceshort =
  withPackageByBranches Nothing Nothing Nothing zeroOneBranches localBuildPkg
  where
    localBuildPkg :: Package -> AnyBranch -> IO ()
    localBuildPkg pkg br = do
      spec <- localBranchSpecFile pkg br
      rpms <- builtRpms br spec
      buildRPMs False mforceshort rpms br spec

-- FIXME single branch
installDepsCmd :: [String] -> IO ()
installDepsCmd =
  withPackageByBranches Nothing Nothing Nothing zeroOneBranches installDepsPkg
  where
    installDepsPkg :: Package -> AnyBranch -> IO ()
    installDepsPkg pkg br =
      localBranchSpecFile pkg br >>= installDeps

-- FIXME single branch
srpmCmd :: [String] -> IO ()
srpmCmd =
  withPackageByBranches Nothing Nothing Nothing zeroOneBranches srpmBuildPkg
  where
    srpmBuildPkg :: Package -> AnyBranch -> IO ()
    srpmBuildPkg pkg br = do
      spec <- localBranchSpecFile pkg br
      void $ generateSrpm (Just br) spec

data RpmWith = RpmWith String | RpmWithout String

sortCmd :: Maybe RpmWith -> [String] -> IO ()
sortCmd _ [] = return ()
sortCmd mrpmwith args = do
  withPackageByBranches Nothing Nothing Nothing oneBranch dummy args
  let rpmopts = maybe [] toRpmOption mrpmwith
  packages <- dependencySortRpmOpts rpmopts $ reverse args
  putStrLn $ unwords packages
  where
    dummy _ br = gitSwitchBranch br

    toRpmOption :: RpmWith -> [String]
    toRpmOption (RpmWith opt) = ["--with=" ++ opt]
    toRpmOption (RpmWithout opt) = ["--without=" ++ opt]

prepCmd :: [String] -> IO ()
prepCmd =
  withPackageByBranches Nothing Nothing Nothing zeroOneBranches prepPackage

mockCmd :: Maybe Branch -> [String] -> IO ()
mockCmd mroot =
  withPackageByBranches (Just True) Nothing Nothing zeroOneBranches mockBuildPkg
  where
    mockBuildPkg :: Package -> AnyBranch -> IO ()
    mockBuildPkg pkg br = do
      spec <- localBranchSpecFile pkg br
      whenM isPkgGitRepo $ gitSwitchBranch br
      srpm <- generateSrpm (Just br) spec
      let pkgname = unPackage pkg
          mverrel = stripInfix "-" $ removePrefix (pkgname ++ "-") $ takeNVRName srpm
          verrel = maybe "" (uncurry (</>)) mverrel
      let resultsdir = "results_" ++ pkgname </> verrel
      rootBr <- maybe getReleaseBranch return mroot
      cmd_ "mock" ["--root", mockConfig rootBr, "--resultdir=" ++ resultsdir, srpm]

nvrCmd :: Maybe BranchOpts -> [String] -> IO ()
nvrCmd mbrnchopts =
  withPackageByBranches Nothing Nothing mbrnchopts Nothing nvrBranch
  where
    nvrBranch :: Package -> AnyBranch -> IO ()
    nvrBranch pkg br = do
      spec <- localBranchSpecFile pkg br
      case br of
        RelBranch rbr ->
          pkgNameVerRel' rbr spec
        OtherBranch _obr -> do
          sbr <- systemBranch
          pkgNameVerRel' sbr spec
        >>= putStrLn
