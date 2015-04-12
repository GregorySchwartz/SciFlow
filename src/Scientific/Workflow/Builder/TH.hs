{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE OverloadedStrings #-}
module Scientific.Workflow.Builder.TH where

import Language.Haskell.TH

import Control.Arrow ((>>>))
import Control.Monad.State
import qualified Data.HashMap.Strict as M

import Scientific.Workflow.Types
import Scientific.Workflow.Builder

mkWorkflow :: String -> Builder () -> Q [Dec]
mkWorkflow name st = do
    nodeDec <- declareNodes nd
    wfDec <- [d| $(varP $ mkName name) = $(fmap ListE $ mapM (`linkNodes` m) endNodes) |]
    return $ nodeDec ++ wfDec
  where
    builder = execState st $ B [] []
    endNodes = map (\x -> M.lookupDefault undefined x m) . leaves . fromUnits . snd . unzip . _links $ builder
    m = M.fromList $ _links builder
    nd = map (\(a,b,_) -> (a,b)) $ _nodes builder

declareNodes :: [(String, String)] -> Q [Dec]
declareNodes nodes = do d <- mapM f nodes
                        return $ concat d
  where
    f (l, ar) = [d| $(varP $ mkName l) = proc l $(varE $ mkName ar) |]
{-# INLINE declareNodes #-}

linkNodes :: Unit -> M.HashMap String Unit -> Q Exp
linkNodes nd m = [| Workflow $(go nd) |]
  where
    lookup' x = M.lookupDefault (S x) x m
    go (S a)          = varE $ mkName a
    go (L a t)        = [| $(go $ lookup' a) >>> $(go $ S t) |]
    go (L2 (a,b) t)   = [| zipS  $(go $ lookup' a) 
                                 $(go $ lookup' b)
                             >>> $(go $ S t) |]
    go (L3 (a,b,c) t) = [| zipS3 $(go $ lookup' a)
                                 $(go $ lookup' b)
                                 $(go $ lookup' c)
                             >>> $(go $ S t) |]
{-# INLINE linkNodes #-}
