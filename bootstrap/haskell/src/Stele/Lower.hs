-- | Lowering pass: AST to IR.
--
-- Transforms a typed Stele 'Program' into an 'IRProgram'. This pass
-- resolves all pattern matching, match expressions, and let-in chains
-- into flat instructions and basic block control flow, so that backends
-- (C and AArch64) are purely mechanical translations.
module Stele.Lower
  ( lowerProgram
  ) where

import Stele.AST
import Stele.IR

import Control.Monad (when)
import Control.Monad.Trans.State.Strict (State, evalState, get, gets, modify')
import Data.Char (isUpper)
import qualified Data.Set as Set

-- ---------------------------------------------------------------------------
-- Lowering monad
-- ---------------------------------------------------------------------------

data LowerState = LowerState
  { freshCounter    :: !Int
  , emittedBlocks   :: [Block]     -- accumulated (reversed order)
  , currentInstrs   :: [Instr]     -- current block (reversed order)
  , currentBlockId  :: BlockId
  , nullaryVariants :: Set.Set String  -- names of nullary oneof variants
  , lambdaFuncs     :: [IRDecl]    -- generated lambda functions (reversed)
  , knownFns        :: Set.Set String  -- top-level fn names + builtins
  , localVars       :: Set.Set String  -- variables in scope (for free var analysis)
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
cName name  = "stele_" ++ name

-- | Deduplicate a list, keeping only the last occurrence of each element,
-- then reverse the result.  Used for TCO release lists: when a variable
-- is shadowed, only the final binding survives, so we must release it
-- exactly once.
nubReverse :: Ord a => [a] -> [a]
nubReverse = go [] Set.empty . reverse
  where
    go acc _ [] = acc
    go acc seen (x:xs)
      | Set.member x seen = go acc seen xs
      | otherwise          = go (x:acc) (Set.insert x seen) xs

-- ---------------------------------------------------------------------------
-- Program lowering
-- ---------------------------------------------------------------------------

-- | Lower a complete Stele program to IR.
-- | Built-in function names (from the runtime).
builtinFnNames :: Set.Set String
builtinFnNames = Set.fromList
  [ "read", "write", "argc", "argv", "sh", "terminate"
  , "spawn", "await", "sleep_ms"
  , "strlen", "char_at", "substr", "concat"
  , "int_to_str", "char_of_int", "strcmp"
  ]

lowerProgram :: Program -> IRProgram
lowerProgram (Program decls) = evalState go initState
  where
    -- Collect nullary variant names from oneof declarations
    nullaries = Set.fromList
      [ vname | OneofDecl _ variants <- decls
              , (vname, fields) <- variants
              , null fields
              ]
    -- Collect top-level function names
    topFns = Set.fromList [name | FnDecl name _ <- decls]
    allFns = Set.union topFns builtinFnNames
    initState = LowerState 0 [] [] "entry" nullaries [] allFns Set.empty
    go = do
      irDecls <- concat <$> mapM lowerDecl decls
      s <- get
      return (IRProgram (reverse (lambdaFuncs s) ++ irDecls))

lowerDecl :: Decl -> Lower [IRDecl]
lowerDecl (StructDecl _ _) = return []
lowerDecl (OneofDecl _ _) = return []
lowerDecl (FnDecl name clauses) = do
  body <- lowerFn name clauses
  return [IRFunc name body]
lowerDecl (DoDecl "main" stmts) = do
  body <- lowerDo stmts
  return [IRMain body]
lowerDecl (TestDecl name stmts) = do
  body <- lowerDo stmts
  return [IRTest name body]
lowerDecl (DoDecl _ _) = return []
lowerDecl (ImportDecl _) = return []
lowerDecl (OpenDecl _) = return []

-- ---------------------------------------------------------------------------
-- Fn lowering
-- ---------------------------------------------------------------------------

lowerFn :: String -> [CaseClause] -> Lower IRFuncBody
lowerFn name clauses = do
  -- Reset state for this function
  modify' (\s -> s { emittedBlocks = []
                   , currentInstrs = []
                   , currentBlockId = "entry"
                   , localVars = Set.empty })

  let hasTailCall = any (\(CaseClause _ body) -> isSelfTailCall name body) clauses
  if hasTailCall
    then do
      -- TCO path: retain arg, jump to tco_entry, dispatch with TCO-aware clauses
      tcoLbl <- freshBlock "tco_entry_"
      emit (IRetain "arg")
      finishBlock (TJump tcoLbl) tcoLbl
      lowerClausesTCO "arg" name clauses ("fn '" ++ name ++ "'") tcoLbl
    else
      -- Normal path
      lowerClauses "arg" clauses ("fn '" ++ name ++ "'") TReturn

  blocks <- collectBlocks
  return (IRFuncBody "arg" blocks)

