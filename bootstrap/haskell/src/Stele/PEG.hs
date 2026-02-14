{-# LANGUAGE BangPatterns #-}
-- | A PEG-based packrat parser generator, built from first principles.
--
-- This module provides a complete Parsing Expression Grammar (PEG) engine
-- with memoized recursive descent — commonly known as /packrat parsing/.
-- Grammars are first-class Haskell values: a 'Grammar' is simply a
-- @'Data.Map.Map' 'String' 'PExpr'@ mapping rule names to parsing expressions.
-- Call 'parse' to transform input text into a concrete 'ParseTree'.
--
-- = Design
--
-- The parser is built entirely from scratch with no external parser libraries.
-- Input is stored in an 'Data.Array.Array' for O(1) character access. A memo
-- table (keyed by @(position, rule name)@) ensures each @(position, rule)@
-- pair is computed at most once, giving worst-case O(n) parsing for
-- well-structured grammars.
--
-- Error reporting uses furthest-position tracking: the parser records the
-- deepest input position reached and what was expected there, producing
-- informative messages on failure.
--
-- = Usage
--
-- Build a grammar using the combinator EDSL, then call 'parse':
--
-- @
-- import qualified Data.Map.Strict as Map
-- import Stele.PEG
--
-- myGrammar :: Grammar
-- myGrammar = Map.fromList
--   [ (\"number\", 'many1' ('satisfy' \"digit\" isDigit))
--   , (\"expr\",   'rule' \"number\" '<.>' 'many' ('lit' \"+\" '<.>' 'rule' \"number\"))
--   ]
--
-- result = 'parse' myGrammar \"3+42\" \"expr\"
-- -- Right (PTNode \"expr\" [...])
-- @
--
-- = PEG Semantics
--
-- PEG choice ('PChoice', '</>') is /ordered/: the first alternative that
-- matches wins. This eliminates ambiguity by construction — PEGs never
-- produce multiple parse trees. Repetition ('PStar', 'PPlus') is greedy.
-- Lookahead operators ('PAnd', 'PNot') match without consuming input.
module Stele.PEG
  ( -- * Core Types
    PExpr(..)
  , Grammar
  , ParseTree(..)
    -- * Parsing
  , parse
    -- * Combinators (the EDSL)
    -- | Build grammars ergonomically in Haskell. These combinators construct
    -- 'PExpr' values and can be freely composed.

    -- ** Primitives
  , lit, chr, satisfy, anyChar, rule

    -- ** Combinators
  , seq_, choice, many, many1, opt
  , andP, notP, label

    -- ** Operators
  , (<.>), (</>)

    -- ** Common Building Blocks
    -- | Pre-built expressions for whitespace, identifiers, and comments.
  , ws, ws1, digits, letter, letterOrDigit
  ) where

import           Data.Array (Array, (!), listArray, bounds)
import qualified Data.Map.Strict as Map
import           Data.Map.Strict (Map)
import           Data.List (intercalate)

-- ---------------------------------------------------------------------------
-- Core types
-- ---------------------------------------------------------------------------

-- | A Parsing Expression — the atoms and combinators of PEG.
--
-- These form the complete set of PEG operators. Construct them directly
-- or use the combinator functions ('lit', 'seq_', 'choice', etc.).
data PExpr
  = PTerminal  !String              -- ^ Match an exact string
  | PSatisfy   !String (Char -> Bool) -- ^ Match a char satisfying a predicate (name for errors)
  | PAny                             -- ^ Match any single character
  | PSequence  [PExpr]               -- ^ Match all sub-expressions in order
  | PChoice    [PExpr]               -- ^ Ordered choice: try each until one succeeds
  | PStar      PExpr                 -- ^ Zero or more (greedy)
  | PPlus      PExpr                 -- ^ One or more (greedy)
  | POptional  PExpr                 -- ^ Zero or one
  | PAnd       PExpr                 -- ^ Positive lookahead (succeed without consuming)
  | PNot       PExpr                 -- ^ Negative lookahead (succeed if sub-expr fails)
  | PNonTerminal !String             -- ^ Reference a named rule in the grammar
  | PLabel     !String PExpr         -- ^ Label a sub-expression (creates a named node in the tree)

instance Show PExpr where
  show (PTerminal s)    = show s
  show (PSatisfy n _)   = "[" ++ n ++ "]"
  show PAny             = "."
  show (PSequence es)   = "(" ++ unwords (map show es) ++ ")"
  show (PChoice es)     = "(" ++ intercalate " / " (map show es) ++ ")"
  show (PStar e)        = show e ++ "*"
  show (PPlus e)        = show e ++ "+"
  show (POptional e)    = show e ++ "?"
  show (PAnd e)         = "&" ++ show e
  show (PNot e)         = "!" ++ show e
  show (PNonTerminal s) = s
  show (PLabel n _)     = "<" ++ n ++ ">"

-- | A Grammar maps rule names to parsing expressions.
--
-- Each entry @(name, expr)@ defines a named production rule. Rules can
-- reference each other via 'PNonTerminal' \/ 'rule', enabling recursive
-- grammars. The packrat memoization ensures termination for non-left-recursive
-- grammars.
type Grammar = Map String PExpr

-- | The result of parsing: a tree of named nodes and text leaves.
--
-- Named nodes ('PTNode') arise from rule matches and 'PLabel' expressions.
-- Text leaves ('PTLeaf') hold the matched input fragments. Empty leaves
-- are automatically filtered out during construction.
data ParseTree
  = PTNode !String [ParseTree]  -- ^ Named node (from a rule match or label)
  | PTLeaf !String              -- ^ Matched text
  deriving (Eq)

instance Show ParseTree where
  show = showTree 0
    where
      showTree indent (PTLeaf s) =
        replicate indent ' ' ++ show s
      showTree indent (PTNode name children) =
        replicate indent ' ' ++ name ++ ":\n" ++
        unlines (map (showTree (indent + 2)) children)

-- ---------------------------------------------------------------------------
-- Internal machinery
-- ---------------------------------------------------------------------------

-- | Input array for O(1) character access.
type Input = Array Int Char

toInput :: String -> Input
toInput [] = listArray (0, -1) []
toInput s  = listArray (0, length s - 1) s

inputLength :: Input -> Int
inputLength inp = let (lo, hi) = bounds inp in hi - lo + 1

charAt :: Input -> Int -> Maybe Char
charAt inp pos
  | pos < 0        = Nothing
  | pos > hi       = Nothing
  | otherwise       = Just (inp ! pos)
  where (_, hi) = bounds inp

-- | Memo table: maps (position, rule name) to cached result.
type Memo = Map (Int, String) (Maybe (ParseTree, Int))

-- | Parser state threaded through computation.
data PState = PState
  { psInput    :: !Input
  , psLen      :: !Int
  , psGrammar  :: !Grammar
  , psMemo     :: !Memo
  , psFurthest :: !Int    -- ^ Furthest position reached (for error messages)
  , psFarthestExpected :: !String  -- ^ What was expected at the furthest position
  }

-- | Update the furthest-reached position for error reporting.
updateFurthest :: Int -> String -> PState -> PState
updateFurthest pos expected st
  | pos > psFurthest st = st { psFurthest = pos, psFarthestExpected = expected }
  | otherwise = st

-- ---------------------------------------------------------------------------
-- The engine
-- ---------------------------------------------------------------------------

-- | Parse a named rule at a given position. Memoized.
parseRule :: String -> Int -> PState -> (Maybe (ParseTree, Int), PState)
parseRule name pos st =
  case Map.lookup (pos, name) (psMemo st) of
    Just cached -> (cached, st)
    Nothing ->
      case Map.lookup name (psGrammar st) of
        Nothing -> error $ "Stele.PEG: unknown rule '" ++ name ++ "'"
        Just expr ->
          let (result, st') = parseExpr expr pos st
              result' = case result of
                Just (trees, pos') -> Just (PTNode name (flattenTrees trees), pos')
                Nothing            -> Nothing
              st'' = st' { psMemo = Map.insert (pos, name) result' (psMemo st') }
          in (result', st'')

-- | Flatten singleton PTSeq wrappers and filter empty leaves.
flattenTrees :: [ParseTree] -> [ParseTree]
flattenTrees = filter (not . isEmpty)
  where
    isEmpty (PTLeaf "") = True
    isEmpty _           = False

-- | Parse a PEG expression at a given position.
-- Returns (Just (trees, newPos), state) on success, (Nothing, state) on failure.
parseExpr :: PExpr -> Int -> PState -> (Maybe ([ParseTree], Int), PState)
parseExpr expr pos st = case expr of

  PTerminal str ->
    let len = length str
        matches = all (\i -> charAt (psInput st) (pos + i) == Just (str !! i))
                      [0 .. len - 1]
    in if matches
       then (Just ([PTLeaf str], pos + len), st)
       else (Nothing, updateFurthest pos (show str) st)

  PSatisfy name predicate ->
    case charAt (psInput st) pos of
      Just c | predicate c -> (Just ([PTLeaf [c]], pos + 1), st)
      _ -> (Nothing, updateFurthest pos name st)

  PAny ->
    case charAt (psInput st) pos of
      Just c  -> (Just ([PTLeaf [c]], pos + 1), st)
      Nothing -> (Nothing, updateFurthest pos "any character" st)

  PSequence exprs -> parseSequence exprs pos st []

  PChoice exprs -> parseChoice exprs pos st

  PStar e -> parseStar e pos st []

  PPlus e ->
    let (first, st') = parseExpr e pos st
    in case first of
      Nothing -> (Nothing, st')
      Just (trees, pos') ->
        let (rest, st'') = parseStar e pos' st' []
        in case rest of
          Just (trees', pos'') -> (Just (trees ++ trees', pos''), st'')
          Nothing              -> (Just (trees, pos'), st'')

  POptional e ->
    let (result, st') = parseExpr e pos st
    in case result of
      Just _  -> (result, st')
      Nothing -> (Just ([], pos), st')

  PAnd e ->
    let (result, st') = parseExpr e pos st
    in case result of
      Just _  -> (Just ([], pos), st')   -- succeed but don't consume
      Nothing -> (Nothing, st')

  PNot e ->
    let (result, st') = parseExpr e pos st
    in case result of
      Just _  -> (Nothing, st')          -- fail if sub-expr succeeds
      Nothing -> (Just ([], pos), st')   -- succeed if sub-expr fails

  PNonTerminal name ->
    let (result, st') = parseRule name pos st
    in case result of
      Just (tree, pos') -> (Just ([tree], pos'), st')
      Nothing           -> (Nothing, st')

  PLabel name e ->
    let (result, st') = parseExpr e pos st
    in case result of
      Just (trees, pos') -> (Just ([PTNode name (flattenTrees trees)], pos'), st')
      Nothing            -> (Nothing, st')

-- | Parse a sequence of expressions in order.
parseSequence :: [PExpr] -> Int -> PState -> [ParseTree]
              -> (Maybe ([ParseTree], Int), PState)
parseSequence [] pos st acc = (Just (reverse acc, pos), st)
parseSequence (e:es) pos st acc =
  let (result, st') = parseExpr e pos st
  in case result of
    Nothing          -> (Nothing, st')
    Just (trees, pos') -> parseSequence es pos' st' (reverse trees ++ acc)

-- | Try each choice in order, return the first success.
parseChoice :: [PExpr] -> Int -> PState -> (Maybe ([ParseTree], Int), PState)
parseChoice [] _ st = (Nothing, st)
parseChoice (e:es) pos st =
  let (result, st') = parseExpr e pos st
  in case result of
    Just _  -> (result, st')
    Nothing -> parseChoice es pos st'

-- | Parse zero or more repetitions (greedy).
parseStar :: PExpr -> Int -> PState -> [ParseTree]
          -> (Maybe ([ParseTree], Int), PState)
parseStar e pos st acc =
  let (result, st') = parseExpr e pos st
  in case result of
    Nothing -> (Just (reverse acc, pos), st')
    Just (trees, pos')
      | pos' == pos -> (Just (reverse acc, pos), st')  -- no progress, stop
      | otherwise   -> parseStar e pos' st' (reverse trees ++ acc)

-- ---------------------------------------------------------------------------
-- Top-level interface
-- ---------------------------------------------------------------------------

-- | Parse an input string using a grammar, starting from a named rule.
--
-- The entire input must be consumed for the parse to succeed. Returns
-- 'Right' with the concrete 'ParseTree' on success, or 'Left' with a
-- human-readable error message on failure.
--
-- The error message includes the furthest position reached in the input
-- and what was expected there, which is typically close to the actual
-- error location.
--
-- @
-- parse myGrammar \"3+4\" \"expr\"   -- Right (PTNode \"expr\" [...])
-- parse myGrammar \"3+\" \"expr\"    -- Left \"Parse error at position 2: ...\"
-- @
parse :: Grammar -> String -> String -> Either String ParseTree
parse grammar input startRule =
  let inp = toInput input
      len = if null input then 0 else inputLength inp
      st0 = PState
        { psInput    = inp
        , psLen      = len
        , psGrammar  = grammar
        , psMemo     = Map.empty
        , psFurthest = 0
        , psFarthestExpected = ""
        }
      (result, stFinal) = parseRule startRule 0 st0
  in case result of
    Just (tree, pos)
      | pos == len -> Right tree
      | otherwise  ->
          let ctx = safeSlice pos (min 30 (len - pos)) input
          in Left $ "Parse error: matched up to position " ++ show pos
                 ++ " but input continues: " ++ show ctx
    Nothing ->
      let fp   = psFurthest stFinal
          ctx  = safeSlice fp (min 30 (len - fp)) input
          expd = psFarthestExpected stFinal
      in Left $ "Parse error at position " ++ show fp
             ++ ": expected " ++ expd
             ++ ", found " ++ show ctx

safeSlice :: Int -> Int -> String -> String
safeSlice start len s = take len (drop start s)

-- ---------------------------------------------------------------------------
-- EDSL Combinators
-- ---------------------------------------------------------------------------

-- | Match an exact string literal.
lit :: String -> PExpr
lit = PTerminal

-- | Match a specific character.
chr :: Char -> PExpr
chr c = PTerminal [c]

-- | Match a character satisfying a predicate.
satisfy :: String -> (Char -> Bool) -> PExpr
satisfy = PSatisfy

-- | Match any single character.
anyChar :: PExpr
anyChar = PAny

-- | Reference a named rule.
rule :: String -> PExpr
rule = PNonTerminal

-- | Sequence of expressions (must all match in order).
seq_ :: [PExpr] -> PExpr
seq_ [x] = x
seq_ xs  = PSequence xs

-- | Ordered choice (try each until one succeeds).
choice :: [PExpr] -> PExpr
choice [x] = x
choice xs  = PChoice xs

-- | Zero or more repetitions.
many :: PExpr -> PExpr
many = PStar

-- | One or more repetitions.
many1 :: PExpr -> PExpr
many1 = PPlus

-- | Optional (zero or one).
opt :: PExpr -> PExpr
opt = POptional

-- | Positive lookahead.
andP :: PExpr -> PExpr
andP = PAnd

-- | Negative lookahead.
notP :: PExpr -> PExpr
notP = PNot

-- | Label a sub-expression (creates a named node in the parse tree).
label :: String -> PExpr -> PExpr
label = PLabel

-- | Sequence operator. Flattens nested sequences.
infixl 6 <.>
(<.>) :: PExpr -> PExpr -> PExpr
a <.> b = case (a, b) of
  (PSequence as, PSequence bs) -> PSequence (as ++ bs)
  (PSequence as, _)            -> PSequence (as ++ [b])
  (_, PSequence bs)            -> PSequence (a : bs)
  _                            -> PSequence [a, b]

-- | Ordered choice operator. Flattens nested choices.
infixl 4 </>
(</>) :: PExpr -> PExpr -> PExpr
a </> b = case (a, b) of
  (PChoice as, PChoice bs) -> PChoice (as ++ bs)
  (PChoice as, _)          -> PChoice (as ++ [b])
  (_, PChoice bs)          -> PChoice (a : bs)
  _                        -> PChoice [a, b]

-- ---------------------------------------------------------------------------
-- Common building blocks
-- ---------------------------------------------------------------------------

-- | Optional whitespace (spaces, tabs, newlines, and @-- comments@).
ws :: PExpr
ws = many (satisfy "whitespace" (`elem` " \t\n\r") </> lineComment)

-- | Required whitespace (at least one whitespace character or comment).
ws1 :: PExpr
ws1 = many1 (satisfy "whitespace" (`elem` " \t\n\r") </> lineComment)

-- | A line comment: @--@ to end of line.
lineComment :: PExpr
lineComment = seq_ [lit "--", many (satisfy "non-newline" (/= '\n'))]

-- | One or more digits.
digits :: PExpr
digits = many1 (satisfy "digit" (\c -> c >= '0' && c <= '9'))

-- | A letter or underscore.
letter :: PExpr
letter = satisfy "letter" (\c -> (c >= 'a' && c <= 'z')
                              || (c >= 'A' && c <= 'Z')
                              || c == '_')

-- | A letter, digit, or underscore.
letterOrDigit :: PExpr
letterOrDigit = satisfy "letter/digit" (\c -> (c >= 'a' && c <= 'z')
                                            || (c >= 'A' && c <= 'Z')
                                            || (c >= '0' && c <= '9')
                                            || c == '_')
