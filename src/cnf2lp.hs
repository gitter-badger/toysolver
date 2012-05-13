-----------------------------------------------------------------------------
-- |
-- Module      :  cnf2lp
-- Copyright   :  (c) Masahiro Sakai 2011-2012
-- License     :  BSD-style
-- 
-- Maintainer  :  masahiro.sakai@gmail.com
-- Stability   :  experimental
-- Portability :  portable
--
-----------------------------------------------------------------------------
module Main where

import qualified Data.ByteString.Lazy as BS
import Data.Array.IArray
import qualified Data.Set as Set
import qualified Data.Map as Map
import Data.Char
import System.IO
import System.Environment
import System.Exit
import System.Console.GetOpt

import LPFile
import qualified Language.CNF.Parse.ParseDIMACS as DIMACS

cnfToLP :: DIMACS.CNF -> ObjType -> LPFile.LP
cnfToLP cnf objType
  = LP
  { variables = Set.fromList vs
  , dir = dir
  , objectiveFunction = (Nothing, obj)
  , constraints = cs
  , LPFile.bounds = Map.empty
  , integerVariables = Set.empty
  , binaryVariables = Set.fromList vs
  , semiContinuousVariables = Set.empty
  , sos = []
  }
  where
    dir = if objType == ObjMaxZero then OptMin else OptMax
    obj = if objType == ObjNone then [Term 0 (take 1 vs)] else [Term 1 [v] | v <- vs]
    vs = if DIMACS.numVars cnf == 0
         then ["x0"]
         else ["x" ++ show i | i <- [1 .. DIMACS.numVars cnf]]
    cs = do
      cl <- DIMACS.clauses cnf      
      let (lhs,n) = foldr f ([], 0) (elems cl)
      return (Nothing, Nothing, (lhs, Ge, fromIntegral $ 1 - n))
    f :: Int -> (Expr,Integer) -> (Expr,Integer)
    f i (vs,n) =
      if i > 0
      then (Term 1 [v] : vs, n)
      else (Term (-1) [v] : vs, n+1)
      where v = "x" ++ show (abs i)

data Flag
  = Help
  | ObjType ObjType
  deriving Eq

data ObjType = ObjNone | ObjMaxOne | ObjMaxZero
  deriving Eq

options :: [OptDescr Flag]
options =
    [ Option ['h'] ["help"] (NoArg Help)                       "show help"
    , Option []    ["obj"]  (ReqArg (ObjType . parseObjType) "STRING") "none (default), max-one, max-zero"
    ]
  where
    parseObjType s =
      case map toLower s of
        "none"     -> ObjNone
        "max-one"  -> ObjMaxOne
        "max-zero" -> ObjMaxZero
        _          -> error ("unknown obj: " ++ s)

main :: IO ()
main = do
  args <- getArgs
  case getOpt Permute options args of
    (o,_,[])
      | Help `elem` o -> putStrLn (usageInfo header options)
    (o,[fname],[]) -> do
      ret <- case fname of
               "-" -> fmap (DIMACS.parseByteString "-") $ BS.hGetContents stdin
               _   -> DIMACS.parseFile fname
      case ret of
        Left err -> hPrint stderr err >> exitFailure
        Right cnf -> do
          let objType = last (ObjNone : [t | ObjType t <- o])
          case LPFile.render (cnfToLP cnf objType) of
            Nothing -> hPutStrLn stderr "conversion failure" >> exitFailure
            Just s2 -> putStr s2
    (o,_,errs) ->
      hPutStrLn stderr $ concat errs ++ usageInfo header options

header :: String
header = "Usage: dimacs2lp [file.cnf|-]"