-- | Lower a sequence of case clauses into a chain of test blocks.
-- The continuation says what to do with the result of a successful match.
lowerClauses :: Var -> [CaseClause] -> String
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
  mapM_ (\(clauseLbl, nextLbl, CaseClause pat body) ->
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
  -- Add pattern-bound names to localVars so closures in the body can capture them
  let patNames = patternBoundNames pat
  savedLocals <- localVars <$> get
  modify' (\st -> st { localVars = Set.union patNames (localVars st) })
  result <- lowerExpr body
  -- Restore localVars and release pattern bindings in reverse order
  modify' (\st -> st { localVars = savedLocals })
  mapM_ (\v -> emit (IRelease v)) (reverse bindings)
  finishBlockFinal (mkTerm result)

-- | TCO-aware clause lowering. Structurally identical to 'lowerClauses'
-- but delegates to 'lowerClauseTCO' which handles tail-call vs non-tail clauses.
lowerClausesTCO :: Var -> String -> [CaseClause] -> String -> BlockId -> Lower ()
lowerClausesTCO scrut fnName clauses failMsg tcoEntryLbl = do
  failLbl <- freshBlock "match_fail_"
  clauseLabels <- mapM (\(i, _) -> freshBlock ("clause_" ++ show i ++ "_test_")) (zip [(0::Int)..] clauses)
  let nextLabels = drop 1 clauseLabels ++ [failLbl]

  -- Jump to first clause
  let firstLbl = case clauseLabels of
        (l:_) -> l
        []    -> failLbl
  finishBlock (TJump firstLbl) firstLbl

  -- Emit each clause
  mapM_ (\(clauseLbl, nextLbl, CaseClause pat body) ->
    lowerClauseTCO scrut fnName pat body clauseLbl nextLbl tcoEntryLbl
    ) (zip3 clauseLabels nextLabels clauses)

  -- Match fail block
  modify' (\s -> s { currentBlockId = failLbl })
  finishBlockFinal (TMatchFail failMsg)

-- | Lower a single clause with TCO awareness.
-- Delegates body lowering to 'lowerTailBody' which recursively handles
-- tail calls inside LetIn chains and Match arms.
lowerClauseTCO :: Var -> String -> Pattern -> Expr -> BlockId -> BlockId
               -> BlockId -> Lower ()
lowerClauseTCO scrut fnName pat body clauseLbl nextLbl tcoEntryLbl = do
  modify' (\s -> s { currentBlockId = clauseLbl, currentInstrs = [] })
  bodyLbl <- freshBlock "clause_body_"
  lowerPatternTest scrut pat bodyLbl nextLbl
  modify' (\s -> s { currentBlockId = bodyLbl, currentInstrs = [] })
  bindings <- lowerPatternBindings scrut pat
  -- Add pattern-bound names to localVars so closures in the body can capture them
  let patNames = patternBoundNames pat
  modify' (\st -> st { localVars = Set.union patNames (localVars st) })
  lowerTailBody fnName body bindings tcoEntryLbl

-- | Lower an expression in tail position, recursively handling LetIn chains
-- and Match arms. Accumulates bindings that must be released before any
-- tail jump or return.
lowerTailBody :: String -> Expr -> [Var] -> BlockId -> Lower ()
lowerTailBody fnName (Call callee argExpr) outerBindings tcoEntryLbl
  | callee == fnName = do
      -- TAIL CALL: evaluate new arg, release all bindings + old arg, loop
      -- Deduplicate to avoid double-freeing shadowed variables
      let dedupBindings = nubReverse outerBindings
      varg <- lowerExpr argExpr
      mapM_ (\v -> emit (IRelease v)) dedupBindings
      emit (IRelease "arg")
      emit (ICopy "arg" varg)
      finishBlock (TJump tcoEntryLbl) tcoEntryLbl
lowerTailBody fnName expr@(LetIn _ _ _) outerBindings tcoEntryLbl = do
  let (bindings, finalBody) = collectLetChain expr
  -- Lower each binding, accumulating names
  boundNames <- mapM (\(n, v) -> do
    vr <- lowerExpr v
    let mangledName = cName n
    emit (ICopy mangledName vr)
    return mangledName
    ) bindings
  -- Recurse into final body with extended bindings
  lowerTailBody fnName finalBody (outerBindings ++ boundNames) tcoEntryLbl
lowerTailBody fnName (Match scrutinee clauses) outerBindings tcoEntryLbl = do
  -- Lower scrutinee
  scrResult <- lowerExpr scrutinee
  scr <- freshVar "_scr"
  emit (ICopy scr scrResult)
  -- Dispatch each arm via lowerTailMatchClause
  let allBindings = outerBindings ++ [scr]
  failLbl <- freshBlock "match_fail_"
  clauseLabels <- mapM (\(i, _) -> freshBlock ("tmclause_" ++ show i ++ "_test_"))
                       (zip [(0::Int)..] clauses)
  let nextLabels = drop 1 clauseLabels ++ [failLbl]
  let firstLbl = case clauseLabels of
        (l:_) -> l
        []    -> failLbl
  finishBlock (TJump firstLbl) firstLbl
  mapM_ (\(clauseLbl, nextLbl, CaseClause pat armBody) ->
    lowerTailMatchClause fnName scr pat armBody clauseLbl nextLbl allBindings tcoEntryLbl
    ) (zip3 clauseLabels nextLabels clauses)
  -- Match fail block
  modify' (\s -> s { currentBlockId = failLbl })
  finishBlockFinal (TMatchFail "match")
lowerTailBody _ expr outerBindings _ = do
  -- FALLBACK (base case): evaluate body, release all bindings + old arg, return
  -- Deduplicate to avoid double-freeing shadowed variables
  let dedupBindings = nubReverse outerBindings
  result <- lowerExpr expr
  mapM_ (\v -> emit (IRelease v)) dedupBindings
  emit (IRelease "arg")
  finishBlockFinal (TReturn result)

-- | Lower a single match arm in tail position. Pattern test + bindings are
-- handled normally, then body is delegated to 'lowerTailBody'.
lowerTailMatchClause :: String -> Var -> Pattern -> Expr
                     -> BlockId -> BlockId -> [Var] -> BlockId -> Lower ()
lowerTailMatchClause fnName scrut pat armBody clauseLbl nextLbl outerBindings tcoEntryLbl = do
  modify' (\s -> s { currentBlockId = clauseLbl, currentInstrs = [] })
  bodyLbl <- freshBlock "tmclause_body_"
  lowerPatternTest scrut pat bodyLbl nextLbl
  modify' (\s -> s { currentBlockId = bodyLbl, currentInstrs = [] })
  patBindings <- lowerPatternBindings scrut pat
  let patNames = patternBoundNames pat
  modify' (\st -> st { localVars = Set.union patNames (localVars st) })
  lowerTailBody fnName armBody (outerBindings ++ patBindings) tcoEntryLbl

-- ---------------------------------------------------------------------------
-- Pattern matching: test generation
-- ---------------------------------------------------------------------------

-- | Generate tests for a pattern, branching to bodyLbl on success
-- or nextLbl on failure. May emit multiple blocks for complex patterns.
lowerPatternTest :: Var -> Pattern -> BlockId -> BlockId -> Lower ()
lowerPatternTest _scrut PWild bodyLbl _nextLbl = do
  finishBlock (TJump bodyLbl) bodyLbl
lowerPatternTest scrut (PVar name) bodyLbl nextLbl = do
  s <- get
  if Set.member name (nullaryVariants s)
    then do
      -- Nullary variant pattern: check __tag == name
      tc <- freshVar "_tc"
      emit (ITagCheck tc scrut TagRecord)
      tagCheckLbl <- freshBlock "nvtag_"
      finishBlock (TBranch tc tagCheckLbl nextLbl) tagCheckLbl
      tagFv <- freshVar "_vtag_"
      emit (IFieldGet tagFv scrut "__tag")
      tagNc <- freshVar "_tnc"
      emit (INullCheck tagNc tagFv)
      tagEqLbl <- freshBlock "nvteq_"
      finishBlock (TBranch tagNc tagEqLbl nextLbl) tagEqLbl
      tagEq <- freshVar "_teq"
      emit (IStrEq tagEq tagFv name)
      finishBlock (TBranch tagEq bodyLbl nextLbl) bodyLbl
    else
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
lowerPatternTest scrut (PVariant vname innerPat) bodyLbl nextLbl = do
  -- Variant pattern: check it's a record, check __tag == vname, then check inner fields
  tc <- freshVar "_tc"
  emit (ITagCheck tc scrut TagRecord)
  tagCheckLbl <- freshBlock "vartag_"
  finishBlock (TBranch tc tagCheckLbl nextLbl) tagCheckLbl
  -- Get __tag field
  tagFv <- freshVar "_vtag_"
  emit (IFieldGet tagFv scrut "__tag")
  tagNc <- freshVar "_tnc"
  emit (INullCheck tagNc tagFv)
  tagValLbl <- freshBlock "vartagval_"
  finishBlock (TBranch tagNc tagValLbl nextLbl) tagValLbl
  -- Check __tag string value
  tagEq <- freshVar "_teq"
  emit (IStrEq tagEq tagFv vname)
  -- Now check inner pattern fields
  case innerPat of
    PRec fields ->
      if null fields
        then finishBlock (TBranch tagEq bodyLbl nextLbl) bodyLbl
        else do
          innerLbl <- freshBlock "varfields_"
          finishBlock (TBranch tagEq innerLbl nextLbl) innerLbl
          lowerRecFieldTests scrut fields bodyLbl nextLbl
    _ -> finishBlock (TBranch tagEq bodyLbl nextLbl) bodyLbl
lowerPatternTest _ (PLit _) _ nextLbl = do
  finishBlock (TJump nextLbl) nextLbl
lowerPatternTest scrut (PQualVariant modN vname innerPat) bodyLbl nextLbl =
  lowerPatternTest scrut (PVariant (modN ++ "__" ++ vname) innerPat) bodyLbl nextLbl

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
  s <- get
  if Set.member name (nullaryVariants s)
    then return []  -- nullary variant pattern: no variables to bind
    else do
      let v = cName name
      emit (ICopy v scrut)
      emit (IRetain v)
      return [v]
lowerPatternBindings _ PWild = return []
lowerPatternBindings _ (PLit _) = return []
lowerPatternBindings scrut (PRec fields) =
  concat <$> mapM (lowerFieldBinding scrut) fields
lowerPatternBindings scrut (PVariant _ innerPat) =
  lowerPatternBindings scrut innerPat
lowerPatternBindings scrut (PQualVariant modN vname innerPat) =
  lowerPatternBindings scrut (PVariant (modN ++ "__" ++ vname) innerPat)

lowerFieldBinding :: Var -> PatField -> Lower [Var]
lowerFieldBinding scrut (PatField fname mPat) = do
  let isTypeLike n = n `elem` ["Int", "String", "Void"] || (not (null n) && isUpper (head n))
  let boundName = case mPat of
        Just (PVar n)
          | isTypeLike n -> Just fname
          | otherwise    -> Just n
        Just PWild -> Nothing
        _          -> Just fname
  fv <- freshVar ("_fb_" ++ fname ++ "_")
  emit (IFieldGet fv scrut fname)
  case boundName of
    Nothing -> return []
    Just n -> do
      let v = cName n
      emit (ICopy v fv)
      emit (IRetain v)
      return [v]

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
  s <- get
  if Set.member name (nullaryVariants s)
    then do
      -- Nullary variant: construct {| __tag: "Name" |}
      tagVar <- freshVar "_tag"
      emit (IConst tagVar (OStr name))
      t <- freshVar "_t"
      emit (IRecord t [("__tag", tagVar)])
      return t
    else do
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

lowerExpr (NamedRecord typeName fields) = do
  -- Emit a __tag field with the type name, then the user fields
  tagVar <- freshVar "_tag"
  emit (IConst tagVar (OStr typeName))
  fieldResults <- mapM (\(fname, expr) -> do
    v <- lowerExpr expr
    return (fname, v)) fields
  t <- freshVar "_t"
  emit (IRecord t (("__tag", tagVar) : fieldResults))
  return t

lowerExpr (Call fnName arg) = do
  s <- get
  if Set.member fnName (knownFns s)
    then do
      -- Direct function call
      varg <- lowerExpr arg
      t <- freshVar "_t"
      emit (ICall t fnName varg)
      emit (IRelease varg)
      return t
    else do
      -- Closure call: load the variable, call via stele_call_closure
      closVar <- freshVar "_t"
      emit (ICopy closVar (cName fnName))
      emit (IRetain closVar)
      varg <- lowerExpr arg
      t <- freshVar "_t"
      emit (ICallClosure t closVar varg)
      emit (IRelease closVar)
      emit (IRelease varg)
      return t

lowerExpr ReadLn = do
  t <- freshVar "_t"
  emit (IReadLn t)
  return t

lowerExpr ReadInt = do
  t <- freshVar "_t"
  emit (IReadInt t)
  return t

lowerExpr (LetIn name value body) = do
  -- Flatten let-in chains
  let (bindings, finalBody) = collectLetChain (LetIn name value body)
  -- Lower each binding, tracking locals
  boundNames <- mapM (\(n, v) -> do
    vr <- lowerExpr v
    let mangledName = cName n
    -- If this variable was already bound, release the old value before reassignment
    locals <- gets localVars
    let alreadyBound = Set.member n locals
    when alreadyBound $ emit (IRelease mangledName)
    emit (ICopy mangledName vr)
    modify' (\st -> st { localVars = Set.insert n (localVars st) })
    -- Return Nothing for already-bound names to avoid duplicate releases
    return (if alreadyBound then Nothing else Just mangledName)
    ) bindings
  let uniqueBoundNames = [n | Just n <- boundNames]
  -- Lower body
  result <- lowerExpr finalBody
  -- Release bindings in reverse order
  mapM_ (\v -> emit (IRelease v)) (reverse uniqueBoundNames)
  return result

lowerExpr (Closure clauses) = do
  -- Free variable analysis
  let patBound cl = patternBoundNames (casePattern cl)
      bodyFree cl = Set.difference (exprFreeVars (caseBody cl)) (patBound cl)
      allFree = Set.unions (map bodyFree clauses)
  s <- get
  let captured = Set.toList (Set.intersection allFree (localVars s))
  -- Generate a fresh lambda name and register it as a known function
  lambdaName <- freshVar "_lambda"
  modify' (\st -> st { knownFns = Set.insert lambdaName (knownFns st) })
  -- Save state and generate lambda body as a top-level function
  let savedBlocks = emittedBlocks s
      savedInstrs = currentInstrs s
      savedBlockId = currentBlockId s
      savedLocals = localVars s
  modify' (\st -> st { emittedBlocks = [], currentInstrs = [], currentBlockId = "entry"
                      , localVars = Set.empty })
  -- Extract captured variables from arg (env is merged into arg at call time).
  -- No retain needed: arg stays alive for the entire function call, so
  -- field pointers remain valid.  Body references do their own retain/release.
  mapM_ (\v -> do
    let mangledName = cName v
    emit (IFieldGet mangledName "arg" v)
    modify' (\st -> st { localVars = Set.insert v (localVars st) })
    ) captured
  -- Lower the lambda body like a fn
  lowerClauses "arg" clauses ("closure '" ++ lambdaName ++ "'") TReturn
  blocks <- collectBlocks
  let lambdaBody = IRFuncBody "arg" blocks
  -- Restore state and register the lambda
  modify' (\st -> st { emittedBlocks = savedBlocks
                      , currentInstrs = savedInstrs
                      , currentBlockId = savedBlockId
                      , localVars = savedLocals
                      , lambdaFuncs = IRFunc lambdaName lambdaBody : lambdaFuncs st })
  -- Emit closure creation: make_closure(fn_lambda_N, env_record)
  t <- freshVar "_t"
  let envFields = map (\v -> (v, cName v)) captured
  emit (IClosure t lambdaName envFields)
  return t

