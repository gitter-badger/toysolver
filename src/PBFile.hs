-----------------------------------------------------------------------------
-- |
-- Module      :  PBFile
-- Copyright   :  (c) Masahiro Sakai 2011
-- License     :  BSD-style
-- 
-- Maintainer  :  masahiro.sakai@gmail.com
-- Portability :  portable
--
-- A parser library for .opb file and .wbo files used by PB Competition.
-- 
-- References:
-- Input/Output Format and Solver Requirements for the Competitions of
-- Pseudo-Boolean Solvers
-- http://www.cril.univ-artois.fr/PB11/format.pdf
--
-----------------------------------------------------------------------------

module PBFile
  ( Formula
  , Constraint
  , Op (..)
  , SoftFormula
  , SoftConstraint
  , Sum
  , WeightedTerm
  , Term
  , Lit (..)
  , Var
  , parseOPBString
  , parseOPBFile
  , parseWBOString
  , parseWBOFile
  ) where

import Prelude hiding (sum)
import Control.Monad
import Data.Maybe
import Text.ParserCombinators.Parsec

type Formula = (Maybe Sum, [Constraint])
type Constraint = (Sum, Op, Integer)
data Op = Ge | Eq deriving (Eq, Ord, Show, Enum, Bounded)

type SoftFormula = (Maybe Integer, [SoftConstraint])
type SoftConstraint = (Maybe Integer, Constraint)

type Sum = [WeightedTerm]
type WeightedTerm = (Integer, Term)
type Term = [Lit]
data Lit = Pos Var | Neg Var deriving (Eq, Ord, Show)
type Var = Int

-- <formula>::= <sequence_of_comments> [<objective>] <sequence_of_comments_or_constraints>
formula :: Parser Formula
formula = do
  sequence_of_comments
  obj <- optionMaybe objective
  cs <- sequence_of_comments_or_constraints
  return (obj, cs)

-- <sequence_of_comments>::= <comment> [<sequence_of_comments>]
sequence_of_comments :: Parser ()
sequence_of_comments = skipMany1 comment

-- <comment>::= "*" <any_sequence_of_characters_other_than_EOL> <EOL>
comment :: Parser ()
comment = do
  _ <- char '*' 
  _ <- manyTill anyChar eol
  return ()

-- <sequence_of_comments_or_constraints>::= <comment_or_constraint> [<sequence_of_comments_or_constraints>]
sequence_of_comments_or_constraints :: Parser [Constraint]
sequence_of_comments_or_constraints = do
  xs <- many1 comment_or_constraint
  return $ catMaybes xs

-- <comment_or_constraint>::= <comment>|<constraint>
comment_or_constraint :: Parser (Maybe Constraint)
comment_or_constraint =
  (comment >> return Nothing) <|> (liftM Just constraint)

-- <objective>::= "min:" <zeroOrMoreSpace> <sum> ";"
objective :: Parser Sum
objective = do
  _ <- string "min:"
  zeroOrMoreSpace
  obj <- sum
  _ <- char ';'
  eol
  return obj

-- <constraint>::= <sum> <relational_operator> <zeroOrMoreSpace> <integer> <zeroOrMoreSpace> ";"
constraint :: Parser Constraint
constraint = do
  lhs <- sum
  op <- relational_operator
  zeroOrMoreSpace
  rhs <- integer
  zeroOrMoreSpace
  semi
  return (lhs, op, rhs)

-- <sum>::= <weightedterm> | <weightedterm> <sum>
sum :: Parser Sum
sum = many1 weightedterm

-- <weightedterm>::= <integer> <oneOrMoreSpace> <term> <oneOrMoreSpace>
weightedterm :: Parser WeightedTerm
weightedterm = do
  w <- integer
  oneOrMoreSpace
  t <- term
  oneOrMoreSpace
  return (w,t)

