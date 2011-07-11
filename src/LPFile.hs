{-# OPTIONS_GHC -Wall -fno-warn-unused-do-bind #-}
-----------------------------------------------------------------------------
-- |
-- Module      :  LPFile
-- Copyright   :  (c) Masahiro Sakai 2011
-- License     :  BSD-style
-- 
-- Maintainer  :  masahiro.sakai@gmail.com
-- Stability   :  provisional
-- Portability :  portable
--
-- A CPLEX .lp format parser library.
-- 
-- References:
-- http://publib.boulder.ibm.com/infocenter/cosinfoc/v12r2/index.jsp?topic=/ilog.odms.cplex.help/Content/Optimization/Documentation/CPLEX/_pubskel/CPLEX880.html
-- http://www.gurobi.com/doc/45/refman/node589.html
-- http://lpsolve.sourceforge.net/5.5/CPLEX-format.htm
--
-----------------------------------------------------------------------------
module LPFile
  ( LP (..)
  , Expr (..)
  , ObjectiveFunction
  , Constraint
  , Bounds
  , Label
  , Var
  , BoundExpr (..)
  , RelOp (..)
  , SOSType (..)
  , SOS
  , defaultBounds
  , getBounds
  , parseString
  , parseFile
  , render
  ) where

import Control.Monad
import Control.Monad.Writer
import Data.Char
import Data.Maybe
import Data.Ratio
import qualified Data.Map as Map
import qualified Data.Set as Set
import Text.ParserCombinators.Parsec hiding (label)

import Util (combineMaybe)

-- ---------------------------------------------------------------------------

data LP
  = LP
  { variables :: Set.Set Var
  , isMinimize :: Bool
  , objectiveFunction :: ObjectiveFunction
  , constraints :: [Constraint]
  , bounds :: Map.Map Var Bounds
  , integerVariables :: Set.Set Var
  , binaryVariables :: Set.Set Var
  , semiContinuousVariables :: Set.Set Var
  , sos :: [SOS]
  }
  deriving (Show, Eq, Ord)

data Expr
  = Const Rational
  | Var Var
  | Expr :+: Expr
  | Expr :*: Expr
  | Expr :/: Expr
  deriving (Eq, Ord, Show)

type ObjectiveFunction = (Maybe Label, Expr)
type Constraint = (Maybe Label, Maybe (Var, Rational), (Expr, RelOp, Rational))
type Bounds = (BoundExpr, BoundExpr)
type Label = String
type Var = String
data BoundExpr = NegInf | Finite Rational | PosInf
    deriving (Eq, Ord, Show)
data RelOp = Le | Ge | Eql
    deriving (Eq, Ord, Enum, Show)
data SOSType = S1 | S2
    deriving (Eq, Ord, Enum, Show, Read)
type SOS = (Maybe Label, SOSType, [(Var, Rational)])

class Variables a where
  vars :: a -> Set.Set Var

instance Variables a => Variables [a] where
  vars = Set.unions . map vars

instance Variables LP where
  vars = variables

instance Variables Expr where
  vars (Const _) = Set.empty
  vars (Var v) = Set.singleton v
  vars (a :+: b) = vars a `Set.union` vars b
  vars (a :*: b) = vars a `Set.union` vars b
  vars (a :/: b) = vars a `Set.union` vars b

defaultBounds :: Bounds
defaultBounds = (Finite 0, PosInf)

getBounds :: LP -> Var -> Bounds
getBounds lp v = fromMaybe defaultBounds (Map.lookup v (bounds lp))

-- ---------------------------------------------------------------------------

parseString :: SourceName -> String -> Either ParseError LP
parseString = parse lpfile

parseFile :: FilePath -> IO (Either ParseError LP)
parseFile = parseFromFile lpfile

-- ---------------------------------------------------------------------------

char' :: Char -> Parser Char
char' c = (char c <|> char (toUpper c)) <?> show c

string' :: String -> Parser ()
string' s = mapM_ char' s <?> show s

sep :: Parser ()
sep = skipMany ((comment >> return ()) <|> (space >> return ()))

comment :: Parser String
comment = do
  char '\\'
  manyTill anyChar (try newline)

tok :: Parser a -> Parser a
tok p = do
  x <- p
  sep
  return x

ident :: Parser String
ident = tok $ do
  x <- letter <|> oneOf syms1 
  xs <- many (alphaNum <|> oneOf syms2)
  let s = x:xs 
  guard $ map toLower s `Set.notMember` reserved
  return s
  where
    syms1 = "!\"#$%&()/,;?@_`'{}|~"
    syms2 = '.' : syms1

label :: Parser Label
label = do
  name <- ident
  tok $ char ':'
  return name

reserved :: Set.Set String
reserved = Set.fromList
  [ "bound", "bounds"
  , "gen", "general", "generals"
  , "bin", "binary", "binaries"
  , "semi", "semi-continuous", "semis"
  , "sos"
  , "end"
  ]

-- ---------------------------------------------------------------------------

lpfile :: Parser LP
lpfile = do
  sep
  (flag, obj) <- problem
  cs <- constraintSection
  bnds <- option Map.empty (try boundsSection)
  xs <- many (liftM Left generalSection <|> liftM Right binarySection)
  let ints = Set.fromList $ concat [x | Left  x <- xs]
      bins = Set.fromList $ concat [x | Right x <- xs]
  scs <- liftM Set.fromList $ option [] (try semiSection)
  ss <- option [] (try sosSection)
  end
  let f (_, _, (e, _, _)) = vars e
      vs = Set.unions $ map f cs ++
           [ Map.keysSet bnds
           , ints
           , bins
           , scs
           , vars (snd obj)
           ] ++
           [Set.fromList (map fst xs) | (_,_,xs) <- ss]
  return $ LP vs flag obj cs bnds ints bins scs ss

problem :: Parser (Bool, ObjectiveFunction)
problem = do
  flag <-  (try minimize >> return True)
       <|> (try maximize >> return False)
  name <- optionMaybe (try label)
  obj <- expr
  return (flag, (name, obj))

minimize, maximize :: Parser ()
minimize = tok $ string' "min" >> optional (string' "imize")
maximize = tok $ string' "max" >> optional (string' "imize")

