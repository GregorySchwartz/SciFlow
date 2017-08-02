{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RecordWildCards #-}

module Scientific.Workflow.Internal.Builder
    ( node
    , link
    , (~>)
    , path
    , buildWorkflow
    , buildWorkflowPart
    , mkDAG
    , ContextData(..)
    ) where

import Control.Monad.Identity (runIdentity)
import Control.Lens ((^.), (%~), _1, _2, _3, (&))
import Control.Monad.Trans.Except (throwE)
import           Control.Monad.State (lift, liftIO, (>=>), foldM_, execState, modify, State, get)
import Control.Concurrent.MVar
import Control.Concurrent (forkIO)
import qualified Data.Text           as T
import Data.List.Split (chunksOf)
import Data.Graph.Inductive.Graph ( mkGraph, lab, labNodes, outdeg, nmap
                                  , lpre, labnfilter, nfilter, gmap, suc )
import Data.Graph.Inductive.PatriciaTree (Gr)
import Data.List (sortBy, foldl')
import Data.Maybe (fromJust, fromMaybe)
import qualified Data.ByteString as B
import Data.Ord (comparing)
import qualified Data.Map as M
import Text.Printf (printf)
import Control.Concurrent.Async.Lifted (mapConcurrently)
import           Language.Haskell.TH
import Control.Monad.Catch (try)

import Scientific.Workflow.Types
import Scientific.Workflow.Internal.Builder.Types
import Scientific.Workflow.Internal.DB
import Scientific.Workflow.Internal.Utils (warnMsg, logMsg, runRemote, defaultRemoteOpts, RemoteOpts(..))

-- | Declare a computational node. The function must have the signature:
-- (DBData a, DBData b) => a -> IO b
node :: ToExpQ q
     => PID                  -- ^ node id
     -> q                    -- ^ function
     -> State Attribute ()   -- ^ Attribues
     -> Builder ()
node p fn setAttr = modify $ _1 %~ (newNode:)
  where
    attr = execState setAttr defaultAttribute
    newNode = Node p (toExpQ fn) attr
{-# INLINE node #-}

-- | many-to-one generalized link function
link :: [PID] -> PID -> Builder ()
link xs t = modify $ _2 %~ (zipWith3 Edge xs (repeat t) [0..] ++)
{-# INLINE link #-}

-- | (~>) = link.
(~>) :: [PID] -> PID -> Builder ()
(~>) = link
{-# INLINE (~>) #-}

-- | singleton
path :: [PID] -> Builder ()
path ns = foldM_ f (head ns) $ tail ns
  where
    f a t = link [a] t >> return t
{-# INLINE path #-}

-- | Build the workflow. This function will first create functions defined in
-- the builder. These pieces will then be assembled to form a function that will
-- execute each individual function in a correct order, named $name$.
buildWorkflow :: String     -- ^ Name of the workflow
              -> Builder () -- ^ Builder
              -> Q [Dec]
buildWorkflow workflowName = mkWorkflow workflowName . mkDAG

-- | Build only a part of the workflow that has not been executed. This is used
-- during development for fast compliation.
buildWorkflowPart :: FilePath   -- ^ Path to the db
                  -> String     -- ^ Name of the workflow
                  -> Builder () -- ^ Builder
                  -> Q [Dec]
buildWorkflowPart db wfName b = do
    st <- runIO $ getWorkflowState db
    mkWorkflow wfName $ trimDAG st $ mkDAG b
  where
    getWorkflowState dir = do
        db <- openDB dir
        ks <- getKeys db
        return $ M.fromList $ zip ks $ repeat Success

-- TODO: check the graph is a valid DAG
-- | Contruct a DAG representing the workflow
mkDAG :: Builder () -> DAG
mkDAG builder = mkGraph ns' es'
  where
    ns' = map (\x -> (pid2nid $ _nodePid x, x)) ns
    es' = map (\Edge{..} -> (pid2nid _edgeFrom, pid2nid _edgeTo, _edgeOrd)) es
    (ns, es) = execState builder ([], [])
    pid2nid pid = M.findWithDefault
        (error $ "mkDAG: cannot identify node: " ++ T.unpack pid) pid $
        M.fromListWithKey
            (\k _ _ -> error $ "Multiple declaration for: " ++ T.unpack k) $
            zip (map _nodePid ns) [0..]
{-# INLINE mkDAG #-}

-- | Remove nodes that are executed before from a DAG.
trimDAG :: (M.Map T.Text NodeState) -> DAG -> DAG
trimDAG st dag = gmap revise gr
  where
    revise context@(linkTo, _, nodeLabel, _)
        | shallBuild (_nodePid nodeLabel) && null linkTo = context
        | otherwise = context & _3 %~
            ( \l -> l{_nodeFunction = feedEmptyInput (_nodeFunction l)} )
      where
        feedEmptyInput x = [| (\() -> undefined) >=> $(x) |]
    gr = labnfilter f dag
      where
        f (i, x) = shallBuild (_nodePid x) || any shallBuild children
          where children = map (_nodePid . fromJust . lab dag) $ suc dag i
    shallBuild x = case M.lookup x st of
        Just Success -> False
        _ -> True
{-# INLINE trimDAG #-}


-- Generate codes from a DAG. This function will create functions defined in
-- the builder. These pieces will be assembled to form a function that will
-- execute each individual function in a correct order.
-- Lastly, a function table will be created with the name $name$_function_table.
mkWorkflow :: String   -- name
           -> DAG -> Q [Dec]
mkWorkflow workflowName dag = do
    let expq = connect sinks [| const $ return () |]
    -- define the workflow
    workflows <-
        [d| $(varP $ mkName workflowName) = Workflow dag' pids $expq |]

    return workflows
  where
    dag' = nmap _nodePid dag
    computeNodes = snd $ unzip $ labNodes dag
    pids = M.fromList $ map (\Node{..} -> (_nodePid, _nodeAttr)) computeNodes
    sinks = labNodes $ nfilter ((==0) . outdeg dag) dag

    backTrack (i, Node{..})
        | bSize > 0 = do
            e <- _nodeFunction
            if argIsContextData e
                then connect (fst $ unzip parents)
                        [| mkProcListNWithContext bSize _nodePid $fn' |]
                else connect (fst $ unzip parents)
                        [| mkProcListN bSize _nodePid $fn' |]
        | otherwise = connect (fst $ unzip parents) [| mkProc _nodePid $fn' |]
      where
        parents = map ( \(x, o) -> ((x, fromJust $ lab dag x), o) ) $
            sortBy (comparing snd) $ lpre dag i
        fn' = [| liftProcFunction $_nodeFunction |]
        bSize = _nodeAttr^.batch

    connect [] sink = sink
    connect [source] sink = [| $(backTrack source) >=> $sink |]
    connect sources sink = [| fmap runParallel $expq >=> $sink |]
      where
        expq = foldl' g e0 $ sources
        e0 = [| (pure. pure) $(conE (tupleDataName $ length sources)) |]
        g acc x = [| ((<*>) . fmap (<*>)) $acc $ fmap Parallel $(backTrack x) |]
{-# INLINE mkWorkflow #-}

-- | TODO: Need more work.
argIsContextData :: Exp -> Bool
argIsContextData e = case e of
    LamE [ConP conName _] _ -> getName conName == "ContextData"
    _ -> False
  where
    getName x = snd $ T.breakOnEnd "." $ T.pack $ show x

mkProc :: (DBData a, DBData b)
       => PID -> (a -> ProcState b) -> (Processor a b)
mkProc = mkProcWith (return, runIdentity)
{-# INLINE mkProc #-}

mkProcListN :: (DBData [a], DBData [b])
            => Int -> PID -> (a -> ProcState b) -> (Processor [a] [b])
mkProcListN n pid f = mkProcWith (chunksOf n, concat) pid $
    (mapM :: (a -> ProcState b) -> [a] -> ProcState [b]) f
{-# INLINE mkProcListN #-}

mkProcListNWithContext :: (DBData (ContextData c [a]), DBData [b])
                       => Int -> PID -> (ContextData c a -> ProcState b)
                       -> (Processor (ContextData c [a]) [b])
mkProcListNWithContext n pid f = mkProcWith (toChunks, concat) pid f'
  where
    f' (ContextData c xs) = mapM f $ zipWith ContextData (repeat c) xs
    toChunks (ContextData c xs) = zipWith ContextData (repeat c) $ chunksOf n xs
{-# INLINE mkProcListNWithContext #-}

mkProcWith :: (Traversable t, DBData a, DBData b)
           => (a -> t a, t b -> b) -> PID -> (a -> ProcState b) -> (Processor a b)
mkProcWith (box, unbox) pid f = \input -> do
    wfState <- get
    let (pSt, attr) = M.findWithDefault (error "Impossible") pid $ wfState^.procStatus

    pStValue <- liftIO $ takeMVar pSt
    case pStValue of
        (Fail ex) -> liftIO (putMVar pSt pStValue) >> lift (throwE (pid, ex))
        Success -> liftIO $ do
            putMVar pSt pStValue
            readData pid $ wfState^.db
        Scheduled -> do
            _ <- liftIO $ takeMVar $ wfState^.procParaControl

            liftIO $ logMsg $ printf "%s: running..." pid

            let sendToRemote = fromMaybe (wfState^.remote) (attr^.submitToRemote)
                remoteOpts = defaultRemoteOpts
                    { extraParams = attr^.remoteParam
                    , environment = wfState^.config
                    }
                input' = box input
            result <- try $ unbox <$> if sendToRemote
                then liftIO $ mapConcurrently (runRemote remoteOpts pid) input'
                else mapM f input'  -- disable parallel in local machine due to memory issue
            case result of
                Left ex -> do
                    _ <- liftIO $ do
                        putMVar pSt $ Fail ex
                        _ <- forkIO $ putMVar (wfState^.procParaControl) ()
                        warnMsg $ printf "%s: Failed!" pid
                    lift (throwE (pid, ex))
                Right r -> liftIO $ do
                    saveData pid r $ wfState^.db
                    putMVar pSt Success
                    _ <- forkIO $ putMVar (wfState^.procParaControl) ()
                    logMsg $ printf "%s: Finished." pid
                    return r
        Skip -> liftIO $ putMVar pSt pStValue >> return undefined
        EXE inputData output -> do
            c <- liftIO $ B.readFile inputData
            r <- f $ deserialize c
            liftIO $ B.writeFile output $ serialize r
            liftIO $ putMVar pSt Skip
            return undefined

        -- Read data stored in this node
        Get -> liftIO $ do
            r <- readData pid $ wfState^.db
            B.putStr $ showYaml r
            putMVar pSt Skip
            return r

        -- Replace data stored in this node
        Put inputData -> do
            c <- liftIO $ B.readFile inputData
            r <- return (readYaml c) `asTypeOf` f undefined
            liftIO $ updateData pid r $ wfState^.db
            liftIO $ putMVar pSt Skip
            return r
{-# INLINE mkProcWith #-}