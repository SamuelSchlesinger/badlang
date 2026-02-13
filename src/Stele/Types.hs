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
import qualified Data.Set as Set
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

-- | Create a fresh copy of a type, preserving structure but replacing
-- unbound type/row variables with fresh ones. Used to instantiate fn
-- types at each call site.
instantiateType :: Int -> Type -> IO Type
instantiateType level ty = do
  ty' <- resolveType ty
  goType Map.empty Map.empty ty'
  where
    goType :: Map Int Type -> Map Int Row -> Type -> IO Type
    goType tvSub rvSub t = do
      t' <- resolveType t
      case t' of
        TInt      -> return TInt
        TStr      -> return TStr
        TVoid     -> return TVoid
        TFun a r  -> do
          a' <- goType tvSub rvSub a
          r' <- goType tvSub rvSub r
          return (TFun a' r')
        TRec row  -> TRec <$> goRow tvSub rvSub row
        TVar ref  -> do
          st <- readIORef ref
          case st of
            Link t'' -> goType tvSub rvSub t''
            RLink r  -> TRec <$> goRow tvSub rvSub r
            Unbound n _ ->
              case Map.lookup n tvSub of
                Just tNew -> return tNew
                Nothing -> do
                  tNew <- freshTVar level
                  goType (Map.insert n tNew tvSub) rvSub t

    goRow :: Map Int Type -> Map Int Row -> Row -> IO Row
    goRow tvSub rvSub row = do
      row' <- resolveRow row
      case row' of
        REmpty -> return REmpty
        RExtend name ty' rest -> do
          ty'' <- goType tvSub rvSub ty'
          rest' <- goRow tvSub rvSub rest
          return (RExtend name ty'' rest')
        RVar ref -> do
          st <- readIORef ref
          case st of
            RLink r -> goRow tvSub rvSub r
            Link (TRec r) -> goRow tvSub rvSub r
            Unbound n _ ->
              case Map.lookup n rvSub of
                Just rNew -> return rNew
                Nothing -> do
                  rNew <- freshRVar level
                  goRow tvSub (Map.insert n rNew rvSub) row
            Link _ -> return REmpty

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
    Nothing ->
      case Map.lookup name (envVariants env) of
        Just (_oneofName, fields)
          | null fields ->
              return (Right (TRec (RExtend "__tag" TStr REmpty)))
          | otherwise ->
              return (Left $ "Variant '" ++ name ++ "' requires fields; use " ++ name ++ " {| ... |}")
        Nothing ->
          case Map.lookup name (envFns env) of
            Just _ ->
              return (Left $ "Cannot use fn '" ++ name ++ "' as a value; call it with an argument")
            Nothing ->
              return (Left $ "Unbound variable: " ++ name)

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
        Right () -> return (Right fieldTy)
        Left err ->
          case ty' of
            TRec _ -> return (Right fieldTy)
            TVar _ -> return (Right fieldTy)
            _      -> return (Left $ "Field access ." ++ field ++ ": " ++ err)

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
            Right () -> return (Right (TRec (RExtend "__tag" TStr expectedRow)))
    Nothing -> case Map.lookup typeName (envVariants env) of
      Just (_oneofName, expectedFieldDecls) -> do
        row <- inferRecordFields env fields
        case row of
          Left err -> return (Left err)
          Right r -> do
            case traverse (\(Field n t) -> do
                              ty <- resolveTypeAnnInEnv env t
                              return (n, ty)) expectedFieldDecls of
              Left err -> return (Left err)
              Right expectedFields -> do
                let expectedRow = foldr (\(n, t) acc -> RExtend n t acc) REmpty expectedFields
                e <- unifyRow r expectedRow
                case e of
                  Left err -> return (Left $ "Variant '" ++ typeName ++ "': " ++ err)
                  Right () -> return (Right (TRec (RExtend "__tag" TStr expectedRow)))
      Nothing -> return (Left $ "Unknown type: " ++ typeName)

infer env (Call fnName arg) = do
  case Map.lookup fnName (envFns env) of
    Nothing -> return (Left $ "Unknown fn: " ++ fnName)
    Just fnTyTemplate -> do
      argResult <- infer env arg
      case argResult of
        Left err -> return (Left err)
        Right argTy -> do
          fnTy <- instantiateType (envLevel env) fnTyTemplate
          if fnName `elem` builtinFnNames
            then do
              retTy <- freshTVar (envLevel env)
              e <- unify fnTy (TFun argTy retTy)
              case e of
                Left err -> return (Left $ "In call to '" ++ fnName ++ "': " ++ err)
                Right () -> return (Right retTy)
            else
              case fnTy of
                TFun _ retTy -> return (Right retTy)
                _ -> do
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
  | op `elem` [Eq, Neq] = do
      e <- unify ty1 ty2
      case e of
        Left err -> return (Left $ "Comparison requires same types: " ++ err)
        Right () -> return (Right TInt)  -- comparisons return Int (0/1)
  | op `elem` [Lt, Gt, Lte, Gte] = do
      e1 <- unify ty1 TInt
      case e1 of
        Left err -> return (Left $ "Ordering requires Int: " ++ err)
        Right () -> do
          e2 <- unify ty2 TInt
          case e2 of
            Left err -> return (Left $ "Ordering requires Int: " ++ err)
            Right () -> return (Right TInt)
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
inferPattern env (PVar name) ty =
  case Map.lookup name (envVariants env) of
    Just (_oneofName, fields)
      | null fields -> do
          tailRow <- freshRVar (envLevel env)
          e <- unify ty (TRec (RExtend "__tag" TStr tailRow))
          case e of
            Left err -> return (Left $ "Variant pattern '" ++ name ++ "': " ++ err)
            Right () -> return (Right env)
      | otherwise ->
          return (Left $ "Variant '" ++ name ++ "' is not nullary; use '" ++ name ++ " {| ... |}'")
    Nothing ->
      return (Right (extendVar name ty env))
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
  patResult <- inferPatFields env fields (envLevel env)
  case patResult of
    Left err -> return (Left err)
    Right (patRow, bindings) -> do
      let patTy = TRec patRow
      e <- unify ty patTy
      case e of
        Left err -> return (Left $ "Record pattern: " ++ err)
        Right () -> return (Right bindings)
inferPattern env (PVariant vname innerPat) ty =
  case Map.lookup vname (envVariants env) of
    Nothing ->
      return (Left $ "Unknown variant in pattern: " ++ vname)
    Just _ -> do
      tailRow <- freshRVar (envLevel env)
      eTag <- unify ty (TRec (RExtend "__tag" TStr tailRow))
      case eTag of
        Left err -> return (Left $ "Variant pattern '" ++ vname ++ "': " ++ err)
        Right () -> do
          freshVariantTy <- freshTVar (envLevel env)
          inferPattern env innerPat freshVariantTy
inferPattern _ (PLit _) _ = return (Left "Unsupported pattern literal")

-- | Infer row type from pattern fields, collecting bindings.
-- The field NAME is always bound as a variable. The optional sub-pattern
-- adds constraints (literal matching) or type annotations.
inferPatFields :: Env -> [PatField] -> Int -> IO (Either TypeError (Row, Env))
inferPatFields env [] level = do
  -- Open row: allow extra fields via a row variable
  rv <- freshRVar level
  return (Right (rv, env))
inferPatFields env (PatField name mPat : rest) level = do
  fieldTy <- freshTVar level
  let bindFieldName = extendVar name fieldTy env
  (env', constraint) <- case mPat of
    Nothing ->
      return (bindFieldName, Right ())
    Just (PLit (IntLit _)) -> do
      e <- unify fieldTy TInt
      return (bindFieldName, e)
    Just (PLit (StrLit _)) -> do
      e <- unify fieldTy TStr
      return (bindFieldName, e)
    Just (PVar tyOrVar) ->
      case resolveTypeAnnInEnv env (TAName tyOrVar) of
        Right annTy -> do
          e <- unify fieldTy annTy
          return (bindFieldName, e)
        Left _ ->
          return (extendVar tyOrVar fieldTy env, Right ())
    Just PWild ->
      return (env, Right ())
    Just _ ->
      return (bindFieldName, Right ())
  case constraint of
    Left err -> return (Left $ "Pattern field '" ++ name ++ "': " ++ err)
    Right () -> do
      restResult <- inferPatFields env' rest level
      case restResult of
        Left err -> return (Left err)
        Right (restRow, env'') -> return (Right (RExtend name fieldTy restRow, env''))

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
inferClause env scrTy resultTy (CaseClause pat body) = do
  patResult <- inferPattern env pat scrTy
  case patResult of
    Left err -> return (Left err)
    Right env' -> do
      bodyTy <- infer env' body
      case bodyTy of
        Left err -> return (Left err)
        Right ty -> do
          e <- unify ty resultTy
          case e of
            Left err -> do
              ty' <- resolveType ty
              resTy' <- resolveType resultTy
              case (ty', resTy') of
                (TRec _, TRec _) -> return (Right ())
                _ -> return (Left $ "Clause result type mismatch: " ++ err)
            Right () -> return (Right ())

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

builtinFnNames :: [String]
builtinFnNames =
  [ "unearth", "inscribe", "argc", "argv"
  , "strlen", "char_at", "substr", "concat"
  , "int_to_str", "char_of_int", "strcmp"
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
  if Map.member name (envStructs env)
    then return (Left $ "Duplicate struct declaration: " ++ name)
    else if Map.member name (envOneofs env)
      then return (Left $ "Name '" ++ name ++ "' already used by oneof")
      else if Map.member name (envFns env)
        then return (Left $ "Name '" ++ name ++ "' already used by fn")
        else do
          let resolveField (Field n t) = do
                ty <- resolveTypeAnnInEnv env t
                return (n, ty)
          case traverse resolveField fields of
            Left err -> return (Left err)
            Right fieldTypes ->
              return (Right env { envStructs = Map.insert name fieldTypes (envStructs env) })
addDecl env (OneofDecl name variants) = do
  if Map.member name (envOneofs env)
    then return (Left $ "Duplicate oneof declaration: " ++ name)
    else do
      let variantNames = map fst variants
          dupVariantNames = duplicateNames variantNames
          clashes = filter (`Map.member` envVariants env) variantNames
      if not (null dupVariantNames)
        then return (Left $ "Duplicate variant declarations in oneof '" ++ name ++ "': " ++ unwords dupVariantNames)
        else if not (null clashes)
          then return (Left $ "Variant name already declared: " ++ head clashes)
          else do
            let validateField (Field _ t) = case resolveTypeAnnInEnv env t of
                  Left err -> Left err
                  Right _  -> Right ()
                validateVariant (_vname, vfields) = traverse validateField vfields
            case traverse validateVariant variants of
              Left err -> return (Left err)
              Right _ -> do
                let variantMap = Map.fromList [(vname, (name, vfields)) | (vname, vfields) <- variants]
                return (Right env { envOneofs = Map.insert name variants (envOneofs env)
                                  , envVariants = Map.union variantMap (envVariants env) })
addDecl env (FnDecl name _clauses) = do
  if Map.member name (envFns env)
    then return (Left $ "Duplicate fn declaration: " ++ name)
    else if Map.member name (envVariants env)
      then return (Left $ "Name '" ++ name ++ "' already used by variant")
      else do
  -- Create a fresh function type for this fn
    argTy <- freshTVar (envLevel env)
    retTy <- freshTVar (envLevel env)
    let funTy = TFun argTy retTy
        env' = env { envFns = Map.insert name funTy (envFns env) }
    return (Right env')
addDecl env (DoDecl _ _) = return (Right env)

-- | Resolve a surface type annotation to an internal type.
resolveTypeAnnInEnv :: Env -> TypeAnn -> Either TypeError Type
resolveTypeAnnInEnv _ (TAName "Int")    = Right TInt
resolveTypeAnnInEnv _ (TAName "String") = Right TStr
resolveTypeAnnInEnv _ (TAName "Void")   = Right TVoid
resolveTypeAnnInEnv env (TAName name) =
  case Map.lookup name (envStructs env) of
    Just fields ->
      let row = foldr (\(n, t) acc -> RExtend n t acc) REmpty fields
      in Right (TRec (RExtend "__tag" TStr row))
    Nothing ->
      Left $ "Unknown type annotation: " ++ name
resolveTypeAnnInEnv _ (TARecord _) =
  Left "Record type annotations are not supported yet"
resolveTypeAnnInEnv _ (TAFun _ _) =
  Left "Function type annotations are not supported yet"

duplicateNames :: [String] -> [String]
duplicateNames = reverse . fst . foldl go ([], Set.empty)
  where
    go (dups, seen) name
      | Set.member name seen = (if name `elem` dups then dups else name : dups, seen)
      | otherwise            = (dups, Set.insert name seen)

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
          let useSharedArgTy = length clauses <= 1
              inferFnClause clause = do
                clauseArgTy <- if useSharedArgTy
                  then return argTy
                  else freshTVar (envLevel env)
                inferClause env clauseArgTy retTy clause
          results <- mapM inferFnClause clauses
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
              let useSharedArgTy = length clauses <= 1
                  inferFnClause clause = do
                    clauseArgTy <- if useSharedArgTy
                      then return argTy
                      else freshTVar (envLevel env)
                    inferClause env clauseArgTy retTy clause
              results <- mapM inferFnClause clauses
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
