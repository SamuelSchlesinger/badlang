-- | The grammar of badlang, defined as a first-class PEG value,
-- and the machinery to transform concrete parse trees into typed ASTs.
--
-- = Grammar Overview
--
-- The grammar is built using the combinator EDSL from "Badlang.PEG".
-- It defines the complete surface syntax of badlang:
--
-- * __Declarations:__ @altar@, @rite@, @ritual@ (each terminated by @seal@)
-- * __Expressions:__ arithmetic, comparisons, boolean operators, records
--   (@{| ... |}@), field access (@.@), @invoke@, @summon@, @divine@, @let@
-- * __Patterns:__ record patterns (@{| x: 0, y |}@), literals, wildcards,
--   variables
-- * __Statements:__ @let@ bindings, @utter@ (print), bare expressions
--
-- Expression precedence is encoded via the grammar structure:
-- @or_expr@ > @and_expr@ > @cmp_expr@ > @add_expr@ > @mul_expr@ >
-- @unary_expr@ > @postfix_expr@ > @primary_expr@.
--
-- = Parse Tree to AST
--
-- The second half of this module converts the concrete 'Badlang.PEG.ParseTree'
-- produced by the PEG parser into the typed 'Badlang.AST.Program' AST.
-- This conversion handles:
--
-- * Unwrapping labeled nodes and wrapper rules
-- * Building operator chains into left-associative 'Badlang.AST.BinOp' trees
-- * Desugaring sequential @let@ bindings into nested 'Badlang.AST.LetIn'
-- * Extracting record fields and pattern fields from their parse tree form
--
-- = Entry Point
--
-- Use 'parseProgram' to go directly from source text to AST:
--
-- @
-- case parseProgram sourceCode of
--   Left err  -> putStrLn ("Parse error: " ++ err)
--   Right ast -> ...  -- proceed to type checking
-- @
module Badlang.Grammar
  ( -- * Grammar
    badlangGrammar
    -- * Parsing
  , parseProgram
  ) where

import           Badlang.PEG
import           Badlang.AST
import qualified Data.Map.Strict as Map

-- ---------------------------------------------------------------------------
-- The Grammar
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- The Grammar
-- ---------------------------------------------------------------------------

-- | Reserved keywords — identifiers must not match these.
keywords :: [String]
keywords = [ "altar", "rite", "ritual", "given", "seal"
           , "let", "in", "invoke", "summon", "utter", "divine"
           , "hearken", "scry", "whisper" ]

-- | A keyword terminal that ensures it's not followed by an identifier char.
kw :: String -> PExpr
kw s = seq_ [lit s, notP letterOrDigit]

