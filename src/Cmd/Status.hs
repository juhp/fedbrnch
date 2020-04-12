module Cmd.Status (statusCmd) where

import Common
import Common.System

import Distribution.Fedora.Branch

import Bugzilla
import Branches
import Git
import Koji
import ListReviews
import Package
import Types (Package)

-- FIXME add --no-pull?
-- FIXME --pending
-- FIXME show bodhi days left
statusCmd :: Bool -> ([Branch],[Package]) -> IO ()
statusCmd reviews (brs,pkgs) = do
  when reviews $
    (map reviewBugToPackage <$> listReviews' True ReviewRepoCreated) >>= mapM_ (withPackageDir False statusBranch brs)
  withPackageBranches False statusBranch (brs,pkgs)

statusBranch :: Maybe Package -> Branch -> IO ()
statusBranch mpkg br = do
  pkg <- getPackageName mpkg
  branched <- gitBool "show-ref" ["--verify", "--quiet", "refs/remotes/origin/" ++ show br]
  if not branched
    then putStrLn $ "No " ++ show br ++ " branch"
    else do
    clean <- workingDirClean
    if not clean then
      putStrLn "working dir is dirty"
      else do
      switchBranch br
      let spec = pkg <.> "spec"
      haveSpec <- doesFileExist spec
      if not haveSpec then do
        newrepo <- initialPkgRepo
        if newrepo then putStrLn $ show br ++ ": initial repo"
          else putStrLn $ "missing " ++ spec
        else do
        mnvr <- cmdMaybe "fedpkg" ["verrel"]
        case mnvr of
          Nothing -> do
            putStrLn "undefined NVR!\n"
            putStr "HEAD "
            simplifyCommitLog <$> gitShortLog1 Nothing >>= putStrLn
          Just nvr -> do
            -- unless (br == Master) $ do
            --   prev <- do
            --     branches <- getFedoraBranches
            --     return $ newerBranch branches br
            --   ancestor <- gitBool "merge-base" ["--is-ancestor", "HEAD", show prev]
            --   when ancestor $ do
            --     unmerged <- gitShortLog $ "HEAD.." ++ show prev
            --     unless (null unmerged) $ do
            --       putStrLn $ "Newer commits in " ++ show prev ++ ":"
            --       mapM_ (putStrLn . simplifyCommitLog) unmerged
            unpushed <- gitShortLog1 $ Just $ "origin/" ++ show br ++ "..HEAD"
            if null unpushed then do
              mtags <- kojiBuildTags nvr
              case mtags of
                Nothing -> do
                  latest <- cmd "koji" ["latest-build", "--quiet", branchDestTag br, pkg]
                  -- FIXME should we check for any build/task if null?
                  putStrLn $ if dropExtension nvr == dropExtension latest then nvr ++ " is already latest" else (if null latest then "new " else (head . words) latest ++ " ->\n") ++ nvr
                Just [] -> do
                  status <- kojiBuildStatus nvr
                  -- FIXME show pending archs building
                  putStrLn $ nvr ++ " (" ++ show status ++ ")"
                Just tags ->
                  putStrLn $ nvr ++ " (" ++ unwords tags ++ ")"
              else putStrLn $ show br ++ ": " ++ simplifyCommitLog unpushed