-- <integer>::= <unsigned_integer> | "+" <unsigned_integer> | "-" <unsigned_integer>
integer :: Parser Integer
integer = msum
  [ unsigned_integer
  , char '+' >> unsigned_integer
  , char '-' >> liftM negate unsigned_integer
  ]

-- <unsigned_integer>::= <digit> | <digit><unsigned_integer>
unsigned_integer :: Parser Integer
unsigned_integer = liftM read (many1 digit)  

-- <relational_operator>::= ">=" | "="
relational_operator :: Parser Op
relational_operator = (string ">=" >> return Ge) <|> (string "=" >> return Eq)

-- <variablename>::= "x" <unsigned_integer>
variablename :: Parser Var
variablename = do
  _ <- char 'x'
  i <- unsigned_integer
  return $! fromIntegral i

-- <oneOrMoreSpace>::= " " [<oneOrMoreSpace>]
oneOrMoreSpace :: Parser ()
oneOrMoreSpace  = skipMany1 (char ' ')

-- <zeroOrMoreSpace>::= [" " <zeroOrMoreSpace>]
zeroOrMoreSpace :: Parser ()
zeroOrMoreSpace = skipMany (char ' ')

eol :: Parser ()
eol = char '\n' >> return ()

semi :: Parser ()
semi = char ';' >> eol

{-
For linear pseudo-Boolean instances, <term> is defined as
<term>::=<variablename>

For non-linear instances, <term> is defined as
<term>::= <oneOrMoreLiterals>
-}
term :: Parser Term
term = oneOrMoreLiterals

-- <oneOrMoreLiterals>::= <literal> | <literal> <oneOrMoreSpace> <oneOrMoreLiterals>
oneOrMoreLiterals :: Parser [Lit]
oneOrMoreLiterals = do
  l <- literal
  mplus (try $ oneOrMoreSpace >> liftM (l:) (oneOrMoreLiterals)) (return [l])
-- Note that we cannot use sepBy1.
-- In "p `sepBy1` q", p should success whenever q success.
-- But it's not the case here.

-- <literal>::= <variablename> | "~"<variablename>
literal :: Parser Lit
literal = (liftM Pos variablename) <|> (char '~' >> liftM Neg variablename)

parseOPBString :: SourceName -> String -> Either ParseError Formula
parseOPBString = parse formula

parseOPBFile :: FilePath -> IO (Either ParseError Formula)
parseOPBFile = parseFromFile formula


-- <softformula>::= <sequence_of_comments> <softheader> <sequence_of_comments_or_constraints>
softformula :: Parser SoftFormula
softformula = do
  sequence_of_comments
  top <- softheader
  cs <- wbo_sequence_of_comments_or_constraints
  return (top, cs)

-- <softheader>::= "soft:" [<unsigned_integer>] ";"
softheader :: Parser (Maybe Integer)
softheader = do
  _ <- string "soft:"
  zeroOrMoreSpace -- XXX
  top <- optionMaybe unsigned_integer
  zeroOrMoreSpace -- XXX
  semi
  return top

-- <sequence_of_comments_or_constraints>::= <comment_or_constraint> [<sequence_of_comments_or_constraints>]
wbo_sequence_of_comments_or_constraints :: Parser [SoftConstraint]
wbo_sequence_of_comments_or_constraints = do
  xs <- many1 wbo_comment_or_constraint
  return $ catMaybes xs

-- <comment_or_constraint>::= <comment>|<constraint>|<softconstraint>
wbo_comment_or_constraint :: Parser (Maybe SoftConstraint)
wbo_comment_or_constraint = (comment >> return Nothing) <|> m
  where
    m = liftM Just $ (constraint >>= \c -> return (Nothing, c)) <|> softconstraint

-- <softconstraint>::= "[" <zeroOrMoreSpace> <unsigned_integer> <zeroOrMoreSpace> "]" <constraint>
softconstraint :: Parser SoftConstraint
softconstraint = do
  _ <- char '['
  zeroOrMoreSpace
  cost <- unsigned_integer
  zeroOrMoreSpace
  _ <- char ']'
  zeroOrMoreSpace -- XXX
  c <- constraint
  return (Just cost, c)

