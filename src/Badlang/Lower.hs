-- | Lowering pass: AST to IR.
--
-- Transforms a typed badlang 'Program' into an 'IRProgram'. This pass
-- resolves all pattern matching, divine expressions, and let-in chains
-- into flat instructions and basic block control flow, so that backends
-- (C and AArch64) are purely mechanical translations.
module Badlang.Lower
  ( lowerProgram
  ) where

import Badlang.AST
import Badlang.IR

import Control.Monad.Trans.State.Strict (State, evalState, get, modify')

-- ---------------------------------------------------------------------------
-- Lowering monad
-- ---------------------------------------------------------------------------

data LowerState = LowerState
  { freshCounter  :: !Int
  , emittedBlocks :: [Block]     -- accumulated (reversed order)
  , currentInstrs :: [Instr]     -- current block (reversed order)
  , currentBlockId :: BlockId
  }

type Lower = State LowerState

freshVar :: String -> Lower String
freshVar prefix = do
  s <- get; modify' (\st -> st { freshCounter = freshCounter st + 1 })
  return (prefix ++ show (freshCounter s))

freshBlock :: String -> Lower BlockId
freshBlock prefix = do
  s <- get; modify' (\st -> st { freshCounter = freshCounter st + 1 })
  return (prefix ++ show (freshCounter s))

emit :: Instr -> Lower ()
emit instr = modify' (\s -> s { currentInstrs = instr : currentInstrs s })

-- | Finish the current block with a terminator and start a new one.
finishBlock :: Terminator -> BlockId -> Lower ()
finishBlock term newId = modify' $ \s ->
  let blk = Block (currentBlockId s) (reverse (currentInstrs s)) term
  in s { emittedBlocks = blk : emittedBlocks s
       , currentInstrs = []
       , currentBlockId = newId
       }

-- | Finish current block without starting a new one (for the last block).
finishBlockFinal :: Terminator -> Lower ()
finishBlockFinal term = modify' $ \s ->
  let blk = Block (currentBlockId s) (reverse (currentInstrs s)) term
  in s { emittedBlocks = blk : emittedBlocks s
       , currentInstrs = []
       }

-- | Collect all blocks emitted so far (including current if non-empty)
-- and reset for the next function.
collectBlocks :: Lower [Block]
collectBlocks = do
  s <- get
  let blocks = reverse (emittedBlocks s)
  modify' (\st -> st { emittedBlocks = [], currentInstrs = [] })
  return blocks

-- ---------------------------------------------------------------------------
-- Name mangling
-- ---------------------------------------------------------------------------

cName :: String -> String
cName "arg" = "arg"
cName name  = "bl_" ++ name


-- ---------------------------------------------------------------------------
-- Program lowering
-- ---------------------------------------------------------------------------

-- | Lower a complete badlang program to IR.
lowerProgram :: Program -> IRProgram
lowerProgram (Program decls) = evalState go initState
  where
    initState = LowerState 0 [] [] "entry"
    go = do
      irDecls <- concat <$> mapM lowerDecl decls
      return (IRProgram irDecls)

lowerDecl :: Decl -> Lower [IRDecl]
lowerDecl (AltarDecl _ _) = return []
lowerDecl (RiteDecl name clauses) = do
  body <- lowerRite name clauses
  return [IRFunc name body]
lowerDecl (RitualDecl "main" stmts) = do
  body <- lowerRitual stmts
  return [IRMain body]
lowerDecl (RitualDecl _ _) = return []

-- ---------------------------------------------------------------------------
-- Rite lowering
-- ---------------------------------------------------------------------------

lowerRite :: String -> [GivenClause] -> Lower IRFuncBody
lowerRite name clauses = do
  -- Reset state for this function
  modify' (\s -> s { emittedBlocks = []
                   , currentInstrs = []
                   , currentBlockId = "entry" })

  -- Lower pattern match clauses
  lowerClauses "arg" clauses ("rite '" ++ name ++ "'") TReturn

  blocks <- collectBlocks
  return (IRFuncBody "arg" blocks)

-- | Lower a sequence of given clauses into a chain of test blocks.
-- The continuation says what to do with the result of a successful match.
lowerClauses :: Var -> [GivenClause] -> String
             -> (Var -> Terminator) -> Lower ()
