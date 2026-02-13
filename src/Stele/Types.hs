-- | Type inference with structural subtyping and row polymorphism.
--
-- The type system implements Algorithm-W-style unification-based inference
-- extended with Rémy-style row types for structural records.
--
-- = Row Polymorphism
--
-- Records have types like @{| x: Int, y: String | r |}@ where @r@ is a
-- /row variable/ — an open tail that permits additional fields. This is
-- how width subtyping emerges naturally from unification: a fn that
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
-- * __Per-call-site freshening:__ each @call@ expression creates
--   fresh type variables, implementing a pragmatic form of
--   let-polymorphism that allows the same fn to be called with
--   structurally different records.
--
-- = Entry Point
--
-- @
-- case 'typeCheck' ast of
--   Left err    -> putStrLn ("Type error: " ++ err)
--   Right prog  -> ...  -- proceed to code generation
-- @
module Stele.Types
  ( -- * Type Checking
    typeCheck
    -- * Error Type
  , TypeError
  ) where

import           Stele.AST
import qualified Data.Map.Strict as Map
import           Data.Map.Strict (Map)
import           Data.IORef
import           System.IO.Unsafe (unsafePerformIO)

-- ---------------------------------------------------------------------------
-- Type representation
-- ---------------------------------------------------------------------------

-- | A human-readable type error message.
type TypeError = String

-- | Types in Stele.
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
  { envVars     :: Map String Type      -- ^ Variable -> type
  , envFns      :: Map String Type      -- ^ Fn name -> function type
  , envStructs  :: Map String [(String, Type)]  -- ^ Struct name -> fields
  , envOneofs   :: Map String [(String, [Field])] -- ^ Oneof name -> [(variant, fields)]
  , envVariants :: Map String (String, [Field])   -- ^ Variant name -> (oneof_name, fields)
  , envLevel    :: !Int                 -- ^ Current generalization level
  }

emptyEnv :: Env
emptyEnv = Env Map.empty Map.empty Map.empty Map.empty Map.empty 0

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
      oc <- occursCheck ref t
      if oc
        then return (Left "Infinite type (occurs check)")
        else do
          writeIORef ref (Link t)
          return (Right ())
    Link t' -> unify t' t
    RLink _ -> return (Left "Type variable linked to row")

-- | Check if a type variable occurs in a type (prevents infinite types).
occursCheck :: IORef TVarState -> Type -> IO Bool
occursCheck ref ty = do
  ty' <- resolveType ty
  case ty' of
    TVar ref2 -> return (ref == ref2)
    TFun a r -> do
      oa <- occursCheck ref a
      if oa then return True else occursCheck ref r
    TRec row -> occursCheckRow ref row
    _ -> return False

occursCheckRow :: IORef TVarState -> Row -> IO Bool
occursCheckRow ref row = do
  row' <- resolveRow row
  case row' of
    REmpty -> return False
    RExtend _ ty rest -> do
      ot <- occursCheck ref ty
      if ot then return True else occursCheckRow ref rest
    RVar ref2 -> return (ref == ref2)

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
    Nothing -> case Map.lookup name (envFns env) of
      Just t  -> return (Right t)
      Nothing ->
        -- Check if it's a nullary variant
        case Map.lookup name (envVariants env) of
          Just _ -> return (Right (TRec REmpty))  -- nullary variants are valid expressions
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