lowerExpr (Match scrutinee clauses) = do
  scrResult <- lowerExpr scrutinee
  scr <- freshVar "_scr"
  emit (ICopy scr scrResult)

  mch <- freshVar "_mch"
  doneLbl <- freshBlock "match_done_"

  -- Lower match clauses
  lowerMatchClauses scr mch doneLbl clauses

  -- Done block: release scrutinee, result is in mch
  modify' (\s -> s { currentBlockId = doneLbl, currentInstrs = [] })
  emit (IRelease scr)
  return mch

-- Qualified expressions are resolved before lowering; treat as their
-- desugared forms if they somehow reach here.
lowerExpr (QualCall modN fn arg) = lowerExpr (Call (modN ++ "__" ++ fn) arg)
lowerExpr (QualVar modN name) = lowerExpr (Var (modN ++ "__" ++ name))
lowerExpr (QualRecord modN typN fields) = lowerExpr (NamedRecord (modN ++ "__" ++ typN) fields)

-- | Lower match clauses - like fn clauses but write to a result var
-- and jump to a done label instead of returning.
lowerMatchClauses :: Var -> Var -> BlockId -> [CaseClause] -> Lower ()
lowerMatchClauses scrut mch doneLbl clauses = do
  failLbl <- freshBlock "match_fail_"
  clauseLabels <- mapM (\(i, _) -> freshBlock ("mclause_" ++ show i ++ "_test_")) (zip [(0::Int)..] clauses)
  let nextLabels = drop 1 clauseLabels ++ [failLbl]

  let firstLbl = case clauseLabels of
        (l:_) -> l
        []    -> failLbl
  finishBlock (TJump firstLbl) firstLbl

  mapM_ (\(clauseLbl, nextLbl, CaseClause pat body) ->
    lowerMatchClause scrut mch doneLbl pat body clauseLbl nextLbl
    ) (zip3 clauseLabels nextLabels clauses)

  -- Match fail block
  modify' (\s -> s { currentBlockId = failLbl })
  finishBlockFinal (TMatchFail "match")