lowerClauses scrut clauses failMsg mkTerm = do
  failLbl <- freshBlock "match_fail_"
  clauseLabels <- mapM (\(i, _) -> freshBlock ("clause_" ++ show i ++ "_test_")) (zip [(0::Int)..] clauses)
  let nextLabels = drop 1 clauseLabels ++ [failLbl]

  -- Jump to first clause
  let firstLbl = case clauseLabels of
        (l:_) -> l
        []    -> failLbl
  finishBlock (TJump firstLbl) firstLbl

  -- Emit each clause
  mapM_ (\(clauseLbl, nextLbl, GivenClause pat body) ->
    lowerClause scrut pat body clauseLbl nextLbl mkTerm
    ) (zip3 clauseLabels nextLabels clauses)

  -- Match fail block
  modify' (\s -> s { currentBlockId = failLbl })
  finishBlockFinal (TMatchFail failMsg)

-- | Lower a single clause: test pattern, bind variables, execute body.
lowerClause :: Var -> Pattern -> Expr -> BlockId -> BlockId
            -> (Var -> Terminator) -> Lower ()
lowerClause scrut pat body clauseLbl nextLbl mkTerm = do
  -- We're already in clauseLbl
  modify' (\s -> s { currentBlockId = clauseLbl, currentInstrs = [] })
  bodyLbl <- freshBlock "clause_body_"
  lowerPatternTest scrut pat bodyLbl nextLbl

  -- Body block
  modify' (\s -> s { currentBlockId = bodyLbl, currentInstrs = [] })
  bindings <- lowerPatternBindings scrut pat
  result <- lowerExpr body
  -- Release pattern bindings in reverse order
  mapM_ (\v -> emit (IRelease v)) (reverse bindings)
  finishBlockFinal (mkTerm result)

-- ---------------------------------------------------------------------------
-- Pattern matching: test generation
-- ---------------------------------------------------------------------------

-- | Generate tests for a pattern, branching to bodyLbl on success
-- or nextLbl on failure. May emit multiple blocks for complex patterns.
lowerPatternTest :: Var -> Pattern -> BlockId -> BlockId -> Lower ()
lowerPatternTest _scrut PWild bodyLbl _nextLbl = do
  finishBlock (TJump bodyLbl) bodyLbl
lowerPatternTest _scrut (PVar _) bodyLbl _nextLbl = do
  finishBlock (TJump bodyLbl) bodyLbl
lowerPatternTest scrut (PLit (IntLit n)) bodyLbl nextLbl = do
  tc <- freshVar "_tc"
  emit (ITagCheck tc scrut TagInt)
  checkLbl <- freshBlock "litcheck_"
  finishBlock (TBranch tc checkLbl nextLbl) checkLbl
  veq <- freshVar "_eq"
  emit (IIntEq veq scrut n)
  finishBlock (TBranch veq bodyLbl nextLbl) bodyLbl
lowerPatternTest scrut (PLit (StrLit s)) bodyLbl nextLbl = do
  tc <- freshVar "_tc"
  emit (ITagCheck tc scrut TagStr)
  checkLbl <- freshBlock "litcheck_"
  finishBlock (TBranch tc checkLbl nextLbl) checkLbl
  veq <- freshVar "_eq"
  emit (IStrEq veq scrut s)
  finishBlock (TBranch veq bodyLbl nextLbl) bodyLbl
lowerPatternTest scrut (PRec fields) bodyLbl nextLbl = do
  -- First check it's a record
  tc <- freshVar "_tc"
  emit (ITagCheck tc scrut TagRecord)
  if null fields
    then finishBlock (TBranch tc bodyLbl nextLbl) bodyLbl
    else do
      firstFieldLbl <- freshBlock "recfield_"
      finishBlock (TBranch tc firstFieldLbl nextLbl) firstFieldLbl
      lowerRecFieldTests scrut fields bodyLbl nextLbl
lowerPatternTest _ (PLit _) _ nextLbl = do
  finishBlock (TJump nextLbl) nextLbl

