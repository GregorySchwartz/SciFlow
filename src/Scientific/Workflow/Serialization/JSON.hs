{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE UndecidableInstances #-}
module Scientific.Workflow.Serialization.JSON
    (Serializable(..)
    ) where

import Data.Yaml (FromJSON, ToJSON, encode, decode)

import Scientific.Workflow.Serialization

instance (FromJSON a, ToJSON a) => Serializable a where
    serialize = encode
    deserialize = decode