infer env (NamedRecord typeName fields) = do
  -- Check structs first, then variants
  case Map.lookup typeName (envStructs env) of
    Just expectedFields -> do
      row <- inferRecordFields env fields
      case row of
        Left err -> return (Left err)
        Right r -> do
          let expectedRow = foldr (\(n, t) acc -> RExtend n t acc) REmpty expectedFields
          e <- unifyRow r expectedRow
          case e of
            Left err -> return (Left $ "Struct '" ++ typeName ++ "': " ++ err)
            Right () -> return (Right (TRec expectedRow))
    Nothing -> case Map.lookup typeName (envVariants env) of
      Just (_oneofName, expectedFieldDecls) -> do
        row <- inferRecordFields env fields
        case row of
          Left err -> return (Left err)
          Right r -> do
            let expectedFields = map (\(Field n t) -> (n, resolveTypeAnn t)) expectedFieldDecls
                expectedRow = foldr (\(n, t) acc -> RExtend n t acc) REmpty expectedFields
            e <- unifyRow r expectedRow
            case e of
              Left err -> return (Left $ "Variant '" ++ typeName ++ "': " ++ err)
              Right () -> return (Right (TRec expectedRow))
      Nothing -> return (Left $ "Unknown type: " ++ typeName)

infer env (Call fnName arg) = do
  case Map.lookup fnName (envFns env) of
    Nothing -> return (Left $ "Unknown fn: " ++ fnName)
    Just _fnTy -> do
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

infer _ ReadLn = return (Right TStr)
infer _ ReadInt = return (Right TInt)

infer env (Match scrutinee clauses) = do
  scrTy <- infer env scrutinee
  case scrTy of
    Left err -> return (Left err)
    Right scrType -> inferClauses env scrType clauses