-- | Lower field tests for a record pattern.
lowerRecFieldTests :: Var -> [PatField] -> BlockId -> BlockId -> Lower ()
lowerRecFieldTests _ [] bodyLbl _ =
  finishBlock (TJump bodyLbl) bodyLbl
lowerRecFieldTests scrut (PatField fname mPat : rest) bodyLbl nextLbl = do
  -- Get field
  fv <- freshVar ("_f_" ++ fname ++ "_")
  emit (IFieldGet fv scrut fname)
  -- Null check
  nc <- freshVar "_nc"
  emit (INullCheck nc fv)
  case mPat of
    Nothing -> do
      -- Just check field exists
      if null rest
        then finishBlock (TBranch nc bodyLbl nextLbl) bodyLbl
        else do
          nextFieldLbl <- freshBlock "recfield_"
          finishBlock (TBranch nc nextFieldLbl nextLbl) nextFieldLbl
          lowerRecFieldTests scrut rest bodyLbl nextLbl
    Just (PLit (IntLit n)) -> do
      litLbl <- freshBlock "fieldlit_"
      finishBlock (TBranch nc litLbl nextLbl) litLbl
      -- Check tag
      tc <- freshVar "_tc"
      emit (ITagCheck tc fv TagInt)
      valLbl <- freshBlock "fieldval_"
      finishBlock (TBranch tc valLbl nextLbl) valLbl
      -- Check value
      veq <- freshVar "_eq"
      emit (IIntEq veq fv n)
      if null rest
        then finishBlock (TBranch veq bodyLbl nextLbl) bodyLbl
        else do
          nextFieldLbl <- freshBlock "recfield_"
          finishBlock (TBranch veq nextFieldLbl nextLbl) nextFieldLbl
          lowerRecFieldTests scrut rest bodyLbl nextLbl
    Just (PLit (StrLit s)) -> do
      litLbl <- freshBlock "fieldlit_"
      finishBlock (TBranch nc litLbl nextLbl) litLbl
      tc <- freshVar "_tc"
      emit (ITagCheck tc fv TagStr)
      valLbl <- freshBlock "fieldval_"
      finishBlock (TBranch tc valLbl nextLbl) valLbl
      veq <- freshVar "_eq"
      emit (IStrEq veq fv s)
      if null rest
        then finishBlock (TBranch veq bodyLbl nextLbl) bodyLbl
        else do
          nextFieldLbl <- freshBlock "recfield_"
          finishBlock (TBranch veq nextFieldLbl nextLbl) nextFieldLbl
          lowerRecFieldTests scrut rest bodyLbl nextLbl
    Just (PVar _) -> do
      -- Just check field exists (PVar in field position = type annotation)
      if null rest
        then finishBlock (TBranch nc bodyLbl nextLbl) bodyLbl
        else do
          nextFieldLbl <- freshBlock "recfield_"
          finishBlock (TBranch nc nextFieldLbl nextLbl) nextFieldLbl
          lowerRecFieldTests scrut rest bodyLbl nextLbl
    Just PWild -> do
      if null rest
        then finishBlock (TBranch nc bodyLbl nextLbl) bodyLbl
        else do
          nextFieldLbl <- freshBlock "recfield_"
          finishBlock (TBranch nc nextFieldLbl nextLbl) nextFieldLbl
          lowerRecFieldTests scrut rest bodyLbl nextLbl
    Just _ -> do
      -- Unsupported sub-pattern, just check exists
      if null rest
        then finishBlock (TBranch nc bodyLbl nextLbl) bodyLbl
        else do
          nextFieldLbl <- freshBlock "recfield_"
          finishBlock (TBranch nc nextFieldLbl nextLbl) nextFieldLbl
          lowerRecFieldTests scrut rest bodyLbl nextLbl

-- ---------------------------------------------------------------------------
-- Pattern matching: variable binding
-- ---------------------------------------------------------------------------

-- | Bind variables from a pattern match. Returns the list of bound
-- variable names (for subsequent release).
lowerPatternBindings :: Var -> Pattern -> Lower [Var]
lowerPatternBindings scrut (PVar name) = do
  let v = cName name
  emit (ICopy v scrut)
  emit (IRetain v)
  return [v]