parseWBOString :: SourceName -> String -> Either ParseError SoftFormula
parseWBOString = parse softformula

parseWBOFile :: FilePath -> IO (Either ParseError SoftFormula)
parseWBOFile = parseFromFile softformula




exampleLIN :: String
exampleLIN = unlines
  [ "* #variable= 5 #constraint= 4"
  , "*"
  , "* this is a dummy instance"
  , "*"
  , "min: 1 x2 -1 x3 ;"
  , "1 x1 +4 x2 -2 x5 >= 2;"
  , "-1 x1 +4 x2 -2 x5 >= +3;"
  , "12345678901234567890 x4 +4 x3 >= 10;"
  , "* an equality constraint"
  , "2 x2 +3 x4 +2 x1 +3 x5 = 5;"
  ]

exampleNLC1 :: String
exampleNLC1 = unlines
  [ "* #variable= 5 #constraint= 4 #product= 5 sizeproduct= 13"
  , "*"
  , "* this is a dummy instance"
  , "*"
  , "min: 1 x2 x3 -1 x3 ;"
  , "1 x1 +4 x1 ~x2 -2 x5 >= 2;"
  , "-1 x1 +4 x2 -2 x5 >= 3;"
  , "12345678901234567890 x4 +4 x3 >= 10;"
  , "2 x2 x3 +3 x4 ~x5 +2 ~x1 x2 +3 ~x1 x2 x3 ~x4 ~x5 = 5 ;"
  ]

exampleNLC2 :: String
exampleNLC2 = unlines
  [ "* #variable= 6 #constraint= 3 #product= 9 sizeproduct= 18"
  , "*"
  , "* Factorization problem: find the smallest P such that P*Q=N"
  , "* P is a 3 bits number (x3 x2 x1)"
  , "* Q is a 3 bits number (x6 x5 x4)"
  , "* N=35"
  , "* "
  , "* minimize the value of P"
  , "min: +1 x1 +2 x2 +4 x3 ;"
  , "* P>=2 (to avoid trivial factorization)"
  , "+1 x1 +2 x2 +4 x3 >=2;"
  , "* Q>=2 (to avoid trivial factorization)"
  , "+1 x4 +2 x5 +4 x6 >=2;"
  , "*"
  , "* P*Q=N"
  , "+1 x1 x4 +2 x1 x5 +4 x1 x6 +2 x2 x4 +4 x2 x5 +8 x2 x6 +4 x3 x4 +8 x3 x5 +16 x3 x6 = 35;"
  ]

exampleWBO1 :: String
exampleWBO1 = unlines $
  [ "* #variable= 1 #constraint= 2 #soft= 2 mincost= 2 maxcost= 3 sumcost= 5"
  , "soft: 6 ;"
  , "[2] +1 x1 >= 1 ;"
  , "[3] -1 x1 >= 0 ;"
  ]

exampleWBO2 :: String
exampleWBO2 = unlines $
  [ "* #variable= 2 #constraint= 3 #soft= 2 mincost= 2 maxcost= 3 sumcost= 5"
  , "soft: 6 ;"
  , "[2] +1 x1 >= 1 ;"
  , "[3] +1 x2 >= 1 ;"
  , "-1 x1 -1 x2 >= -1 ;"
  ]

exampleWBO3 :: String
exampleWBO3 = unlines $
  [ "* #variable= 4 #constraint= 6 #soft= 4 mincost= 2 maxcost= 5 sumcost= 14"
  , "soft: 6 ;"
  , "[2] +1 x1 >= 1;"
  , "[3] +1 x2 >= 1;"
  , "[4] +1 x3 >= 1;"
  , "[5] +1 x4 >= 1;"
  , "-1 x1 -1 x2 >= -1 ;"
  , "-1 x3 -1 x4 >= -1 ;"
  ]