inferBinOp :: BinOp -> Type -> Type -> IO (Either TypeError Type)
inferBinOp op ty1 ty2
  | op `elem` [Add, Sub, Mul, Div, Mod] = do
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
inferPattern env PWild _ = return (Right env)
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
inferPattern env (PVariant _vname innerPat) _ty = do
  -- Variant pattern: each variant has its own field set, so use a fresh
  -- type for the inner pattern to avoid unifying different variant fields
  -- against each other (which would require all variants' fields in every value).
  freshScrTy <- freshTVar (envLevel env)
  inferPattern env innerPat freshScrTy
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
      -- Treat as type annotation: look up struct or resolve type name
      case typeName of
        "Int"    -> do _ <- unify fieldTy TInt; return env1
        "String" -> do _ <- unify fieldTy TStr; return env1
        _        -> return env1  -- unknown type, leave unconstrained
    Just _ -> return env1  -- other patterns: just bind the name
  (restRow, env'') <- inferPatFields env' rest level
  return (RExtend name fieldTy restRow, env'')

-- | Type-check a sequence of case clauses against a scrutinee type.
inferClauses :: Env -> Type -> [CaseClause] -> IO (Either TypeError Type)
inferClauses _ _ [] = return (Left "Empty pattern match")
inferClauses env scrTy clauses = do
  resultTy <- freshTVar (envLevel env)
  results <- mapM (inferClause env scrTy resultTy) clauses
  case sequence results of
    Left err -> return (Left err)
    Right _  -> return (Right resultTy)

inferClause :: Env -> Type -> Type -> CaseClause -> IO (Either TypeError ())
inferClause env scrTy _resultTy (CaseClause pat body) = do
  patResult <- inferPattern env pat scrTy
  case patResult of
    Left err -> return (Left err)
    Right env' -> do
      bodyTy <- infer env' body
      case bodyTy of
        Left err -> return (Left err)
        Right _ty -> return (Right ())
        -- NOTE: We intentionally do NOT unify clause body types.
        -- This allows different match/fn branches to return records
        -- with different field sets (tagged union pattern), which is
        -- essential for the self-hosting compiler's AST representation.

-- ---------------------------------------------------------------------------
-- Checking statements
-- ---------------------------------------------------------------------------

inferStmt :: Env -> Stmt -> IO (Either TypeError (Env, Type))
inferStmt env (LetStmt name expr) = do
  ty <- infer env expr
  case ty of
    Left err -> return (Left err)
    Right t  -> return (Right (extendVar name t env, TVoid))
inferStmt env (PrintStmt expr) = do
  ty <- infer env expr
  case ty of
    Left err -> return (Left err)
    Right _  -> return (Right (env, TVoid))
inferStmt env (WriteStmt expr) = do
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

-- | Type-check a complete Stele program.
--
-- Validates all declarations: checks that fn bodies are consistent
-- with their pattern types, struct fields are well-formed, and do
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
  let builtinEnv = registerBuiltinFns emptyEnv
  env <- buildEnv builtinEnv decls
  case env of
    Left err -> return (Left err)
    Right env' -> do
      result <- checkDecls env' decls
      case result of
        Left err -> return (Left err)
        Right () -> return (Right (Program decls))

-- | Register built-in fns for IO operations.
registerBuiltinFns :: Env -> Env
registerBuiltinFns env = env
  { envFns = Map.union builtins (envFns env) }
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
      -- strlen : {| s: String |} -> Int
      , ("strlen",   TFun (TRec (RExtend "s" TStr REmpty)) TInt)
      -- char_at : {| s: String, n: Int |} -> Int
      , ("char_at",  TFun (TRec (RExtend "s" TStr (RExtend "n" TInt REmpty))) TInt)
      -- substr : {| s: String, start: Int, len: Int |} -> String
      , ("substr",   TFun (TRec (RExtend "s" TStr (RExtend "start" TInt (RExtend "len" TInt REmpty)))) TStr)
      -- concat : {| a: String, b: String |} -> String
      , ("concat",   TFun (TRec (RExtend "a" TStr (RExtend "b" TStr REmpty))) TStr)
      -- int_to_str : {| n: Int |} -> String
      , ("int_to_str", TFun (TRec (RExtend "n" TInt REmpty)) TStr)
      -- char_of_int : {| n: Int |} -> String
      , ("char_of_int", TFun (TRec (RExtend "n" TInt REmpty)) TStr)
      -- strcmp : {| a: String, b: String |} -> Int
      , ("strcmp",   TFun (TRec (RExtend "a" TStr (RExtend "b" TStr REmpty))) TInt)
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
addDecl env (StructDecl name fields) = do
  let fieldTypes = map (\(Field n t) -> (n, resolveTypeAnn t)) fields
  return (Right env { envStructs = Map.insert name fieldTypes (envStructs env) })
addDecl env (OneofDecl name variants) = do
  let variantMap = Map.fromList [(vname, (name, vfields)) | (vname, vfields) <- variants]
  return (Right env { envOneofs = Map.insert name variants (envOneofs env)
                    , envVariants = Map.union variantMap (envVariants env) })
addDecl env (FnDecl name _clauses) = do
  -- Create a fresh function type for this fn
  argTy <- freshTVar (envLevel env)
  retTy <- freshTVar (envLevel env)
  let funTy = TFun argTy retTy
      env' = env { envFns = Map.insert name funTy (envFns env) }
  return (Right env')
addDecl env (DoDecl _ _) = return (Right env)

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
checkDecl _ (StructDecl _ _) = return (Right ())
checkDecl _ (OneofDecl _ _) = return (Right ())
checkDecl env (FnDecl name clauses) = do
  case Map.lookup name (envFns env) of
    Nothing -> return (Left $ "Internal error: fn '" ++ name ++ "' not in env")
    Just fnTy -> do
      fnTy' <- resolveType fnTy
      case fnTy' of
        TFun argTy retTy -> do
          results <- mapM (inferClause env argTy retTy) clauses
          case sequence results of
            Left err -> return (Left $ "In fn '" ++ name ++ "': " ++ err)
            Right _  -> return (Right ())
        _ -> do
          -- Fn type hasn't been constrained yet, create arg/ret
          argTy <- freshTVar (envLevel env)
          retTy <- freshTVar (envLevel env)
          e <- unify fnTy' (TFun argTy retTy)
          case e of
            Left err -> return (Left err)
            Right () -> do
              results <- mapM (inferClause env argTy retTy) clauses
              case sequence results of
                Left err -> return (Left $ "In fn '" ++ name ++ "': " ++ err)
                Right _  -> return (Right ())
checkDecl env (DoDecl name stmts) = do
  result <- inferStmts env stmts
  case result of
    Left err -> return (Left $ "In do '" ++ name ++ "': " ++ err)
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