-- | The complete badlang grammar, expressed as a 'Grammar' value.
--
-- This is the single source of truth for badlang's surface syntax. Every
-- syntactic construct — from altar declarations to nested divine expressions —
-- is defined here using the PEG combinator EDSL from "Badlang.PEG".
badlangGrammar :: Grammar
badlangGrammar = Map.fromList

  -- ── Program ──────────────────────────────────────────────────────────
  [ ("program", ws <.> many (label "decl" (rule "decl") <.> ws))

  , ("decl", rule "altar_decl" </> rule "rite_decl" </> rule "ritual_decl")

  -- ── Altar (record type) ──────────────────────────────────────────────
  , ("altar_decl", seq_
      [ kw "altar", ws1
      , label "name" (rule "ident"), ws
      , label "fields" (many (rule "field_decl" <.> ws))
      , kw "seal"
      ])

  , ("field_decl", seq_
      [ label "fname" (rule "ident"), ws
      , lit ":", ws
      , label "ftype" (rule "type_ann")
      ])

  -- ── Type annotations ─────────────────────────────────────────────────
  , ("type_ann", rule "type_name")  -- v0.1: just names
  , ("type_name", rule "ident")

  -- ── Rite (pure function) ─────────────────────────────────────────────
  , ("rite_decl", seq_
      [ kw "rite", ws1
      , label "name" (rule "ident"), ws
      , label "clauses" (many1 (rule "given_clause" <.> ws))
      , kw "seal"
      ])

  , ("given_clause", seq_
      [ kw "given", ws
      , label "pattern" (rule "pattern"), ws
      , lit "=>", ws
      , label "body" (rule "block_expr")
      ])

  -- ── Block expression: optional let bindings then a final expression ──
  , ("block_expr", seq_
      [ label "bindings" (many (rule "let_binding"))
      , label "result" (rule "expr")
      ])

  , ("let_binding", seq_
      [ kw "let", ws1
      , label "lname" (rule "ident"), ws
      , lit "=", ws
      , label "lvalue" (rule "expr"), ws
      ])

  -- ── Ritual (effectful entry point) ───────────────────────────────────
  , ("ritual_decl", seq_
      [ kw "ritual", ws1
      , label "name" (rule "ident"), ws
      , label "body" (many1 (rule "stmt" <.> ws))
      , kw "seal"
      ])

  , ("stmt", rule "let_stmt" </> rule "utter_stmt" </> rule "whisper_stmt" </> rule "expr_stmt")

  , ("let_stmt", seq_
      [ kw "let", ws1
      , label "lname" (rule "ident"), ws
      , lit "=", ws
      , label "lvalue" (rule "expr")
      ])

  , ("utter_stmt", seq_
      [ kw "utter", ws1
      , label "value" (rule "expr")
      ])

  , ("whisper_stmt", seq_
      [ kw "whisper", ws1
      , label "value" (rule "expr")
      ])

  , ("expr_stmt", label "value" (rule "expr"))

  -- ── Expressions (precedence climbing) ────────────────────────────────
  , ("expr", rule "or_expr")

  , ("or_expr", seq_
      [ label "head" (rule "and_expr")
      , many (seq_ [ws, label "op" (lit "||"), ws, label "operand" (rule "and_expr")])
      ])

  , ("and_expr", seq_
      [ label "head" (rule "cmp_expr")
      , many (seq_ [ws, label "op" (lit "&&"), ws, label "operand" (rule "cmp_expr")])
      ])

  , ("cmp_expr", seq_
      [ label "head" (rule "add_expr")
      , opt (seq_ [ws, label "op" (rule "cmp_op"), ws, label "operand" (rule "add_expr")])
      ])

  , ("cmp_op", lit "==" </> lit "!=" </> lit "<=" </> lit ">=" </> lit "<" </> lit ">")

  , ("add_expr", seq_
      [ label "head" (rule "mul_expr")
      , many (seq_ [ws, label "op" (rule "add_op"), ws, label "operand" (rule "mul_expr")])
      ])

  , ("add_op", lit "+" </> lit "-")

  , ("mul_expr", seq_
      [ label "head" (rule "unary_expr")
      , many (seq_ [ws, label "op" (rule "mul_op"), ws, label "operand" (rule "unary_expr")])
      ])

  , ("mul_op", lit "*" </> lit "/" </> lit "%")

  , ("unary_expr",
      (seq_ [label "op" (lit "-"), ws, label "operand" (rule "unary_expr")])
      </> rule "postfix_expr")

  , ("postfix_expr", seq_
      [ label "head" (rule "primary_expr")
      , many (seq_ [lit ".", label "field" (rule "ident")])
      ])

  -- ── Primary expressions ──────────────────────────────────────────────
  , ("primary_expr",
      rule "int_lit"
      </> rule "str_lit"
      </> rule "paren_expr"
      </> rule "invoke_expr"
      </> rule "summon_expr"
      </> rule "divine_expr"
      </> rule "hearken_expr"
      </> rule "scry_expr"
      </> rule "record_lit"
      </> rule "var_expr")

  , ("int_lit", label "value" digits)

  , ("str_lit", seq_
      [ lit "\""
      , label "value" (many (satisfy "string-char" (\c -> c /= '"' && c /= '\\')))
      , lit "\""
      ])

  , ("paren_expr", seq_ [lit "(", ws, rule "expr", ws, lit ")"])

  , ("invoke_expr", seq_
      [ kw "invoke", ws1
      , label "rite" (rule "ident"), ws
      , label "arg" (rule "invoke_arg")
      ])

  , ("invoke_arg",
      rule "record_lit"
      </> rule "paren_expr"
      </> rule "var_expr")

  , ("summon_expr", seq_
      [ kw "summon", ws1
      , label "altar" (rule "ident"), ws
      , label "fields" (rule "record_lit")
      ])

  , ("divine_expr", seq_
      [ kw "divine", ws1
      , label "scrutinee" (rule "expr"), ws
      , label "clauses" (many1 (rule "given_clause" <.> ws))
      , kw "seal"
      ])

  , ("hearken_expr", kw "hearken")

  , ("scry_expr", kw "scry")

  , ("record_lit", seq_
      [ lit "{|", ws
      , label "fields" (opt (seq_
          [ rule "field_init"
          , many (seq_ [ws, lit ",", ws, rule "field_init"])
          ]))
      , ws, lit "|}"
      ])

  , ("field_init", seq_
      [ label "fname" (rule "ident"), ws
      , lit ":", ws
      , label "fvalue" (rule "expr")
      ])

  , ("var_expr", rule "ident")

  -- ── Patterns ─────────────────────────────────────────────────────────
  , ("pattern",
      rule "record_pat"
      </> rule "lit_pat"
      </> rule "wild_pat"
      </> rule "var_pat")

  , ("record_pat", seq_
      [ lit "{|", ws
      , label "fields" (opt (seq_
          [ rule "pat_field"
          , many (seq_ [ws, lit ",", ws, rule "pat_field"])
          ]))
      , ws, lit "|}"
      ])

  , ("pat_field", seq_
      [ label "fname" (rule "ident")
      , opt (seq_ [ws, lit ":", ws, label "fpat" (rule "pattern")])
      ])

  , ("lit_pat", rule "int_lit" </> rule "str_lit")
  , ("wild_pat", lit "_")
  , ("var_pat", rule "ident")

  -- ── Identifiers ──────────────────────────────────────────────────────
  , ("ident", seq_
      [ notP (rule "keyword")
      , label "name" (seq_ [letter, many letterOrDigit])
      ])

  , ("keyword", choice (map (\k -> seq_ [lit k, notP letterOrDigit]) keywords))
  ]

