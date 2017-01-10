module Scientific.Workflow
    ( runWorkflow
    , module Scientific.Workflow.Builder
    , module Scientific.Workflow.Types
    ) where

import           Control.Concurrent             (forkIO)
import           Control.Concurrent.MVar
import           Control.Exception              (bracket, displayException)
import           Control.Monad.State
import           Control.Monad.Trans.Except
import           Data.Graph.Inductive.Graph     (lab, labNodes)
import           Data.Graph.Inductive.Query.DFS (rdfs)
import qualified Data.Map                       as M
import           Data.Maybe                     (fromJust)
import qualified Data.Set                       as S
import           Data.Tuple                     (swap)
import           Data.Yaml                      (decodeFile)
import           Text.Printf                    (printf)

import           Scientific.Workflow.Builder
import           Scientific.Workflow.DB
import           Scientific.Workflow.Types
import           Scientific.Workflow.Utils

runWorkflow :: Workflow -> RunOpt -> IO ()
runWorkflow (Workflow gr pids wf) opts =
    bracket (openDB $ database opts) closeDB $ \db -> do
        ks <- S.fromList <$> getKeys db
        let selection = case selected opts of
                Nothing -> Nothing
                Just xs -> let nodeMap = M.fromList $ map swap $ labNodes gr
                               nds = map (flip (M.findWithDefault undefined) nodeMap) xs
                           in Just $ S.fromList $ map (fromJust . lab gr) $ rdfs nds gr

        pidStateMap <- flip M.traverseWithKey pids $ \pid attr ->
            case runMode opts of
                Master -> do
                    v <- case fmap (S.member pid) selection of
                        Just False -> newMVar Skip
                        _ -> if pid `S.member` ks
                            then newMVar Success
                            else newMVar Scheduled
                    return (v, attr)
                Slave i input output -> do
                    v <- if pid == i
                        then newMVar (EXE input output)
                        else newMVar Skip
                    return (v, attr)
                Review i -> do
                    v <- if pid == i then newMVar Get else newMVar Skip
                    return (v, attr)
                Replace i input -> do
                    v <- if pid == i then newMVar (Put input) else newMVar Skip
                    return (v, attr)

        para <- newEmptyMVar
        _ <- forkIO $ replicateM_ (nThread opts) $ putMVar para ()

        env <- case configuration opts of
            Nothing -> return M.empty
            Just fl -> do
                r <- decodeFile fl
                case r of
                    Nothing -> error "fail to parse configuration file"
                    Just x -> return x

        let initState = WorkflowState db pidStateMap para (runOnRemote opts) env

        result <- runExceptT $ evalStateT (wf ()) initState
        case result of
            Right _ -> return ()
            Left (pid, ex) -> errorMsg $ printf "\"%s\" failed. The error was: %s."
                pid (displayException ex)
