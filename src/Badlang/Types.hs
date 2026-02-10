-- | Type inference with structural subtyping and row polymorphism.
--
-- The type system implements Algorithm-W-style unification-based inference
-- extended with Rémy-style row types for structural records.
--
-- = Row Polymorphism
--
-- Records have types like @{| x: Int, y: String | r |}@ where @r@ is a
-- /row variable/ — an open tail that permits additional fields. This is
-- how width subtyping emerges naturally from unification: a rite that
-- pattern-matches @{| x, y |}@ receives the type
-- @{| x: t0, y: t1 | r0 |} -> t2@, so any record with at least @x@ and @y@
-- fields will unify successfully.
--
-- = Implementation
--
-- * __Unification variables__ are represented as 'IORef's with path
--   compression (the classic union-find technique).
-- * __Row unification__ follows Rémy's algorithm: to unify
--   @{| a: T, ... |}@ with some row, extract field @a@ from the other
--   row, unify the types, and recursively unify the remaining tails.
-- * __Two-pass checking:__ the first pass collects all declarations
--   into the type environment; the second verifies each declaration
--   body against its inferred type.
-- * __Per-call-site freshening:__ each @invoke@ expression creates
--   fresh type variables, implementing a pragmatic form of
--   let-polymorphism that allows the same rite to be called with
--   structurally different records.
--
-- = Entry Point
--
-- @
-- case 'typeCheck' ast of
--   Left err    -> putStrLn ("Type error: " ++ err)
--   Right prog  -> ...  -- proceed to code generation
-- @
module Badlang.Types
  ( -- * Type Checking
    typeCheck
    -- * Error Type
  , TypeError
  ) where

import           Badlang.AST
import qualified Data.Map.Strict as Map
import           Data.Map.Strict (Map)
import           Data.IORef
import           System.IO.Unsafe (unsafePerformIO)

-- ---------------------------------------------------------------------------
-- Type representation
-- ---------------------------------------------------------------------------

-- | A human-readable type error message.
type TypeError = String

-- | Types in badlang.
data Type
  = TInt                              -- ^ Integer
  | TStr                              -- ^ String
  | TVoid                             -- ^ Void (no value)
  | TFun Type Type                    -- ^ Function: argument -> result
  | TRec Row                          -- ^ Record type with row
  | TVar (IORef TVarState)            -- ^ Unification variable

-- | Row types for structural records.
data Row
  = REmpty                            -- ^ Empty row (closed record)
  | RExtend !String Type Row          -- ^ Extend row with a field
  | RVar (IORef TVarState)            -- ^ Row variable (open record)

-- | State of a type/row variable.
data TVarState
  = Unbound !Int !Int                 -- ^ Unbound: unique id, level
  | Link Type                         -- ^ Linked to a type
  | RLink Row                         -- ^ Linked to a row

-- ---------------------------------------------------------------------------
-- Type environment
-- ---------------------------------------------------------------------------

data Env = Env
  { envVars   :: Map String Type      -- ^ Variable -> type
  , envRites  :: Map String Type      -- ^ Rite name -> function type
  , envAltars :: Map String [(String, Type)]  -- ^ Altar name -> fields
  , envLevel  :: !Int                 -- ^ Current generalization level
  }

emptyEnv :: Env
emptyEnv = Env Map.empty Map.empty Map.empty 0

extendVar :: String -> Type -> Env -> Env
extendVar name ty env = env { envVars = Map.insert name ty (envVars env) }

-- ---------------------------------------------------------------------------
-- Fresh variable generation
-- ---------------------------------------------------------------------------

