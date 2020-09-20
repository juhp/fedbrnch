{-# LANGUAGE OverloadedStrings #-}

module Cmd.Build (
  buildCmd,
  BuildOpts(..),
  UpdateType(..),
  scratchCmd,
  Archs(..),
  parallelBuildCmd,
  SideTagTarget(..)
  ) where

import Common
import Common.System
import qualified Common.Text as T

import Control.Concurrent.Async
import Data.Aeson.Types (Object, (.:), parseEither)
import Data.Char (isDigit, toLower)
import Distribution.RPM.Build.Order (dependencyLayers)
import Fedora.Bodhi hiding (bodhiUpdate)
import System.Console.Pretty
import System.Time.Extra (sleep)

import Text.Read
import qualified Text.ParserCombinators.ReadP as R
import qualified Text.ParserCombinators.ReadPrec as RP

import Bugzilla
import Branches
import Cmd.Merge
import Git
import Krb
import Koji
import Package
import Prompt

data UpdateType =
  SecurityUpdate | BugfixUpdate | EnhancementUpdate | NewPackageUpdate

instance Show UpdateType where
  show SecurityUpdate = "security"
  show BugfixUpdate = "bugfix"
  show EnhancementUpdate = "enhancement"
  show NewPackageUpdate = "newpackage"

instance Read UpdateType where
  readPrec = do
    s <- look
    case map toLower s of
      "security" -> RP.lift (R.string s) >> return SecurityUpdate
      "bugfix" -> RP.lift (R.string s) >> return BugfixUpdate
      "enhancement" -> RP.lift (R.string s) >> return EnhancementUpdate
      "newpackage" -> RP.lift (R.string s) >> return NewPackageUpdate
      _ -> error' "unknown bodhi update type" >> RP.pfail

data BuildOpts = BuildOpts
  { buildoptMerge :: Bool
  , buildoptNoFailFast :: Bool
  , buildoptTarget :: Maybe String
  , buildoptOverride :: Bool
  , buildoptDryrun :: Bool
  , buildoptUpdateType :: Maybe UpdateType
  }

-- FIXME --add-to-update nvr
-- FIXME vertical vs horizontal builds (ie by package or branch)
-- FIXME --rpmlint (only run for master?)
-- FIXME support --wait-build=NVR
-- FIXME provide direct link to failed task/build.log
-- FIXME default behaviour for build in pkg dir: all branches or current?
buildCmd :: BuildOpts -> Maybe BranchOpts -> [String] -> IO ()
buildCmd opts mbrnchopts args = do
  let singleBrnch = if isJust (buildoptTarget opts)
                    then oneBranch
                    else Nothing
  (brs,pkgs) <- splitBranchesPkgs True mbrnchopts args
  let morethan1 = length pkgs > 1
  withPackageByBranches' (Just False) cleanGitFetchActive mbrnchopts singleBrnch (buildBranch morethan1 opts) (brs,pkgs)

-- FIXME what if untracked files
buildBranch :: Bool -> BuildOpts -> Package -> AnyBranch -> IO ()
buildBranch _ _ _ (OtherBranch _) =
  error' "build only defined for release branches"
buildBranch morethan1 opts pkg rbr@(RelBranch br) = do
  putPkgAnyBrnchHdr pkg rbr
  gitSwitchBranch rbr
  gitMergeOrigin rbr
  newrepo <- initialPkgRepo
  tty <- isTty
  unmerged <- mergeable br
  -- FIXME if already built or failed, also offer merge
  merged <-
    if notNull unmerged && (buildoptMerge opts || newrepo || tty)
      then mergeBranch True unmerged br >> return True
      else return False
  let spec = packageSpec pkg
  checkForSpecFile spec
  checkSourcesMatch spec
  nvr <- pkgNameVerRel' br spec
  putStrLn $ nvr ++ "\n"
  unpushed <- gitShortLog $ "origin/" ++ show br ++ "..HEAD"
  when (not merged || br == Master) $
    unless (null unpushed) $ do
      putStrLn "Local commits:"
      mapM_ (putStrLn . simplifyCommitLog) unpushed
  mpush <-
    if null unpushed then return Nothing
    else
      -- see mergeBranch for: unmerged == 1 (774b5890)
      if tty && (not merged || (newrepo && length unmerged == 1))
      then refPrompt unpushed $ "Press Enter to push" ++ (if length unpushed > 1 then "; or give a ref to push" else "") ++ "; or 'no' to skip pushing"
      else return $ Just Nothing
  let dryrun = buildoptDryrun opts
  buildstatus <- kojiBuildStatus nvr
  let mtarget = buildoptTarget opts
      target = fromMaybe (branchTarget br) mtarget
  case buildstatus of
    Just BuildComplete -> do
      putStrLn $ nvr ++ " is already built"
      when (isJust mpush) $
        error' "Please bump the spec file"
      when morethan1 $ do
        when (br /= Master && isNothing mtarget) $ do
          mtags <- kojiNVRTags nvr
          case mtags of
            Nothing -> error' $ nvr ++ " is untagged"
            Just tags ->
              unless (any (`elem` tags) [show br, show br ++ "-updates", show br ++ "-override"]) $
                unlessM (checkAutoBodhiUpdate br) $
                unless dryrun $
                bodhiCreateOverride nvr
        kojiWaitRepo target nvr
    Just BuildBuilding -> do
      putStrLn $ nvr ++ " is already building"
      when (isJust mpush) $
        error' "Please bump the spec file"
      whenJustM (kojiGetBuildTaskID fedoraHub nvr) kojiWatchTask
      -- FIXME do override
    _ -> do
      mbuildref <- case mpush of
        Nothing -> Just <$> git "show-ref" ["--hash", "origin" </> show br]
        _ -> return $ join mpush
      opentasks <- kojiOpenTasks pkg mbuildref target
      case opentasks of
        [task] -> do
          putStrLn $ nvr ++ " task " ++ displayID task ++ " is already open"
          when (isJust mpush) $
            error' "Please bump the spec file"
          kojiWatchTask task
        (_:_) -> error' $ show (length opentasks) ++ " open " ++ unPackage pkg ++ " tasks already!"
        [] -> do
          let tag = fromMaybe (branchDestTag br) mtarget
          mlatest <- kojiLatestNVR tag $ unPackage pkg
          if equivNVR nvr (fromMaybe "" mlatest)
            then error' $ nvr ++ " is already latest" ++ if Just nvr /= mlatest then " (modulo disttag)" else ""
            else do
            unless dryrun krbTicket
            whenJust mpush $ \ mref ->
              unless dryrun $
              gitPushSilent $ fmap (++ ":" ++ show br) mref
            unlessM (null <$> gitShortLog ("origin" </> show br ++ "..HEAD")) $
              when (mpush == Just Nothing) $
              error' "Unpushed changes remain"
            unlessM isGitDirClean $
              error' "local changes remain (dirty)"
            -- FIXME parse build output
            unless dryrun $ do
              kojiBuildBranch target pkg mbuildref ["--fail-fast"]
              mBugSess <- if isNothing mlatest
                then do
                (mbid, session) <- bzReviewSession
                return $ case mbid of
                  Just bid -> Just (bid,session)
                  Nothing -> Nothing
                else return Nothing
              autoupdate <- checkAutoBodhiUpdate br
              if autoupdate
                then whenJust mBugSess $
                     \ (bid,session) -> postBuildComment session nvr bid
                else do
                when (isNothing mtarget) $ do
                -- FIXME diff previous changelog?
                  changelog <- getChangeLog spec
                  bodhiUpdate (fmap fst mBugSess) changelog nvr
                  -- FIXME prompt for override note
                  when (buildoptOverride opts) $
                    bodhiCreateOverride nvr
              when morethan1 $ kojiWaitRepo target nvr
  where
    bodhiUpdate :: Maybe BugId -> String -> String -> IO ()
    bodhiUpdate mreview changelog nvr = do
      let cbugs = mapMaybe extractBugReference $ lines changelog
          bugs = let bids = [show rev | Just rev <- [mreview]] ++ cbugs in
            if null bids then [] else ["--bugs", intercalate "," bids]
      -- FIXME check for autocreated update (pre-updates-testing)
      -- FIXME also query for open existing bugs
      -- FIXME extract bug no(s) from changelog
      putStrLn $ "Creating Bodhi Update for " ++ nvr ++ ":"
      case buildoptUpdateType opts of
        Nothing -> return ()
        Just updateType -> do
          updateOK <- cmdBool "bodhi" (["updates", "new", "--type", if isJust mreview then "newpackage" else show updateType , "--notes", changelog, "--autokarma", "--autotime", "--close-bugs"] ++ bugs ++ [nvr])
          unless updateOK $ do
            updatequery <- bodhiUpdates [makeItem "display_user" "0", makeItem "builds" nvr]
            case updatequery of
              [] -> do
                putStrLn "bodhi submission failed"
                prompt_ "Press Enter to resubmit to Bodhi"
                bodhiUpdate mreview changelog nvr
              [update] -> case lookupKey "url" update of
                Nothing -> error' "Update created but no url"
                Just uri -> putStrLn uri
              _ -> error' $ "impossible happened: more than one update found for " ++ nvr

    extractBugReference :: String -> Maybe String
    extractBugReference clog =
      let rest = dropWhile (/= '#') clog in
        if null rest then Nothing
        else let bid = takeWhile isDigit $ tail rest in
          if null bid then Nothing else Just bid

checkSourcesMatch :: FilePath -> IO ()
checkSourcesMatch spec = do
  -- "^[Ss]ource[0-9]*:"
  sourcefiles <- map (takeFileName . last . words) <$> cmdLines "spectool" [spec]
  sources <- lines <$> readFile "sources"
  gitfiles <- gitLines "ls-files" []
  forM_ sourcefiles $ \ src ->
    unless (isJust (find (src `isInfixOf`) sources) || src `elem` gitfiles) $ do
    prompt_ $ color Red $ src ++ " not in sources, please fix"
    checkSourcesMatch spec

checkAutoBodhiUpdate :: Branch -> IO Bool
checkAutoBodhiUpdate Master = return True
checkAutoBodhiUpdate br =
  lookupKey'' "create_automatic_updates" <$> bodhiRelease (show br)
  where
    -- Error in $: key "create_automatic_updates" not found
    lookupKey'' :: T.Text -> Object -> Bool
    lookupKey'' k obj =
      let errMsg e = error $ e ++ " " ++ show obj in
        either errMsg id $ parseEither (.: k) obj

bodhiCreateOverride :: String -> IO ()
bodhiCreateOverride nvr = do
  putStrLn $ "Creating Bodhi Override for " ++ nvr ++ ":"
  ok <- cmdBool "bodhi" ["overrides", "save", "--notes", "chain building with fbrnch", "--duration", "7", nvr]
  unless ok $ do
    moverride <- bodhiOverride nvr
    case moverride of
      Nothing -> do
        putStrLn "bodhi override failed"
        prompt_ "Press Enter to retry"
        bodhiCreateOverride nvr
      Just obj -> print obj

data Archs = Archs [String] | ExcludedArchs [String]

-- FIXME default to rawhide/master?
-- FIXME build from a specific git ref
-- FIXME print message about uploading srpm
scratchCmd :: Bool -> Bool -> Bool -> Maybe Archs -> Maybe String -> [String]
           -> IO ()
scratchCmd dryrun rebuildSrpm nofailfast marchopts mtarget =
  withPackageByBranches (Just False) Nothing Nothing Nothing scratchBuild
  where
    scratchBuild :: Package -> AnyBranch -> IO ()
    scratchBuild pkg br = do
      spec <- localBranchSpecFile pkg br
      let target = fromMaybe (anyTarget br) mtarget
      archs <- case marchopts of
        Nothing -> return []
        Just archopts -> case archopts of
          Archs as -> return as
          ExcludedArchs as -> do
            Just (buildtag,_desttag) <- kojiBuildTarget fedoraHub target
            tagArchs <- kojiTagArchs buildtag
            return $ tagArchs \\ as
      let kojiargs = ["--arch-override=" ++ intercalate "," archs | notNull archs] ++ ["--fail-fast" | not nofailfast] ++ ["--no-rebuild-srpm" | not rebuildSrpm]
      pkggit <- isPkgGitRepo
      if pkggit
        then do
        gitSwitchBranch br
        pushed <- do
          clean <- isGitDirClean
          if clean then
            null <$> gitShortLog ("origin/" ++ show br ++ "..HEAD")
            else return False
        unless dryrun $ do
          if pushed then do
            void $ getSources spec
            kojiBuildBranch target pkg Nothing $ "--scratch" : kojiargs
            else srpmBuild target kojiargs spec
          else srpmBuild target kojiargs spec
      where
        srpmBuild :: FilePath -> [String] -> String -> IO ()
        srpmBuild target kojiargs spec =
          void $ generateSrpm (Just br) spec >>= kojiScratchBuild target kojiargs

        anyTarget (RelBranch b) = branchTarget b
        anyTarget _ = "rawhide"

data SideTagTarget = SideTag | Target String

maybeTarget :: Maybe SideTagTarget -> Maybe String
maybeTarget (Just (Target t)) = Just t
maybeTarget _ = Nothing

type Job = (String, Async String)

-- FIXME option to build multiple packages over branches in parallel
-- FIXME require --with-side-tag or --target
-- FIXME use --wait-build=NVR
-- FIXME check sources asap
-- FIXME check not in pkg git dir
parallelBuildCmd :: Bool -> Maybe SideTagTarget -> Maybe BranchOpts -> [String]
                 -> IO ()
parallelBuildCmd dryrun msidetagTarget mbrnchopts args = do
  (brs,pkgs) <- splitBranchesPkgs True mbrnchopts args
  when (null brs && isNothing mbrnchopts) $
    error' "Please specify at least one branch"
  branches <- listOfBranches True True mbrnchopts brs
  let mtarget = maybeTarget msidetagTarget
  when (isJust mtarget && length branches > 1) $
    error' "You can only specify target with one branch"
  if null pkgs
    then do
    unlessM isPkgGitRepo $
      error' "Please specify at least one package"
    parallelBranches $ map onlyRelBranch branches
    else
    forM_ branches $ \ br -> do
      case br of
        (RelBranch rbr) -> do
          putStrLn $ "# " ++ show rbr
          layers <- dependencyLayers pkgs
          mapM_ (parallelBuild rbr) layers
        (OtherBranch _) ->
          error' "parallel builds only defined for release branches"
  where
    parallelBranches :: [Branch] -> IO ()
    parallelBranches brs = do
      krbTicket
      putStrLn $ "Building parallel " ++ show (length brs) ++ " branches:"
      putStrLn $ unwords $ map show brs
      jobs <- mapM setupBranch brs
      failures <- watchJobs [] jobs
      unless (null failures) $
        error' $ "Build failures: " ++ unwords failures
      where
        setupBranch :: Branch -> IO Job
        setupBranch br = do
          job <- startBuild br "." >>= async
          sleep 5
          return (show br,job)

    parallelBuild :: Branch -> [String] -> IO ()
    parallelBuild br layer =  do
      krbTicket
      putStrLn $ "\nBuilding parallel layer of " ++ show (length layer) ++ " packages:"
      putStrLn $ unwords layer
      jobs <- mapM setupBuild layer
      failures <- watchJobs [] jobs
      unless (null failures) $
        error' $ "Build failures: " ++ unwords failures
      where
        setupBuild :: String -> IO Job
        setupBuild pkg = do
          job <- startBuild br pkg >>= async
          sleep 5
          return (pkg,job)

    watchJobs :: [String] -> [Job] -> IO [String]
    watchJobs fails [] = return fails
    watchJobs fails (job:jobs) = do
      sleep 1
      status <- poll (snd job)
      case status of
        Nothing -> watchJobs fails (jobs ++ [job])
        Just (Right nvr) -> do
          putStrLn $ nvr ++ " job " ++ color Yellow "completed" ++  " (" ++ show (length jobs) ++ " jobs left)"
          watchJobs fails jobs
        Just (Left except) -> do
          print except
          let pkg = fst job
          putStrLn $ "** " ++ pkg ++ " job " ++ color Magenta "failed" ++ " ** (" ++ show (length jobs) ++ " jobs left)"
          watchJobs (pkg : fails) jobs

    -- FIXME prefix output with package name
    startBuild :: Branch -> String -> IO (IO String)
    startBuild br pkgdir =
      withExistingDirectory pkgdir $ do
      gitSwitchBranch (RelBranch br)
      pkg <- getPackageName pkgdir
      putPkgBrnchHdr pkg br
      unpushed <- gitShortLog $ "origin/" ++ show br ++ "..HEAD"
      unless (null unpushed) $
        mapM_ (putStrLn . simplifyCommitLog) unpushed
      let spec = packageSpec pkg
      checkForSpecFile spec
      unless (null unpushed) $ do
        checkSourcesMatch spec
        unless dryrun $
          gitPushSilent Nothing
      nvr <- pkgNameVerRel' br spec
      putStrLn $ nvr ++ "\n"
      let mtarget = maybeTarget msidetagTarget
          target = fromMaybe (branchTarget br) mtarget
      -- FIXME should compare git refs
      -- FIXME check for target
      buildstatus <- kojiBuildStatus nvr
      let tag = fromMaybe (branchDestTag br) mtarget
      mlatest <- kojiLatestNVR tag $ unPackage pkg
      case buildstatus of
        Just BuildComplete -> do
          putStrLn $ nvr ++ " is already built"
          when (br /= Master && isNothing mtarget) $ do
            mtags <- kojiNVRTags nvr
            case mtags of
              Nothing -> error' $ nvr ++ " is untagged"
              Just tags ->
                unless (dryrun || any (`elem` tags) [show br, show br ++ "-updates", show br ++ "-override"]) $
                  unlessM (checkAutoBodhiUpdate br) $
                  bodhiCreateOverride nvr
          return $ do
            unless dryrun $
              kojiWaitRepo target nvr
            return nvr
        Just BuildBuilding -> do
          putStrLn $ nvr ++ " is already building"
          return $
            kojiGetBuildTaskID fedoraHub nvr >>=
            maybe (error' $ "Task for " ++ nvr ++ " not found")
            (kojiWaitTaskAndRepo (isNothing mlatest) nvr target)
        _ -> do
          buildref <- git "show-ref" ["--hash", "origin" </> show br]
          opentasks <- kojiOpenTasks pkg (Just buildref) target
          case opentasks of
            [task] -> do
              putStrLn $ nvr ++ " task is already open"
              return $ kojiWaitTaskAndRepo (isNothing mlatest) nvr target task
            (_:_) -> error' $ show (length opentasks) ++ " open " ++ unPackage pkg ++ " tasks already"
            [] -> do
              if equivNVR nvr (fromMaybe "" mlatest)
                then return $ error' $ color Red $ nvr ++ " is already latest (modulo disttag)"
                else do
                -- FIXME parse build output
                if dryrun
                  then return (return nvr)
                  else do
                  task <- kojiBuildBranchNoWait target pkg Nothing ["--fail-fast", "--background"]
                  return $ kojiWaitTaskAndRepo (isNothing mlatest) nvr target task
      where
        kojiWaitTaskAndRepo :: Bool -> String -> String -> TaskID -> IO String
        kojiWaitTaskAndRepo newpkg nvr target task = do
          finish <- kojiWatchTaskQuiet task
          if finish
            then putStrLn $ color Green $ nvr ++ " build success"
            else error' $ color Red $ nvr ++ " build failed"
          unless dryrun $ do
            autoupdate <- checkAutoBodhiUpdate br
            if autoupdate then
              when newpkg $ do
              mBugSess <- do
                (mbid, session) <- bzReviewSession
                return $ case mbid of
                  Just bid -> Just (bid,session)
                  Nothing -> Nothing
              whenJust mBugSess $
                \ (bid,session) -> postBuildComment session nvr bid
              else do
              let mtarget = maybeTarget msidetagTarget
              when (isNothing mtarget) $
                -- -- FIXME: avoid prompt in
                -- changelog <- getChangeLog spec
                -- bodhiUpdate (fmap fst mBugSess) changelog nvr
                bodhiCreateOverride nvr
            kojiWaitRepo target nvr
          return nvr