-- ---------------------------------------------------------------------------
-- Parse Tree → AST
-- ---------------------------------------------------------------------------

-- | Parse a badlang source string into a typed AST.
--
-- This is the main entry point for parsing. It runs the PEG parser with
-- 'badlangGrammar', then converts the resulting parse tree into a
-- 'Program'. Returns 'Left' with an error message on parse failure or
-- AST conversion failure.
parseProgram :: String -> Either String Program
parseProgram input = do
  tree <- parse badlangGrammar input "program"
  treeToProgram tree

-- | Convert a parse tree to a Program.
treeToProgram :: ParseTree -> Either String Program
treeToProgram (PTNode "program" children) = do
  decls <- mapM treeToDecl (findAll "decl" children)
  return (Program decls)
treeToProgram t = Left $ "Expected program, got: " ++ take 100 (show t)

treeToDecl :: ParseTree -> Either String Decl
treeToDecl (PTNode "decl" [child]) = treeToDecl child
treeToDecl (PTNode "altar_decl" children) = do
  name   <- getText =<< find1 "name" children
  fields <- mapM treeToField (findTyped "field_decl" (findAll "fields" children >>= getChildren))
  return (AltarDecl name fields)
treeToDecl (PTNode "rite_decl" children) = do
  name    <- getText =<< find1 "name" children
  clauses <- mapM treeToGivenClause (findTyped "given_clause" (findAll "clauses" children >>= getChildren))
  return (RiteDecl name clauses)