lowerPatternBindings _ PWild = return []
lowerPatternBindings _ (PLit _) = return []
lowerPatternBindings scrut (PRec fields) =
  concat <$> mapM (lowerFieldBinding scrut) fields

lowerFieldBinding :: Var -> PatField -> Lower [Var]
lowerFieldBinding scrut (PatField fname mPat) = do
  let v = cName fname
  -- We need to get the field value again for binding
  -- (the test-time variable is in a different block scope in C,
  -- but in IR we just re-extract since it's cheap)
  fv <- freshVar ("_fb_" ++ fname ++ "_")
  emit (IFieldGet fv scrut fname)
  case mPat of
    Nothing -> do
      emit (ICopy v fv)
      emit (IRetain v)
      return [v]
    Just (PLit (IntLit _)) -> do
      emit (ICopy v fv)
      emit (IRetain v)
      return [v]
    Just (PLit (StrLit _)) -> do
      emit (ICopy v fv)
      emit (IRetain v)
      return [v]
    Just (PVar _) -> do
      emit (ICopy v fv)
      emit (IRetain v)
      return [v]
    Just PWild -> return []
    Just _ -> return []

-- ---------------------------------------------------------------------------
-- Expression lowering
-- ---------------------------------------------------------------------------

-- | Lower an expression, returning the Var holding the result.
-- The result is an owned Value* (refcount incremented).
lowerExpr :: Expr -> Lower Var

lowerExpr (IntLit n) = do
  t <- freshVar "_t"
  emit (IConst t (OInt n))
  return t

lowerExpr (StrLit s) = do
  t <- freshVar "_t"
  emit (IConst t (OStr s))
  return t

lowerExpr (Var name) = do
  t <- freshVar "_t"
  emit (ICopy t (cName name))
  emit (IRetain t)
  return t

lowerExpr (BinOp op e1 e2) = do
  v1 <- lowerExpr e1
  v2 <- lowerExpr e2
  t <- freshVar "_t"
  emit (IBinOp t op v1 v2)
  emit (IRelease v1)
  emit (IRelease v2)
  return t

lowerExpr (UnOp uop e) = do
  v <- lowerExpr e
  t <- freshVar "_t"
  emit (IUnOp t uop v)
  emit (IRelease v)
  return t

lowerExpr (FieldAccess e field) = do
  v <- lowerExpr e
  t <- freshVar "_t"
  emit (IFieldGet t v field)
  emit (IRetain t)
  emit (IRelease v)
  return t

lowerExpr (Record fields) = lowerRecordExpr fields

lowerExpr (Summon _ fields) = lowerRecordExpr fields

lowerExpr (Invoke riteName arg) = do
  varg <- lowerExpr arg
  t <- freshVar "_t"
  emit (ICall t riteName varg)
  emit (IRelease varg)
  return t

lowerExpr Hearken = do
  t <- freshVar "_t"
  emit (IHearken t)
  return t

lowerExpr Scry = do
  t <- freshVar "_t"
  emit (IScry t)
  return t

lowerExpr (LetIn name value body) = do
  -- Flatten let-in chains
  let (bindings, finalBody) = collectLetChain (LetIn name value body)
  -- Lower each binding
  boundNames <- mapM (\(n, v) -> do
    vr <- lowerExpr v
    let mangledName = cName n
    emit (ICopy mangledName vr)
    return mangledName
    ) bindings
  -- Lower body
  result <- lowerExpr finalBody
  -- Release bindings in reverse order
  mapM_ (\v -> emit (IRelease v)) (reverse boundNames)
  return result

lowerExpr (Divine scrutinee clauses) = do
  scrResult <- lowerExpr scrutinee
  scr <- freshVar "_scr"
  emit (ICopy scr scrResult)

  dvn <- freshVar "_dvn"
  doneLbl <- freshBlock "divine_done_"

  -- Lower divine clauses
  lowerDivineClauses scr dvn doneLbl clauses

  -- Done block: release scrutinee, result is in dvn
  modify' (\s -> s { currentBlockId = doneLbl, currentInstrs = [] })
  emit (IRelease scr)
  return dvn

-- | Lower divine clauses - like rite clauses but write to a result var
-- and jump to a done label instead of returning.
lowerDivineClauses :: Var -> Var -> BlockId -> [GivenClause] -> Lower ()
lowerDivineClauses scrut dvn doneLbl clauses = do
  failLbl <- freshBlock "divine_fail_"
  clauseLabels <- mapM (\(i, _) -> freshBlock ("dclause_" ++ show i ++ "_test_")) (zip [(0::Int)..] clauses)
  let nextLabels = drop 1 clauseLabels ++ [failLbl]

  let firstLbl = case clauseLabels of
        (l:_) -> l
        []    -> failLbl
  finishBlock (TJump firstLbl) firstLbl

  mapM_ (\(clauseLbl, nextLbl, GivenClause pat body) ->
    lowerDivineClause scrut dvn doneLbl pat body clauseLbl nextLbl
    ) (zip3 clauseLabels nextLabels clauses)

  -- Divine fail block
  modify' (\s -> s { currentBlockId = failLbl })
  finishBlockFinal (TMatchFail "divine")

-- | Lower a single divine clause.
lowerDivineClause :: Var -> Var -> BlockId -> Pattern -> Expr
                  -> BlockId -> BlockId -> Lower ()
lowerDivineClause scrut dvn doneLbl pat body clauseLbl nextLbl = do
  modify' (\s -> s { currentBlockId = clauseLbl, currentInstrs = [] })
  bodyLbl <- freshBlock "dclause_body_"
  lowerPatternTest scrut pat bodyLbl nextLbl

  -- Body block
  modify' (\s -> s { currentBlockId = bodyLbl, currentInstrs = [] })
  bindings <- lowerPatternBindings scrut pat
  result <- lowerExpr body
  mapM_ (\v -> emit (IRelease v)) (reverse bindings)
  emit (ICopy dvn result)
  finishBlock (TJump doneLbl) doneLbl

lowerRecordExpr :: [(String, Expr)] -> Lower Var
lowerRecordExpr fields = do
  fieldResults <- mapM (\(fname, expr) -> do
    v <- lowerExpr expr
    return (fname, v)) fields
  t <- freshVar "_t"
  emit (IRecord t fieldResults)
  return t

-- | Flatten nested let-in chains.
collectLetChain :: Expr -> ([(String, Expr)], Expr)
collectLetChain (LetIn n v b) =
  let (rest, fb) = collectLetChain b
  in ((n, v) : rest, fb)
collectLetChain other = ([], other)

-- ---------------------------------------------------------------------------
-- Ritual lowering
-- ---------------------------------------------------------------------------

lowerRitual :: [Stmt] -> Lower IRFuncBody
lowerRitual stmts = do
  modify' (\s -> s { emittedBlocks = []
                   , currentInstrs = []
                   , currentBlockId = "entry" })

  -- Lower each statement
  letNames <- lowerStmts stmts

  -- Release let bindings in reverse order
  mapM_ (\v -> emit (IRelease v)) (reverse letNames)

  -- Return void
  voidVar <- freshVar "_t"
  emit (IConst voidVar OVoid)
  finishBlockFinal (TReturn voidVar)

  blocks <- collectBlocks
  return (IRFuncBody "arg" blocks)

-- | Lower a list of statements, returning names of let-bound variables
-- (for release at end).
lowerStmts :: [Stmt] -> Lower [Var]
lowerStmts [] = return []
lowerStmts (s : ss) = do
  names <- lowerStmt s
  rest <- lowerStmts ss
  return (names ++ rest)

lowerStmt :: Stmt -> Lower [Var]
lowerStmt (LetStmt name expr) = do
  v <- lowerExpr expr
  let mangledName = cName name
  emit (ICopy mangledName v)
  return [mangledName]
lowerStmt (UtterStmt expr) = do
  v <- lowerExpr expr
  emit (IUtter v)
  emit (IRelease v)
  return []
lowerStmt (WhisperStmt expr) = do
  v <- lowerExpr expr
  emit (IWhisper v)
  emit (IRelease v)
  return []
lowerStmt (ExprStmt expr) = do
  v <- lowerExpr expr
  emit (IRelease v)
  return []

