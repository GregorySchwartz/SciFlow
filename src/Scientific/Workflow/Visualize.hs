{-# LANGUAGE OverloadedStrings #-}
module Scientific.Workflow.Visualize
    ( renderBuilder
    ) where

import Control.Lens
import Scientific.Workflow.Types (label)
import qualified Data.Text as T
import qualified Data.Text.Lazy      as TL

import Data.GraphViz
import Data.GraphViz.Printing
import Data.GraphViz.Attributes.Complete

import Scientific.Workflow.Types (note)
import Scientific.Workflow.Builder

-- | Print the computation graph
renderBuilder :: Builder () -> TL.Text
renderBuilder b = renderDot . toDot $ graphToDot param dag
  where
    fmtnode (_, (p, (_, attr))) = [Label $ StrLabel $ TL.fromStrict lab]
      where
        lab | T.null (attr^.label) = p
            | otherwise = attr^.label
    dag = mkDAG b
    param = nonClusteredParams{fmtNode = fmtnode}
