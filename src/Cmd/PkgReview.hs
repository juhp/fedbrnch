{-# LANGUAGE OverloadedStrings #-}

module Cmd.PkgReview (
  createReview,
  updateReview,
  ScratchOption(..),
  reviewPackage
  ) where

import Common
import Common.System
import qualified Common.Text as T

import Data.Char
import Network.HTTP.Directory

import Branches
import Bugzilla
import Koji
import Krb
import Package
import Prompt

data ScratchOption = ScratchBuild | ScratchTask Int | SkipScratch
  deriving Eq

-- FIXME add --dependent pkgreview
createReview :: ScratchOption -> Bool -> [FilePath] -> IO ()
createReview scratchOpt mock pkgs =
  withPackageByBranches (Just True) Nothing Zero createPkgReview (Branches [], pkgs)
  where
    createPkgReview :: Package -> AnyBranch -> IO ()
    createPkgReview package _br = do
      let spec = packageSpec package
          pkg = unPackage package
      unless (all isAscii pkg) $
        putStrLn "Warning: package name is not ASCII!"
      putStrLn "checking for existing reviews..."
      (bugs,session) <- bugsSession $ pkgReviews pkg
      unless (null bugs) $ do
        putStrLn "Existing review(s):"
        mapM_ putBug bugs
        -- FIXME abort if open review (unless --force?)
        prompt_ "Press Enter to continue"
      srpm <- generateSrpm Nothing spec
      mockRpmLint mock (scratchOpt == ScratchBuild) pkg spec srpm
      (mkojiurl,specSrpmUrls) <- buildAndUpload scratchOpt srpm pkg spec
      bugid <- postReviewReq session spec specSrpmUrls mkojiurl pkg
      putStrLn "Review request posted:"
      putBugId bugid
      where
        postReviewReq :: BugzillaSession -> FilePath -> String -> Maybe String -> String -> IO BugId
        postReviewReq session spec specSrpmUrls mkojiurl pkg = do
          summary <- cmd "rpmspec" ["-q", "--srpm", "--qf", "%{summary}", spec]
          description <- cmd "rpmspec" ["-q", "--srpm", "--qf", "%{description}", spec]
          createBug session
            [ ("product", "Fedora")
            , ("component", "Package Review")
            , ("version", "rawhide")
            , ("summary", "Review Request: " <> pkg <> " - " <> summary)
            , ("description", specSrpmUrls <> "\n\nDescription:\n" <> description <>  maybe "" ("\n\n\nKoji scratch build: " <>) mkojiurl)]

buildAndUpload :: ScratchOption -> String -> String -> FilePath
               -> IO (Maybe String, String)
buildAndUpload scratchOpt srpm pkg spec = do
  mkojiurl <- case scratchOpt of
                ScratchBuild -> Just <$> kojiScratchBuild "rawhide" [] srpm
                ScratchTask tid -> return $ Just ("https://koji.fedoraproject.org/koji/taskinfo?taskID=" ++ show tid)
                SkipScratch -> return Nothing
  specSrpmUrls <- uploadPkgFiles pkg spec srpm
  return (mkojiurl, specSrpmUrls)

updateReview :: ScratchOption -> Bool -> Maybe FilePath -> IO ()
updateReview scratchOpt mock mspec = do
  spec <- maybe findSpecfile checkLocalFile mspec
  pkg <- cmd "rpmspec" ["-q", "--srpm", "--qf", "%{name}", spec]
  (bid,session) <- reviewBugIdSession pkg
  putBugId bid
  srpm <- generateSrpm Nothing spec
  submitted <- checkForComment session bid (T.pack srpm)
  when submitted $
    error' "This NVR was already posted on the review bug: please bump"
  mockRpmLint mock (scratchOpt == ScratchBuild) pkg spec srpm
  (mkojiurl,specSrpmUrls) <- buildAndUpload scratchOpt srpm pkg spec
  changelog <- getChangeLog Nothing spec
  commentBug session bid (specSrpmUrls <> (if null changelog then "" else "\n\n" <> changelog) <> maybe "" ("\n\nKoji scratch build: " <>) mkojiurl)
  -- putStrLn "Review bug updated"
  where
    checkLocalFile :: FilePath -> IO FilePath
    checkLocalFile f =
      if takeFileName f == f then return f
        else error' "Please run in the directory of the spec file"

uploadPkgFiles :: String -> FilePath -> FilePath -> IO String
uploadPkgFiles pkg spec srpm = do
  fasid <- fasIdFromKrb
  -- read ~/.config/fedora-create-review
  let sshhost = "fedorapeople.org"
      sshpath = "public_html/reviews/" ++ pkg
  cmd_ "ssh" [fasid ++ "@" ++ sshhost, "mkdir", "-p", sshpath]
  cmd_ "scp" [spec, srpm, sshhost ++ ":" ++ sshpath]
  getCheckedFileUrls $ "https://" <> fasid <> ".fedorapeople.org" +/+ removePrefix "public_html/" sshpath
  where
    getCheckedFileUrls :: String -> IO String
    getCheckedFileUrls uploadurl = do
      let specUrl = uploadurl +/+ takeFileName spec
          srpmUrl = uploadurl +/+ takeFileName srpm
      mgr <- httpManager
      checkUrlOk mgr specUrl
      checkUrlOk mgr srpmUrl
      return $ "Spec URL: " <> specUrl <> "\nSRPM URL: " <> srpmUrl
      where
        checkUrlOk mgr url = do
          okay <- httpExists mgr url
          unless okay $ error' $ "Could not access: " ++ url

mockRpmLint :: Bool -> Bool -> String -> FilePath -> FilePath -> IO ()
mockRpmLint mock scratch pkg spec srpm = do
  rpms <-
    if mock then do
      -- FIXME check that mock is installed
      let resultsdir = "results_" ++ pkg
      cmd_ "mock" ["--root", mockConfig Rawhide, "--resultdir=" ++ resultsdir, srpm]
      map (resultsdir </>) . filter ((== ".rpm") . takeExtension) <$> listDirectory resultsdir
    else
      builtRpms (RelBranch Rawhide) spec >>= filterM doesFileExist
  -- FIXME parse # of errors/warnings
  void $ cmdBool "rpmlint" $ spec:srpm:rpms
  prompt_ $ "Press Enter to " ++ if scratch then "submit" else "upload"

-- FIXME does not work with pkg dir/spec:
-- 'fbrnch: No spec file found'
reviewPackage :: Maybe String -> IO ()
reviewPackage mpkg = do
  -- FIXME if spec file exists use it directly
  pkg <- maybe getDirectoryName return mpkg
  (bugs, _) <- if all isDigit pkg
    then bugsSession $ packageReview .&&. statusNewAssigned .&&. bugIdIs (read pkg)
    else bugsSession $ pkgReviews pkg .&&. statusNewAssigned
  case bugs of
    [bug] -> do
      putReviewBug False bug
      prompt_ "Press Enter to run fedora-review"
      -- FIXME support copr build
      -- FIXME if toolbox set REVIEW_NO_MOCKGROUP_CHECK
      cmd_ "fedora-review" ["-b", show (bugId bug)]
    [] -> do
      spec <- findSpecfile
      srpm <- generateSrpm Nothing spec
      cmd_ "fedora-review" ["-rn", srpm]
    _ -> error' $ "More than one review bug found for " ++ pkg