treeToDecl (PTNode "ritual_decl" children) = do
  name  <- getText =<< find1 "name" children
  let stmtNodes = findAll "body" children >>= getChildren
      stmts'    = filter isStmtNode stmtNodes
  stmts <- mapM treeToStmt stmts'
  return (RitualDecl name stmts)
  where
    isStmtNode (PTNode n _) = n `elem` ["let_stmt", "utter_stmt", "whisper_stmt", "expr_stmt", "stmt"]
    isStmtNode _ = False
treeToDecl t = Left $ "Expected declaration, got: " ++ take 100 (show t)

treeToField :: ParseTree -> Either String Field
treeToField (PTNode "field_decl" children) = do
  name <- getText =<< find1 "fname" children
  typ  <- treeToTypeAnn =<< find1 "ftype" children
  return (Field name typ)
treeToField t = Left $ "Expected field, got: " ++ take 100 (show t)

treeToTypeAnn :: ParseTree -> Either String TypeAnn
treeToTypeAnn (PTNode "ftype" children) =
  case children of
    [child] -> treeToTypeAnn child
    _       -> treeToTypeAnn (head children)
treeToTypeAnn (PTNode "type_ann" children) =
  treeToTypeAnn (head children)
treeToTypeAnn (PTNode "type_name" children) =
  treeToTypeAnn (head children)
treeToTypeAnn (PTNode "ident" children) = do
  name <- getText =<< find1 "name" children
  return (TAName name)
treeToTypeAnn t = do
  txt <- getText t
  return (TAName txt)

treeToGivenClause :: ParseTree -> Either String GivenClause
treeToGivenClause (PTNode "given_clause" children) = do
  pat  <- treeToPattern =<< find1 "pattern" children
  body <- treeToBlockExpr =<< find1 "body" children
  return (GivenClause pat body)
treeToGivenClause t = Left $ "Expected given clause, got: " ++ take 100 (show t)

treeToBlockExpr :: ParseTree -> Either String Expr
treeToBlockExpr (PTNode "body" [PTNode "block_expr" cs]) = treeToBlockExpr' cs
treeToBlockExpr (PTNode "body" children) = treeToBlockExpr' children
treeToBlockExpr (PTNode "block_expr" children) = treeToBlockExpr' children
treeToBlockExpr t = treeToExpr t

treeToBlockExpr' :: [ParseTree] -> Either String Expr
treeToBlockExpr' children = do
  let bindingNodes = findTyped "let_binding" (findAll "bindings" children >>= getChildren)
      resultNode   = findAll "result" children
  bindings <- mapM treeToLetBinding bindingNodes
  result   <- case resultNode of
    [r] -> treeToExpr r
    _   -> case reverse children of
             (last_ : _) -> treeToExpr last_
             []          -> Left "Empty block expression"
  return (foldr (\(n, v) body -> LetIn n v body) result bindings)

treeToLetBinding :: ParseTree -> Either String (String, Expr)
treeToLetBinding (PTNode "let_binding" children) = do
  name  <- getText =<< find1 "lname" children
  value <- treeToExpr =<< find1 "lvalue" children
  return (name, value)
treeToLetBinding t = Left $ "Expected let binding, got: " ++ take 100 (show t)

treeToStmt :: ParseTree -> Either String Stmt
treeToStmt (PTNode "let_stmt" children) = do
  name  <- getText =<< find1 "lname" children
  value <- treeToExpr =<< find1 "lvalue" children
  return (LetStmt name value)
treeToStmt (PTNode "utter_stmt" children) = do
  value <- treeToExpr =<< find1 "value" children
  return (UtterStmt value)
treeToStmt (PTNode "whisper_stmt" children) = do
  value <- treeToExpr =<< find1 "value" children
  return (WhisperStmt value)
treeToStmt (PTNode "expr_stmt" children) = do
  value <- treeToExpr =<< find1 "value" children
  return (ExprStmt value)
treeToStmt (PTNode "stmt" [child]) = treeToStmt child
treeToStmt t = Left $ "Expected statement, got: " ++ take 100 (show t)

-- ── Expression conversion ──────────────────────────────────────────────