-- | Lower a single match clause.
lowerMatchClause :: Var -> Var -> BlockId -> Pattern -> Expr
                  -> BlockId -> BlockId -> Lower ()
lowerMatchClause scrut mch doneLbl pat body clauseLbl nextLbl = do
  modify' (\s -> s { currentBlockId = clauseLbl, currentInstrs = [] })
  bodyLbl <- freshBlock "mclause_body_"
  lowerPatternTest scrut pat bodyLbl nextLbl

  -- Body block
  modify' (\s -> s { currentBlockId = bodyLbl, currentInstrs = [] })
  bindings <- lowerPatternBindings scrut pat
  let patNames = patternBoundNames pat
  savedLocals <- localVars <$> get
  modify' (\st -> st { localVars = Set.union patNames (localVars st) })
  result <- lowerExpr body
  modify' (\st -> st { localVars = savedLocals })
  mapM_ (\v -> emit (IRelease v)) (reverse bindings)
  emit (ICopy mch result)
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

-- | Check whether an expression contains a self-recursive tail call.
-- Looks through LetIn chains (tail position is the final body) and
-- Match arms (TCO-eligible if any arm contains a tail call).
isSelfTailCall :: String -> Expr -> Bool
isSelfTailCall fnName (Call callee _) = callee == fnName
isSelfTailCall fnName (LetIn _ _ body) = isSelfTailCall fnName body
isSelfTailCall fnName (Match _ clauses) =
  any (\(CaseClause _ body) -> isSelfTailCall fnName body) clauses
