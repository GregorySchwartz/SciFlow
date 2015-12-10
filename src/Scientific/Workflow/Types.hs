{-# LANGUAGE GADTs #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE TemplateHaskell #-}

module Scientific.Workflow.Types
    ( WorkflowDB(..)
    , Workflow(..)
    , PID
    , ProcState(..)
    , WorkflowState(..)
    , db
    , procStatus
    , Processor
    , RunOpt(..)
    , dbPath
    , Serializable(..)
    , Attribute(..)
    , note
    , def
    ) where

import Control.Lens (makeLenses)
import           Control.Monad.State
import qualified Data.ByteString     as B
import qualified Data.Map            as M
import qualified Data.Text           as T
import Data.Maybe (fromJust)
import Data.Yaml (FromJSON, ToJSON, encode, decode)

class Serializable a where
    serialize :: a -> B.ByteString
    deserialize :: B.ByteString -> a

instance (FromJSON a, ToJSON a) => Serializable a where
    serialize = encode
    deserialize = fromJust . decode


data WorkflowDB  = WorkflowDB FilePath

type PID = T.Text

data ProcState = Finished
               | Scheduled

data WorkflowState = WorkflowState
    { _db         :: WorkflowDB
    , _procStatus :: M.Map PID ProcState
    }

makeLenses ''WorkflowState

type Processor a b = a -> StateT WorkflowState IO b

data Workflow where
    Workflow :: (Processor () o) -> Workflow

data RunOpt = RunOpt
    { _dbPath :: FilePath
    }

makeLenses ''RunOpt

data Attribute = Attribute
    { _note :: T.Text
    }

makeLenses ''Attribute

def :: State a ()
def = return ()