end :: Parser ()
end = tok $ string' "end"

-- ---------------------------------------------------------------------------

constraintSection :: Parser [Constraint]
constraintSection = subjectTo >> many (try constraint)

subjectTo :: Parser ()
subjectTo = msum
  [ try $ tok (string' "subject") >> tok (string' "to")
  , try $ tok (string' "such") >> tok (string' "that")
  , try $ tok (string' "st")
  , try $ tok (string' "s") >> optional (tok (char '.')) >> tok (string' "t")
        >> tok (char '.') >> return ()
  ]

constraint :: Parser Constraint
constraint = do
  name <- optionMaybe (try label)

  g <- optionMaybe $ try $ do
    var <- ident
    tok (char '=')
    val <- tok ((char '0' >> return 0) <|> (char '1' >> return 1))
    tok $ string "->"
    return (var, val)

  -- It seems that CPLEX allows empty lhs, but GLPK rejects it.
  e <- try expr <|> return (Const 0)
  op <- relOp
  s <- option 1 sign
  rhs <- number
  return (name, g, (e, op, s*rhs))

relOp :: Parser RelOp
relOp = tok $ msum
  [ char '<' >> optional (char '=') >> return Le
  , char '>' >> optional (char '=') >> return Ge
  , char '=' >> msum [ char '<' >> return Le
                     , char '>' >> return Ge
                     , return Eql
                     ]
  ]

type Bounds2 = (Maybe BoundExpr, Maybe BoundExpr)

boundsSection :: Parser (Map.Map Var Bounds)
boundsSection = do
  tok $ string' "bound" >> optional (char 's')
  liftM (Map.map g . Map.fromListWith f) $ many (try bound)
  where
    f (lb1,ub1) (lb2,ub2) = (combineMaybe max lb1 lb2, combineMaybe min ub1 ub2)
    g (lb, ub) = ( fromMaybe (fst defaultBounds) lb
                 , fromMaybe (snd defaultBounds) ub
                 )

bound :: Parser (Var, Bounds2)
bound = msum
  [ try $ do
      v <- try ident
      msum
        [ do
            op <- relOp
            b <- boundExpr
            return
              ( v
              , case op of
                  Le -> (Nothing, Just b)
                  Ge -> (Just b, Nothing)
                  Eql -> (Just b, Just b)
              )
        , do
            tok $ string' "free"
            return (v, (Just NegInf, Just PosInf))
        ]
  , do
      b1 <- liftM Just boundExpr
      op1 <- relOp
      guard $ op1 == Le
      v <- ident
      b2 <- option Nothing $ do
        op2 <- relOp
        guard $ op2 == Le
        liftM Just boundExpr
      return (v, (b1, b2))
  ]

boundExpr :: Parser BoundExpr
boundExpr = msum 
  [ try (tok (char '+') >> inf >> return PosInf)
  , try (tok (char '-') >> inf >> return NegInf)
  , do
      s <- option 1 sign
      x <- number
      return $ Finite (s*x)
  ]

inf :: Parser ()
inf = tok (string "inf" >> optional (string "inity"))

-- ---------------------------------------------------------------------------

generalSection :: Parser [Var]
generalSection = do
  tok $ string' "gen" >> optional (string' "eral" >> optional (string' "s"))
  many (try ident)

binarySection :: Parser [Var]
binarySection = do
  tok $ string' "bin" >> optional (string' "ar" >> (string' "y" <|> string' "ies"))
  many (try ident)

semiSection :: Parser [Var]
semiSection = do
  tok $ string' "semi" >> optional (string' "-continuous" <|> string' "s")
  many (try ident)

sosSection :: Parser [SOS]
sosSection = do
  tok $ string' "sos"
  many $ try $ do
    (l,t) <- try (do{ l <- label; t <- typ; return (Just l, t) })
          <|> (do{ t <- typ; return (Nothing, t) })
    xs <- many $ try $ do
      v <- ident
      tok $ char ':'
      w <- number
      return (v,w)
    return (l,t,xs)
  where
    typ = do
      t <- tok $ (char' 's' >> ((char '1' >> return S1) <|> (char '2' >> return S2)))
      tok (string "::")
      return t

-- ---------------------------------------------------------------------------

expr :: Parser Expr
expr = do
  t <- term True
  ts <- many (term False)
  return (foldl (:+:) t ts)

sign :: Num a => Parser a
sign = tok ((char '+' >> return 1) <|> (char '-' >> return (-1)))

term :: Bool -> Parser Expr
term flag = do
  s <- if flag then optionMaybe sign else liftM Just sign
  c <- optionMaybe number
  v <- liftM Var ident <|> qexpr
  return $ case combineMaybe (*) s c of
    Nothing -> v
    Just d -> Const d :*: v

qexpr :: Parser Expr
qexpr = do
  tok (char '[')
  t <- qterm True
  ts <- many (qterm False)
  mapM_ (tok . char) "]/2"
  return (foldl (:+:) t ts :/: Const 2) 

qterm :: Bool -> Parser Expr
qterm flag = do
  s <- if flag then optionMaybe sign else liftM Just sign
  c <- optionMaybe number
  es <- qfactor `chainl1`  (tok (char '*') >> return (:*:))
  return $ case combineMaybe (*) s c of
    Nothing -> es
    Just d -> Const d :*: es

qfactor :: Parser Expr
qfactor = do
  v <- liftM Var ident
  msum [ tok (char '^') >> tok (char '2') >> return (v :*: v)
       , return v
       ]

number :: Parser Rational
number = tok $ do
  b <- (do{ x <- nat; y <- option 0 frac; return (fromInteger x + y) })
    <|> frac
  c <- option 0 e
  return (b*10^^c)
  where
    digits = many1 digit

    nat :: Parser Integer
    nat = liftM read digits

    frac :: Parser Rational
    frac = do
      char '.'
      s <- digits
      return (read s % 10^(length s))

    e :: Parser Integer
    e = do
      oneOf "eE"
      f <- msum [ char '+' >> return id
                , char '-' >> return negate
                , return id
                ]
      liftM f nat

-- ---------------------------------------------------------------------------

render :: LP -> Maybe String
render lp = fmap ($ "") $ execWriterT (render' lp)

render' :: LP -> WriterT ShowS Maybe ()
render' lp = do
  tell $ showString $ if isMinimize lp then "MINIMIZE" else "MAXIMIZE"
  tell $ showChar '\n'

  let (l, obj) = objectiveFunction lp
  renderLabel l
  renderExpr obj
  tell $ showChar '\n'

  tell $ showString "SUBJECT TO\n"

  forM_ (constraints lp) $ \(l, cond, (e, op, val)) -> do
    renderLabel l
    case cond of
      Nothing -> return ()
      Just (v,val) -> do
        tell $ showString v . showString " = "
        renderValue val
        tell $ showString " -> "

    renderExpr e
    tell $ showChar ' '
    renderOp op
    tell $ showChar ' '
    renderValue val
    tell $ showChar '\n'

  tell $ showString "BOUNDS\n"
  forM_ (Map.toAscList (bounds lp)) $ \(v, b@(lb,ub)) -> do
    renderBoundExpr lb
    tell $ showString " <= "
    tell $ showString v
    tell $ showString " <= "
    renderBoundExpr ub
    tell $ showChar '\n'

  unless (Set.null (integerVariables lp)) $ do
    tell $ showString "GENERALS\n"
    forM_ (Set.toList (integerVariables lp)) $ \v -> do
      tell $ showString v
      tell $ showChar '\n'

  unless (Set.null (binaryVariables lp)) $ do
    tell $ showString "BINARIES\n"
    forM_ (Set.toList (binaryVariables lp)) $ \v -> do
      tell $ showString v
      tell $ showChar '\n'

  unless (Set.null (semiContinuousVariables lp)) $ do
    tell $ showString "SEMI-CONTINUOUS\n"
    forM_ (Set.toList (semiContinuousVariables lp)) $ \v -> do
      tell $ showString v
      tell $ showChar '\n'

  unless (null (sos lp)) $ do
    tell $ showString "SOS\n"
    forM_ (sos lp) $ \(l, typ, xs) -> do
      renderLabel l
      tell $ shows typ
      tell $ showString " ::"
      forM_ xs $ \(v, r) -> do
        tell $ showString "  "
        tell $ showString v
        tell $ showString " : "
        renderValue r
      tell $ showChar '\n'

  tell $ showString "END\n"

renderExpr :: Expr -> WriterT ShowS Maybe ()
renderExpr e = do
  e' <- lift $ liftM (Map.filter (0/=)) $ compileExpr e
  forM_ (Map.toAscList e') $ \(v,c) -> do
    tell $ showString $ if c >= 0 then " + " else " - "
    let c' = abs c
    when (c' /= 1) $ do
      renderValue c'
      tell $ showChar ' '
    tell $ showString v

renderValue :: Rational -> WriterT ShowS Maybe ()
renderValue c =
  if denominator c == 1
    then tell $ shows (numerator c)
    else tell $ shows (fromRational c :: Double)

renderLabel :: Maybe Label -> WriterT ShowS Maybe ()
renderLabel l =
  case l of
    Nothing -> return ()
    Just s -> tell $ showString s . showString ": "

renderOp :: RelOp -> WriterT ShowS Maybe ()
renderOp Le = tell $ showString "<="
renderOp Ge = tell $ showString ">="
renderOp Eql = tell $ showString "="

renderBoundExpr :: BoundExpr -> WriterT ShowS Maybe ()
renderBoundExpr (Finite r) = renderValue r
renderBoundExpr NegInf = tell $ showString "-inf"
renderBoundExpr PosInf = tell $ showString "+inf"

-- ---------------------------------------------------------------------------

-- LC.hs にほぼ同じものがある
asConst :: Map.Map Var Rational -> Maybe Rational
asConst m =
  case Map.toList m of
    [] -> Just 0
    [("",x)] -> Just x
    _ -> Nothing

-- LA.hs にほぼ同じものがある
compileExpr :: Expr -> Maybe (Map.Map Var Rational)
compileExpr (Const c) = return $ Map.singleton "" c
compileExpr (Var c) = return $ Map.singleton c 1
compileExpr (a :+: b) = liftM2 (Map.unionWith (+)) (compileExpr a) (compileExpr b)
compileExpr (a :*: b) = do
  x <- compileExpr a
  y <- compileExpr b
  msum [ do{ c <- asConst x; return (fmap (c*) y) }
       , do{ c <- asConst y; return (fmap (c*) x) }
       ]
compileExpr (a :/: b) = do
  x <- compileExpr a
  c <- asConst =<< compileExpr b
  return $ fmap (/c) x

-- ---------------------------------------------------------------------------

testdata :: String
testdata = unlines
  [ "Maximize"
  , " obj: x1 + 2 x2 + 3 x3 + x4"
  , "Subject To"
  , " c1: - x1 + x2 + x3 + 10 x4 <= 20"
  , " c2: x1 - 3 x2 + x3 <= 30"
  , " c3: x2 - 3.5 x4 = 0"
  , "Bounds"
  , " 0 <= x1 <= 40"
  , " 2 <= x4 <= 3"
  , "General"
  , " x4"
  , "End"
  ]

test :: Either ParseError LP
test = parseString "test" testdata

testRender :: IO ()
testRender =
  case test of
    Right lp ->
      case render lp of
        Nothing -> putStrLn "render failure"
        Just s -> putStr s
    Left s -> putStrLn (show s)

-- ---------------------------------------------------------------------------