isSelfTailCall _ _ = False

-- ---------------------------------------------------------------------------
-- Do lowering
-- ---------------------------------------------------------------------------

lowerDo :: [Stmt] -> Lower IRFuncBody
lowerDo stmts = do
  modify' (\s -> s { emittedBlocks = []
                   , currentInstrs = []
                   , currentBlockId = "entry"
                   , localVars = Set.empty })

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
  -- If this variable was already bound, release the old value before reassignment
  locals <- gets localVars
  let alreadyBound = Set.member name locals
  when alreadyBound $ emit (IRelease mangledName)
  emit (ICopy mangledName v)
  modify' (\st -> st { localVars = Set.insert name (localVars st) })
  -- Only add to release list if this is a new binding (avoid duplicate releases)
  if alreadyBound then return [] else return [mangledName]
lowerStmt (PrintStmt expr) = do
  v <- lowerExpr expr
  emit (IPrint v)
  emit (IRelease v)
  return []
lowerStmt (WriteStmt expr) = do
  v <- lowerExpr expr
  t <- freshVar "_t"
  emit (ICall t "write" v)
  emit (IRelease v)
  emit (IRelease t)
  return []
lowerStmt (ExprStmt expr) = do
  v <- lowerExpr expr
  emit (IRelease v)
  return []