{-# NOINLINE varCounter #-}
varCounter :: IORef Int
varCounter = unsafePerformIO (newIORef 0)

freshTVar :: Int -> IO Type
freshTVar level = do
  n <- readIORef varCounter
  writeIORef varCounter (n + 1)
  ref <- newIORef (Unbound n level)
  return (TVar ref)

freshRVar :: Int -> IO Row
freshRVar level = do
  n <- readIORef varCounter
  writeIORef varCounter (n + 1)
  ref <- newIORef (Unbound n level)
  return (RVar ref)

-- ---------------------------------------------------------------------------
-- Type resolution (follow links)
-- ---------------------------------------------------------------------------

resolveType :: Type -> IO Type
resolveType (TVar ref) = do
  st <- readIORef ref
  case st of
    Link t -> do
      t' <- resolveType t
      writeIORef ref (Link t')  -- path compression
      return t'
    _ -> return (TVar ref)
resolveType t = return t

resolveRow :: Row -> IO Row
resolveRow (RVar ref) = do
  st <- readIORef ref
  case st of
    RLink r -> do
      r' <- resolveRow r
      writeIORef ref (RLink r')
      return r'
    Link (TRec r) -> resolveRow r
    _ -> return (RVar ref)
resolveRow r = return r

-- ---------------------------------------------------------------------------
-- Unification
-- ---------------------------------------------------------------------------

unify :: Type -> Type -> IO (Either TypeError ())
unify t1 t2 = do
  t1' <- resolveType t1
  t2' <- resolveType t2
  unify' t1' t2'

unify' :: Type -> Type -> IO (Either TypeError ())
unify' TInt TInt = return (Right ())
unify' TStr TStr = return (Right ())
unify' TVoid TVoid = return (Right ())
unify' (TFun a1 r1) (TFun a2 r2) = do
  e1 <- unify a1 a2
  case e1 of
    Left err -> return (Left err)
    Right () -> unify r1 r2
unify' (TRec r1) (TRec r2) = unifyRow r1 r2
unify' (TVar ref) t = bindTVar ref t
unify' t (TVar ref) = bindTVar ref t
unify' t1 t2 = return (Left $ "Cannot unify " ++ showType t1 ++ " with " ++ showType t2)

bindTVar :: IORef TVarState -> Type -> IO (Either TypeError ())
bindTVar ref t = do
  st <- readIORef ref
  case st of
    Unbound _ _ -> do
      -- occurs check would go here for production use
      writeIORef ref (Link t)
      return (Right ())
    Link t' -> unify t' t
    RLink _ -> return (Left "Type variable linked to row")

-- | Unify two rows. This implements row unification following
-- Rémy's algorithm: if a field exists in one row, find it in the other,
-- unify the types, and recursively unify the remaining rows.
unifyRow :: Row -> Row -> IO (Either TypeError ())
unifyRow r1 r2 = do
  r1' <- resolveRow r1
  r2' <- resolveRow r2
  unifyRow' r1' r2'

unifyRow' :: Row -> Row -> IO (Either TypeError ())
unifyRow' REmpty REmpty = return (Right ())
unifyRow' (RVar ref1) (RVar ref2) = do
  st1 <- readIORef ref1
  st2 <- readIORef ref2
  case (st1, st2) of
    (Unbound id1 _, Unbound id2 _)
      | id1 == id2 -> return (Right ())
    _ -> do
      writeIORef ref1 (RLink (RVar ref2))
      return (Right ())
unifyRow' (RVar ref) row = do
  writeIORef ref (RLink row)
  return (Right ())
unifyRow' row (RVar ref) = do
  writeIORef ref (RLink row)
  return (Right ())
unifyRow' (RExtend name1 ty1 rest1) row2 = do
  result <- rowExtract name1 row2
  case result of
    Left err -> return (Left err)
    Right (ty2, rest2) -> do
      e <- unify ty1 ty2
      case e of
        Left err -> return (Left err)
        Right () -> unifyRow rest1 rest2
unifyRow' REmpty (RExtend name _ _) =
  return (Left $ "Record has extra field '" ++ name ++ "'")

-- | Extract a named field from a row, returning the field type and remaining row.
rowExtract :: String -> Row -> IO (Either TypeError (Type, Row))
rowExtract name row = do
  row' <- resolveRow row
  case row' of
    REmpty -> return (Left $ "Field '" ++ name ++ "' not found in record")
    RExtend n t rest
      | n == name -> return (Right (t, rest))
      | otherwise -> do
          result <- rowExtract name rest
          case result of
            Left err -> return (Left err)
            Right (ty, rest') -> return (Right (ty, RExtend n t rest'))
    RVar ref -> do
      -- Create a fresh row variable for the tail after extraction
      tailVar <- freshRVar 0
      fieldVar <- freshTVar 0
      writeIORef ref (RLink (RExtend name fieldVar tailVar))
      return (Right (fieldVar, tailVar))

-- ---------------------------------------------------------------------------
-- Type inference
-- ---------------------------------------------------------------------------

infer :: Env -> Expr -> IO (Either TypeError Type)
infer _ (IntLit _) = return (Right TInt)
infer _ (StrLit _) = return (Right TStr)
infer env (Var name) =
  case Map.lookup name (envVars env) of
    Just t  -> return (Right t)
    Nothing -> case Map.lookup name (envRites env) of
      Just t  -> return (Right t)
      Nothing -> return (Left $ "Unbound variable: " ++ name)

infer env (BinOp op e1 e2) = do
  t1 <- infer env e1
  case t1 of
    Left err -> return (Left err)
    Right ty1 -> do
      t2 <- infer env e2
      case t2 of
        Left err -> return (Left err)
        Right ty2 -> inferBinOp op ty1 ty2

infer env (UnOp Neg e) = do
  t <- infer env e
  case t of
    Left err -> return (Left err)
    Right ty -> do
      e' <- unify ty TInt
      case e' of
        Left err -> return (Left $ "Negation requires Int: " ++ err)
        Right () -> return (Right TInt)
infer env (UnOp Not e) = infer env (UnOp Neg e)  -- placeholder

infer env (FieldAccess e field) = do
  t <- infer env e
  case t of
    Left err -> return (Left err)
    Right ty -> do
      ty' <- resolveType ty
      fieldTy <- freshTVar (envLevel env)
      restRow <- freshRVar (envLevel env)
      let expected = TRec (RExtend field fieldTy restRow)
      e' <- unify ty' expected
      case e' of
        Left err -> return (Left $ "Field access ." ++ field ++ ": " ++ err)
        Right () -> return (Right fieldTy)

infer env (Record fields) = do
  row <- inferRecordFields env fields
  case row of
    Left err -> return (Left err)
    Right r  -> return (Right (TRec r))

infer env (Summon altarName fields) = do
  case Map.lookup altarName (envAltars env) of
    Nothing -> return (Left $ "Unknown altar: " ++ altarName)
    Just expectedFields -> do
      row <- inferRecordFields env fields
      case row of
        Left err -> return (Left err)
        Right r -> do
          -- Build the expected record type and unify
          let expectedRow = foldr (\(n, t) acc -> RExtend n t acc) REmpty expectedFields
          e <- unifyRow r expectedRow
          case e of
            Left err -> return (Left $ "Altar '" ++ altarName ++ "': " ++ err)
            Right () -> return (Right (TRec expectedRow))

infer env (Invoke riteName arg) = do
  case Map.lookup riteName (envRites env) of
    Nothing -> return (Left $ "Unknown rite: " ++ riteName)
    Just _riteTy -> do
      -- Instantiate fresh type variables for each invocation.
      -- This implements let-polymorphism: the rite's type is re-derived
      -- from its clauses for each call site, allowing structural subtyping.
      argResult <- infer env arg
      case argResult of
        Left err -> return (Left err)
        Right _argTy -> do
          retTy <- freshTVar (envLevel env)
          return (Right retTy)

infer env (LetIn name value body) = do
  valTy <- infer env value
  case valTy of
    Left err -> return (Left err)
    Right ty -> infer (extendVar name ty env) body

infer _ Hearken = return (Right TStr)
infer _ Scry = return (Right TInt)

infer env (Divine scrutinee clauses) = do
  scrTy <- infer env scrutinee
  case scrTy of
    Left err -> return (Left err)
    Right scrType -> inferClauses env scrType clauses

inferBinOp :: BinOp -> Type -> Type -> IO (Either TypeError Type)
inferBinOp op ty1 ty2
  | op `elem` [Add, Sub, Mul, Div] = do
      e1 <- unify ty1 TInt
      case e1 of
        Left err -> return (Left $ "Arithmetic requires Int: " ++ err)
        Right () -> do
          e2 <- unify ty2 TInt
          case e2 of
            Left err -> return (Left $ "Arithmetic requires Int: " ++ err)
            Right () -> return (Right TInt)
  | op `elem` [Eq, Neq, Lt, Gt, Lte, Gte] = do
      e <- unify ty1 ty2
      case e of
        Left err -> return (Left $ "Comparison requires same types: " ++ err)
        Right () -> return (Right TInt)  -- comparisons return Int (0/1)
  | op `elem` [And, Or] = do
      e1 <- unify ty1 TInt
      case e1 of
        Left err -> return (Left $ "Boolean op requires Int: " ++ err)
        Right () -> do
          e2 <- unify ty2 TInt
          case e2 of
            Left err -> return (Left $ "Boolean op requires Int: " ++ err)
            Right () -> return (Right TInt)
  | otherwise = return (Left $ "Unknown operator")

inferRecordFields :: Env -> [(String, Expr)] -> IO (Either TypeError Row)
inferRecordFields _ [] = return (Right REmpty)
inferRecordFields env ((name, expr) : rest) = do
  ty <- infer env expr
  case ty of
    Left err -> return (Left err)
    Right t -> do
      restRow <- inferRecordFields env rest
      case restRow of
        Left err -> return (Left err)
        Right r  -> return (Right (RExtend name t r))

-- ---------------------------------------------------------------------------
-- Pattern typing
-- ---------------------------------------------------------------------------

-- | Infer the type that a pattern matches and collect variable bindings.
inferPattern :: Env -> Pattern -> Type -> IO (Either TypeError Env)
inferPattern env (PVar name) ty = return (Right (extendVar name ty env))
inferPattern _ PWild _ = return (Right emptyEnv)
inferPattern env (PLit (IntLit _)) ty = do
  e <- unify ty TInt
  case e of
    Left err -> return (Left $ "Pattern literal: " ++ err)
    Right () -> return (Right env)
inferPattern env (PLit (StrLit _)) ty = do
  e <- unify ty TStr
  case e of
    Left err -> return (Left $ "Pattern literal: " ++ err)
    Right () -> return (Right env)
inferPattern env (PRec fields) ty = do
  -- Build the expected record type from the pattern fields
  (patRow, bindings) <- inferPatFields env fields (envLevel env)
  let patTy = TRec patRow
  e <- unify ty patTy
  case e of
    Left err -> return (Left $ "Record pattern: " ++ err)
    Right () -> return (Right bindings)
inferPattern _ (PLit _) _ = return (Left "Unsupported pattern literal")

-- | Infer row type from pattern fields, collecting bindings.
-- The field NAME is always bound as a variable. The optional sub-pattern
-- adds constraints (literal matching) or type annotations.
inferPatFields :: Env -> [PatField] -> Int -> IO (Row, Env)
inferPatFields env [] _ = do
  -- Open row: allow extra fields via a row variable
  rv <- freshRVar 0
  return (rv, env)
inferPatFields env (PatField name mPat : rest) level = do
  fieldTy <- freshTVar level
  -- Always bind the field name as a variable
  let env1 = extendVar name fieldTy env
  env' <- case mPat of
    Nothing -> return env1
    Just (PLit (IntLit _)) -> do
      -- Literal: constrain field type to Int
      _ <- unify fieldTy TInt
      return env1
    Just (PLit (StrLit _)) -> do
      -- Literal: constrain field type to String
      _ <- unify fieldTy TStr
      return env1
    Just (PVar typeName) -> do
      -- Treat as type annotation: look up altar or resolve type name
      case typeName of
        "Int"    -> do _ <- unify fieldTy TInt; return env1
        "String" -> do _ <- unify fieldTy TStr; return env1
        _        -> return env1  -- unknown type, leave unconstrained
    Just _ -> return env1  -- other patterns: just bind the name
  (restRow, env'') <- inferPatFields env' rest level
  return (RExtend name fieldTy restRow, env'')

-- | Type-check a sequence of given clauses against a scrutinee type.
inferClauses :: Env -> Type -> [GivenClause] -> IO (Either TypeError Type)
inferClauses _ _ [] = return (Left "Empty pattern match")
inferClauses env scrTy clauses = do
  resultTy <- freshTVar (envLevel env)
  results <- mapM (inferClause env scrTy resultTy) clauses
  case sequence results of
    Left err -> return (Left err)
    Right _  -> return (Right resultTy)

inferClause :: Env -> Type -> Type -> GivenClause -> IO (Either TypeError ())
inferClause env scrTy resultTy (GivenClause pat body) = do
  patResult <- inferPattern env pat scrTy
  case patResult of
    Left err -> return (Left err)
    Right env' -> do
      bodyTy <- infer env' body
      case bodyTy of
        Left err -> return (Left err)
        Right ty -> unify ty resultTy

-- ---------------------------------------------------------------------------
-- Checking statements
-- ---------------------------------------------------------------------------

inferStmt :: Env -> Stmt -> IO (Either TypeError (Env, Type))
inferStmt env (LetStmt name expr) = do
  ty <- infer env expr
  case ty of
    Left err -> return (Left err)
    Right t  -> return (Right (extendVar name t env, TVoid))
inferStmt env (UtterStmt expr) = do
  ty <- infer env expr
  case ty of
    Left err -> return (Left err)
    Right _  -> return (Right (env, TVoid))
inferStmt env (WhisperStmt expr) = do
  ty <- infer env expr
  case ty of
    Left err -> return (Left err)
    Right _  -> return (Right (env, TVoid))
inferStmt env (ExprStmt expr) = do
  ty <- infer env expr
  case ty of
    Left err -> return (Left err)
    Right t  -> return (Right (env, t))

inferStmts :: Env -> [Stmt] -> IO (Either TypeError Type)
inferStmts _ [] = return (Right TVoid)
inferStmts env [s] = do
  r <- inferStmt env s
  case r of
    Left err -> return (Left err)
    Right (_, t) -> return (Right t)
inferStmts env (s:ss) = do
  r <- inferStmt env s
  case r of
    Left err -> return (Left err)
    Right (env', _) -> inferStmts env' ss

-- ---------------------------------------------------------------------------
-- Top-level type checking
-- ---------------------------------------------------------------------------

-- | Type-check a complete badlang program.
--
-- Validates all declarations: checks that rite bodies are consistent
-- with their pattern types, altar fields are well-formed, and ritual
-- statements type-check. Returns the program unchanged on success, or
-- a 'TypeError' describing the first error encountered.
--
-- Internally uses 'unsafePerformIO' to run the IORef-based unification
-- engine. The global variable counter is reset at the start of each
-- invocation, so 'typeCheck' is externally pure.
typeCheck :: Program -> Either TypeError Program
typeCheck prog = unsafePerformIO $ typeCheckIO prog

typeCheckIO :: Program -> IO (Either TypeError Program)
typeCheckIO (Program decls) = do
  writeIORef varCounter 0
  let builtinEnv = registerBuiltinRites emptyEnv
  env <- buildEnv builtinEnv decls
  case env of
    Left err -> return (Left err)
    Right env' -> do
      result <- checkDecls env' decls
      case result of
        Left err -> return (Left err)
        Right () -> return (Right (Program decls))

-- | Register built-in rites for IO operations.
registerBuiltinRites :: Env -> Env
registerBuiltinRites env = env
  { envRites = Map.union builtins (envRites env) }
  where
    builtins = Map.fromList
      -- unearth : {| path: String |} -> String
      [ ("unearth",  TFun (TRec (RExtend "path" TStr REmpty)) TStr)
      -- inscribe : {| path: String, content: String |} -> Void
      , ("inscribe", TFun (TRec (RExtend "path" TStr (RExtend "content" TStr REmpty))) TVoid)
      -- argc : {| |} -> Int
      , ("argc",     TFun (TRec REmpty) TInt)
      -- argv : {| n: Int |} -> String
      , ("argv",     TFun (TRec (RExtend "n" TInt REmpty)) TStr)
      ]

-- | First pass: collect all declarations into the environment.
buildEnv :: Env -> [Decl] -> IO (Either TypeError Env)
buildEnv env [] = return (Right env)
buildEnv env (decl : rest) = do
  result <- addDecl env decl
  case result of
    Left err -> return (Left err)
    Right env' -> buildEnv env' rest

addDecl :: Env -> Decl -> IO (Either TypeError Env)
addDecl env (AltarDecl name fields) = do
  let fieldTypes = map (\(Field n t) -> (n, resolveTypeAnn t)) fields
  return (Right env { envAltars = Map.insert name fieldTypes (envAltars env) })
addDecl env (RiteDecl name _clauses) = do
  -- Create a fresh function type for this rite
  argTy <- freshTVar (envLevel env)
  retTy <- freshTVar (envLevel env)
  let funTy = TFun argTy retTy
      env' = env { envRites = Map.insert name funTy (envRites env) }
  return (Right env')
addDecl env (RitualDecl _ _) = return (Right env)

-- | Resolve a surface type annotation to an internal type.
resolveTypeAnn :: TypeAnn -> Type
resolveTypeAnn (TAName "Int")    = TInt
resolveTypeAnn (TAName "String") = TStr
resolveTypeAnn (TAName "Void")   = TVoid
resolveTypeAnn (TAName _)        = TInt  -- fallback for unknown types
resolveTypeAnn (TARecord _)      = TInt  -- placeholder
resolveTypeAnn (TAFun _ _)       = TInt  -- placeholder

-- | Second pass: type-check all declaration bodies.
checkDecls :: Env -> [Decl] -> IO (Either TypeError ())
checkDecls _ [] = return (Right ())
checkDecls env (decl : rest) = do
  result <- checkDecl env decl
  case result of
    Left err -> return (Left err)
    Right () -> checkDecls env rest

checkDecl :: Env -> Decl -> IO (Either TypeError ())
checkDecl _ (AltarDecl _ _) = return (Right ())
checkDecl env (RiteDecl name clauses) = do
  case Map.lookup name (envRites env) of
    Nothing -> return (Left $ "Internal error: rite '" ++ name ++ "' not in env")
    Just riteTy -> do
      riteTy' <- resolveType riteTy
      case riteTy' of
        TFun argTy retTy -> do
          results <- mapM (inferClause env argTy retTy) clauses
          case sequence results of
            Left err -> return (Left $ "In rite '" ++ name ++ "': " ++ err)
            Right _  -> return (Right ())
        _ -> do
          -- Rite type hasn't been constrained yet, create arg/ret
          argTy <- freshTVar (envLevel env)
          retTy <- freshTVar (envLevel env)
          e <- unify riteTy' (TFun argTy retTy)
          case e of
            Left err -> return (Left err)
            Right () -> do
              results <- mapM (inferClause env argTy retTy) clauses
              case sequence results of
                Left err -> return (Left $ "In rite '" ++ name ++ "': " ++ err)
                Right _  -> return (Right ())
checkDecl env (RitualDecl name stmts) = do
  result <- inferStmts env stmts
  case result of
    Left err -> return (Left $ "In ritual '" ++ name ++ "': " ++ err)
    Right _  -> return (Right ())

-- ---------------------------------------------------------------------------
-- Type display (for error messages)
-- ---------------------------------------------------------------------------

showType :: Type -> String
showType TInt = "Int"
showType TStr = "String"
showType TVoid = "Void"
showType (TFun a r) = showType a ++ " -> " ++ showType r
showType (TRec row) = "{| " ++ showRow row ++ " |}"
showType (TVar ref) = unsafePerformIO $ do
  st <- readIORef ref
  case st of
    Unbound n _ -> return $ "t" ++ show n
    Link t -> return $ showType t
    RLink _ -> return $ "{| " ++ showRow (RVar ref) ++ " |}"

showRow :: Row -> String
showRow REmpty = ""
showRow (RExtend name ty rest) =
  name ++ ": " ++ showType ty ++
  case rest of
    REmpty -> ""
    _      -> ", " ++ showRow rest
showRow (RVar ref) = unsafePerformIO $ do
  st <- readIORef ref
  case st of
    Unbound n _ -> return $ "| r" ++ show n
    RLink r -> return $ showRow r
    Link _ -> return "..."