treeToExpr :: ParseTree -> Either String Expr
treeToExpr (PTNode "result" children) =
  case children of
    [child] -> treeToExpr child
    _       -> treeToExpr (head children)
treeToExpr (PTNode "value" children) =
  case children of
    [child] -> treeToExpr child
    _       -> treeToExpr (head children)
treeToExpr (PTNode "expr" [child]) = treeToExpr child
treeToExpr (PTNode name children)
  | name `elem` ["or_expr", "and_expr", "add_expr", "mul_expr"] =
      treeToChainExpr children
  | name == "cmp_expr" = treeToCompareExpr children
  | name == "unary_expr" = treeToUnaryExpr children
  | name == "postfix_expr" = treeToPostfixExpr children
treeToExpr (PTNode "primary_expr" [child]) = treeToExpr child
treeToExpr (PTNode "paren_expr" children) =
  -- find the expr node among the parens and whitespace
  case findTyped "expr" children of
    [e] -> treeToExpr e
    _   -> case filter isNode children of
             [c] -> treeToExpr c
             (c:_) -> treeToExpr c
             [] -> Left "Empty parenthesized expression"
  where isNode (PTNode _ _) = True
        isNode _ = False
treeToExpr (PTNode "int_lit" children) = do
  valNode <- find1 "value" children
  txt <- getText valNode
  case reads txt of
    [(n, "")] -> Right (IntLit n)
    _         -> Left $ "Invalid integer: " ++ txt
treeToExpr (PTNode "str_lit" children) = do
  valNode <- find1 "value" children
  txt <- getText valNode
  return (StrLit txt)
treeToExpr (PTNode "invoke_expr" children) = do
  riteName <- getText =<< find1 "rite" children
  argNode  <- find1 "arg" children
  arg      <- treeToExpr argNode
  return (Invoke riteName arg)
treeToExpr (PTNode "summon_expr" children) = do
  altarName <- getText =<< find1 "altar" children
  fieldsNode <- find1 "fields" children
  fields <- treeToRecordFields fieldsNode
  return (Summon altarName fields)
treeToExpr (PTNode "divine_expr" children) = do
  scrutinee <- treeToExpr =<< find1 "scrutinee" children
  clauses <- mapM treeToGivenClause (findTyped "given_clause" (findAll "clauses" children >>= getChildren))
  return (Divine scrutinee clauses)
treeToExpr (PTNode "hearken_expr" _) = return Hearken
treeToExpr (PTNode "scry_expr" _) = return Scry
treeToExpr (PTNode "record_lit" children) = do
  let fieldsNode = findAll "fields" children
  fields <- case fieldsNode of
    [] -> return []
    _  -> treeToRecordFields' (concatMap getChildren fieldsNode)
  return (Record fields)
treeToExpr (PTNode "var_expr" [child]) = treeToExpr child
treeToExpr (PTNode "ident" children) = do
  name <- getText =<< find1 "name" children
  return (Var name)
treeToExpr (PTNode "arg" [child]) = treeToExpr child
treeToExpr (PTNode "arg" children) = treeToExpr (Prelude.head children)
treeToExpr (PTNode "invoke_arg" [child]) = treeToExpr child
treeToExpr (PTNode "invoke_arg" children) = treeToExpr (Prelude.head children)
treeToExpr (PTNode "head" children) =
  case children of
    [child] -> treeToExpr child
    _       -> treeToExpr (head children)
treeToExpr (PTNode "operand" children) =
  case children of
    [child] -> treeToExpr child
    _       -> treeToExpr (head children)
treeToExpr (PTNode "lvalue" children) =
  case children of
    [child] -> treeToExpr child
    _       -> treeToExpr (head children)
treeToExpr (PTNode "block_expr" children) = treeToBlockExpr' children
-- General single-child unwrapping for wrapper nodes
treeToExpr (PTNode _name [child]) = treeToExpr child
-- General multi-child: try to find the meaningful node
treeToExpr (PTNode _name children) =
  case filter isNode children of
    [c] -> treeToExpr c
    (c:_) -> treeToExpr c
    []  -> case children of
             (c:_) -> treeToExpr c
             []    -> Left "Empty expression node"
  where isNode (PTNode _ _) = True
        isNode _ = False