-- ---------------------------------------------------------------------------
-- Free variable analysis
-- ---------------------------------------------------------------------------

-- | Collect free variable references from an expression.
exprFreeVars :: Expr -> Set.Set String
exprFreeVars (IntLit _) = Set.empty
exprFreeVars (StrLit _) = Set.empty
exprFreeVars (Var name) = Set.singleton name
exprFreeVars (BinOp _ e1 e2) = Set.union (exprFreeVars e1) (exprFreeVars e2)
exprFreeVars (UnOp _ e) = exprFreeVars e
exprFreeVars (FieldAccess e _) = exprFreeVars e
exprFreeVars (Record fields) = Set.unions [exprFreeVars e | (_, e) <- fields]
exprFreeVars (NamedRecord _ fields) = Set.unions [exprFreeVars e | (_, e) <- fields]
exprFreeVars (Call fn arg) = Set.insert fn (exprFreeVars arg)
exprFreeVars (LetIn name val body) =
  Set.union (exprFreeVars val) (Set.delete name (exprFreeVars body))
exprFreeVars (Match scrut clauses) =
  Set.union (exprFreeVars scrut) (Set.unions (map clauseFreeVars clauses))
exprFreeVars (Closure clauses) = Set.unions (map clauseFreeVars clauses)
exprFreeVars ReadLn = Set.empty
exprFreeVars ReadInt = Set.empty
exprFreeVars (QualCall modN fn arg) = Set.insert (modN ++ "__" ++ fn) (exprFreeVars arg)
exprFreeVars (QualVar modN name) = Set.singleton (modN ++ "__" ++ name)
exprFreeVars (QualRecord modN _ fields) = Set.unions (Set.singleton modN : [exprFreeVars e | (_, e) <- fields])

-- | Free variables in a case clause (body minus pattern bindings).
clauseFreeVars :: CaseClause -> Set.Set String
clauseFreeVars (CaseClause pat body) =
  Set.difference (exprFreeVars body) (patternBoundNames pat)

-- | Names bound by a pattern.
patternBoundNames :: Pattern -> Set.Set String
patternBoundNames (PVar name) = Set.singleton name
patternBoundNames (PLit _) = Set.empty
patternBoundNames PWild = Set.empty
patternBoundNames (PRec fields) = Set.unions
  [patFieldBoundNames pf | pf <- fields]
patternBoundNames (PVariant _ inner) = patternBoundNames inner
patternBoundNames (PQualVariant _ _ inner) = patternBoundNames inner

-- | Names bound by a pattern field.
patFieldBoundNames :: PatField -> Set.Set String
patFieldBoundNames (PatField name mPat) =
  case mPat of
    Nothing -> Set.singleton name
    Just (PVar n) -> if isTypeLike n then Set.singleton name else Set.singleton n
    Just PWild -> Set.empty
    Just _ -> Set.singleton name
  where
    isTypeLike n = n `elem` ["Int", "String", "Void"] ||
                   (not (null n) && isUpper (head n))
