module Cmd.RequestBranch (
  requestBranches
  ) where

import Common
import Common.System

import Branches
import Bugzilla
import Git
import Krb
import ListReviews
import Package
import Pagure
import Prompt

requestBranches :: Bool -> Maybe BranchOpts -> [String] -> IO ()
requestBranches mock mbrnchopts args = do
  (abrs,ps) <- splitBranchesPkgs False mbrnchopts args
  let brs = map onlyRelBranch abrs
  if null ps then
    ifM isPkgGitRepo
    (getDirectoryName >>= requestPkgBranches mock mbrnchopts brs . Package) $
    do pkgs <- map reviewBugToPackage <$> listReviews ReviewUnbranched
       mapM_ (\ p -> withExistingDirectory p $ requestPkgBranches mock mbrnchopts brs (Package p)) pkgs
  else
    mapM_ (\ p -> withExistingDirectory p $ requestPkgBranches mock mbrnchopts brs (Package p)) ps

-- FIXME add --yes, or skip prompt when args given
requestPkgBranches :: Bool -> Maybe BranchOpts -> [Branch] -> Package -> IO ()
requestPkgBranches mock mbrnchopts brs pkg = do
  putPkgHdr pkg
  git_ "fetch" []
  active <- getFedoraBranched
  branches <- case mbrnchopts of
    Nothing -> if null brs
               then return $ take 2 active
               else return brs
    Just request -> do
      let requested = case request of
                        AllBranches -> active
                        ExcludeBranches xbrs -> active \\ xbrs
      inp <- prompt $ "Confirm branches [" ++ unwords (map show requested) ++ "]"
      return $ if null inp
               then requested
               else map (readActiveBranch' active) $ words inp
  newbranches <- filterExistingBranchRequests branches
  forM_ newbranches $ \ br -> do
    when mock $ fedpkg_ "mockbuild" ["--root", mockConfig br]
    fedpkg_ "request-branch" [show br]
  where
    filterExistingBranchRequests :: [Branch] -> IO [Branch]
    filterExistingBranchRequests branches = do
      existing <- fedoraBranchesNoMaster localBranches
      forM_ branches $ \ br ->
        when (br `elem` existing) $
        putStrLn $ show br ++ " branch already exists"
      let brs' = branches \\ existing
      if null brs' then return []
        else do
        current <- fedoraBranchesNoMaster $ pagurePkgBranches (unPackage pkg)
        forM_ brs' $ \ br ->
          when (br `elem` current) $
          putStrLn $ show br ++ " remote branch already exists"
        let newbranches = brs' \\ current
        if null newbranches then return []
          else do
          fasid <- fasIdFromKrb
          erecent <- pagureListProjectIssueTitlesStatus "pagure.io" "releng/fedora-scm-requests"
                     [makeItem "author" fasid, makeItem "status" "all"]
          case erecent of
            Left err -> error' err
            Right recent -> filterM (notExistingRequest recent) newbranches

    -- FIXME handle close_status Invalid
    notExistingRequest :: [IssueTitleStatus] -> Branch -> IO Bool
    notExistingRequest requests br = do
      let pending = filter ((("New Branch \"" ++ show br ++ "\" for \"rpms/" ++ unPackage pkg ++ "\"") ==) . pagureIssueTitle) requests
      unless (null pending) $ do
        putStrLn $ "Branch request already open for " ++ unPackage pkg ++ ":" ++ show br
        mapM_ printScmIssue pending
      return $ null pending