treeToExpr (PTLeaf s) =
  -- A bare leaf in expression position — might be a var or int
  case reads s :: [(Integer, String)] of
    [(n, "")] -> Right (IntLit n)
    _         -> Right (Var s)

treeToRecordFields :: ParseTree -> Either String [(String, Expr)]
treeToRecordFields (PTNode "fields" children) =
  -- "fields" label may wrap a record_lit or directly contain field_inits
  case findTyped "record_lit" children of
    [rl] -> treeToRecordFields rl
    _    -> treeToRecordFields' children
treeToRecordFields (PTNode "record_lit" children) = do
  let fieldsNode = findAll "fields" children
  case fieldsNode of
    [] -> return []
    _  -> treeToRecordFields' (concatMap getChildren fieldsNode)
treeToRecordFields t = treeToRecordFields' [t]

treeToRecordFields' :: [ParseTree] -> Either String [(String, Expr)]
treeToRecordFields' trees =
  mapM treeToFieldInit (filter isFieldInit trees)
  where
    isFieldInit (PTNode "field_init" _) = True
    isFieldInit _                        = False

treeToFieldInit :: ParseTree -> Either String (String, Expr)
treeToFieldInit (PTNode "field_init" children) = do
  name  <- getText =<< find1 "fname" children
  value <- treeToExpr =<< find1 "fvalue" children
  return (name, value)
treeToFieldInit t = Left $ "Expected field init, got: " ++ take 100 (show t)

-- ── Operator chain handling ────────────────────────────────────────────

-- | Convert left-associative operator chains: head (op operand)*
treeToChainExpr :: [ParseTree] -> Either String Expr
treeToChainExpr children = do
  let headNodes = findAll "head" children
      opNodes   = findAll "op" children
      operands  = findAll "operand" children
  headExpr <- case headNodes of
    [h] -> treeToExpr h
    _   -> Left "Expected head in chain expression"
  ops  <- mapM getOpText opNodes
  args <- mapM treeToExpr operands
  return (foldlChain headExpr (zip ops args))

