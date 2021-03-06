{-# OPTIONS_GHC -Wall #-}
-----------------------------------------------------------------------------
-- |
-- Module      :  ToySolver.Converter.MaxSAT2NLPB
-- Copyright   :  (c) Masahiro Sakai 2013
-- License     :  BSD-style
-- 
-- Maintainer  :  masahiro.sakai@gmail.com
-- Stability   :  experimental
-- Portability :  portable
--
-----------------------------------------------------------------------------
module ToySolver.Converter.MaxSAT2NLPB
  ( convert
  ) where

import qualified Data.PseudoBoolean as PBFile
import qualified ToySolver.Text.MaxSAT as MaxSAT

convert :: MaxSAT.WCNF -> PBFile.Formula
convert
  MaxSAT.WCNF
  { MaxSAT.topCost = top
  , MaxSAT.clauses = cs
  , MaxSAT.numVars = nv
  } =
  PBFile.Formula
  { PBFile.pbObjectiveFunction = Just obj
  , PBFile.pbConstraints = cs2
  , PBFile.pbNumVars = nv
  , PBFile.pbNumConstraints = length cs2
  }
  where
    obj = [(w, [-l | l <- ls]) | (w,ls) <- cs, w /= top]
    cs2 = [([(1,[l]) | l <- ls], PBFile.Ge, 1) | (w,ls) <- cs, w == top]