treeToCompareExpr :: [ParseTree] -> Either String Expr
treeToCompareExpr children = do
  let headNodes = findAll "head" children
      opNodes   = findAll "op" children
      operands  = findAll "operand" children
  headExpr <- case headNodes of
    [h] -> treeToExpr h
    _   -> Left "Expected head in compare expression"
  case (opNodes, operands) of
    ([], [])     -> return headExpr
    ([o], [rhs]) -> do
      op  <- getOpText o
      rhs' <- treeToExpr rhs
      return (BinOp (textToOp op) headExpr rhs')
    _ -> Left "Invalid comparison expression"

treeToUnaryExpr :: [ParseTree] -> Either String Expr
treeToUnaryExpr children =
  let opNodes = findAll "op" children
      operands = findAll "operand" children
  in case (opNodes, operands) of
    ([_], [operand]) -> do
      e <- treeToExpr operand
      return (UnOp Neg e)
    _ -> case children of
      [child] -> treeToExpr child
      _       -> Left "Invalid unary expression"

treeToPostfixExpr :: [ParseTree] -> Either String Expr
treeToPostfixExpr children = do
  let headNodes  = findAll "head" children
      fieldNodes = findAll "field" children
  headExpr <- case headNodes of
    [h] -> treeToExpr h
    _   -> Left "Expected head in postfix expression"
  fields <- mapM getText fieldNodes
  return (foldl FieldAccess headExpr fields)

foldlChain :: Expr -> [(String, Expr)] -> Expr
foldlChain = foldl (\acc (op, rhs) -> BinOp (textToOp op) acc rhs)

textToOp :: String -> BinOp
textToOp "+"  = Add
textToOp "-"  = Sub
textToOp "*"  = Mul
textToOp "/"  = Div
textToOp "%"  = Mod
textToOp "==" = Eq
textToOp "!=" = Neq
textToOp "<"  = Lt
textToOp ">"  = Gt
textToOp "<=" = Lte
textToOp ">=" = Gte
textToOp "&&" = And
textToOp "||" = Or
textToOp s    = error $ "Unknown operator: " ++ s

getOpText :: ParseTree -> Either String String
getOpText (PTNode "op" children) = getText (PTNode "op" children)
getOpText (PTLeaf s) = Right s
getOpText t = getText t

-- ── Pattern conversion ─────────────────────────────────────────────────

treeToPattern :: ParseTree -> Either String Pattern
treeToPattern (PTNode "pattern" [child]) = treeToPattern child
treeToPattern (PTNode "fpat" [child]) = treeToPattern child
treeToPattern (PTNode "fpat" children) = treeToPattern (Prelude.head children)
treeToPattern (PTNode "record_pat" children) = do
  let fieldsNode = findAll "fields" children
  fields <- case fieldsNode of
    [] -> return []
    _  -> treeToPatFields (concatMap getChildren fieldsNode)
  return (PRec fields)
treeToPattern (PTNode "lit_pat" [child]) = do
  e <- treeToExpr child
  return (PLit e)
treeToPattern (PTNode "wild_pat" _) = return PWild
treeToPattern (PTNode "var_pat" [child]) = do
  name <- getText child
  return (PVar name)
treeToPattern (PTNode "ident" children) = do
  name <- getText =<< find1 "name" children
  return (PVar name)
treeToPattern t = Left $ "Expected pattern, got: " ++ take 100 (show t)

treeToPatFields :: [ParseTree] -> Either String [PatField]
treeToPatFields = mapM treeToPatField . filter isPatField
  where isPatField (PTNode "pat_field" _) = True
        isPatField _                       = False

treeToPatField :: ParseTree -> Either String PatField
treeToPatField (PTNode "pat_field" children) = do
  name <- getText =<< find1 "fname" children
  let mPat = case findAll "fpat" children of
               [p] -> Just p
               _   -> Nothing
  pat <- case mPat of
    Nothing -> return Nothing
    Just p  -> Just <$> treeToPattern p
  return (PatField name pat)
treeToPatField t = Left $ "Expected pattern field, got: " ++ take 100 (show t)

-- ---------------------------------------------------------------------------
-- Parse tree utilities
-- ---------------------------------------------------------------------------

-- | Find all children with a given label name.
findAll :: String -> [ParseTree] -> [ParseTree]
findAll _ [] = []
findAll name (PTNode n cs : rest)
  | n == name = PTNode n cs : findAll name rest
  | otherwise = findAll name rest
findAll name (_ : rest) = findAll name rest

-- | Find exactly one child with a given label name.
find1 :: String -> [ParseTree] -> Either String ParseTree
find1 name trees =
  case findAll name trees of
    [x] -> Right x
    []  -> Left $ "Missing '" ++ name ++ "' in parse tree"
    _   -> Right (head (findAll name trees))

-- | Get the text content of a parse tree node.
getText :: ParseTree -> Either String String
getText (PTLeaf s) = Right s
getText (PTNode "name" children) = concatTexts children
getText (PTNode "value" children) = concatTexts children
getText (PTNode _ children) = concatTexts children

-- | Concatenate all leaf text in a subtree.
concatTexts :: [ParseTree] -> Either String String
concatTexts trees = Right (concatMap leafText trees)

leafText :: ParseTree -> String
leafText (PTLeaf s) = s
leafText (PTNode _ cs) = concatMap leafText cs

-- | Get the children of a node.
getChildren :: ParseTree -> [ParseTree]
getChildren (PTNode _ cs) = cs
getChildren (PTLeaf _)    = []

-- | Filter parse tree nodes by their type name.
findTyped :: String -> [ParseTree] -> [ParseTree]
findTyped name = filter matches
  where
    matches (PTNode n _) = n == name
    matches _            = False
