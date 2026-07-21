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
import           Data.List (isPrefixOf)
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
  | TVoid                             -- ^ Unit-like result of effectful operations
  | TNever                            -- ^ Does not return (currently terminate)
  | TOneof !String                    -- ^ Nominal sum type
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
  , envOneofNames :: Set.Set String             -- ^ All declared oneofs, including forward references
  , envVariants :: Map String (String, [Field])   -- ^ Variant name -> (oneof_name, fields)
  , envLevel    :: !Int                 -- ^ Current generalization level
  }

emptyEnv :: Env
emptyEnv = Env Map.empty Map.empty Map.empty Map.empty Set.empty Map.empty 0

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
        TNever    -> return TNever
        TOneof n  -> return (TOneof n)
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
-- Never is the bottom type; Void is an ordinary unit-like value.
unify' TNever _ = return (Right ())
unify' _ TNever = return (Right ())
unify' (TOneof n1) (TOneof n2)
  | n1 == n2 = return (Right ())
  | otherwise = return (Left $ "Cannot unify oneof " ++ n1 ++ " with oneof " ++ n2)
unify' (TFun a1 r1) (TFun a2 r2) = do
  e1 <- unify a1 a2
  case e1 of
    Left err -> return (Left err)
    Right () -> unify r1 r2
unify' (TRec r1) (TRec r2) = do
  result <- unifyRow r1 r2
  case result of
    Right () -> return (Right ())
    Left err -> do
      tagged1 <- rowContainsField "tag" r1
      tagged2 <- rowContainsField "tag" r2
      if tagged1 && tagged2
        then return (Right ())
        else return (Left err)
unify' (TVar ref1) (TVar ref2)
  | ref1 == ref2 = return (Right ())
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
        Just (oneofName, fields)
          | null fields ->
              return (Right (TOneof oneofName))
          | otherwise ->
              return (Left $ "Variant '" ++ name ++ "' requires fields; use " ++ name ++ " {| ... |}")
        Nothing ->
          case Map.lookup name (envFns env) of
            Just fnTy -> do
              -- Allow using fn names as values (they become closures)
              fnTy' <- instantiateType (envLevel env) fnTy
              return (Right fnTy')
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
      case ty' of
        TOneof oneofName -> inferOneofField env oneofName field
        _ -> do
          fieldTy <- freshTVar (envLevel env)
          restRow <- freshRVar (envLevel env)
          let expected = TRec (RExtend field fieldTy restRow)
          e' <- unify ty' expected
          case e' of
            Right () -> return (Right fieldTy)
            Left err ->
              case ty' of
                TRec row -> do
                  isDynamic <- rowContainsField "tag" row
                  if isDynamic
                    then return (Right fieldTy)
                    else return (Left $ "Field access ." ++ field ++ ": " ++ err)
                _ -> return (Left $ "Field access ." ++ field ++ ": " ++ err)

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
      Just (oneofName, expectedFieldDecls) -> do
        row <- inferRecordFields env fields
        case row of
          Left err -> return (Left err)
          Right r -> do
            resolvedFields <- mapM (\(Field n t) -> do
                                      result <- resolveTypeAnnIO env t
                                      case result of
                                        Right ty -> return (Right (n, ty))
                                        Left err -> return (Left err)) expectedFieldDecls
            case sequence resolvedFields of
              Left err -> return (Left err)
              Right expectedFields -> do
                let expectedRow = foldr (\(n, t) acc -> RExtend n t acc) REmpty expectedFields
                e <- unifyRow r expectedRow
                case e of
                  Left err -> return (Left $ "Variant '" ++ typeName ++ "': " ++ err)
                  Right () -> return (Right (TOneof oneofName))
      Nothing -> return (Left $ "Unknown type: " ++ typeName)

infer env (Closure clauses) = do
  argTy <- freshTVar (envLevel env)
  retTy <- freshTVar (envLevel env)
  result <- inferClauses env argTy clauses
  case result of
    Left err -> return (Left $ "In closure: " ++ err)
    Right ty -> do
      _ <- unify ty retTy
      return (Right (TFun argTy retTy))

infer env (Call fnName arg) =
  -- Check if it's a local variable (closure call) first
  case Map.lookup fnName (envVars env) of
    Just varTy -> do
      argResult <- infer env arg
      case argResult of
        Left err -> return (Left err)
        Right argTy -> do
          retTy <- freshTVar (envLevel env)
          varTy' <- resolveType varTy
          e <- unify varTy' (TFun argTy retTy)
          case e of
            Left err -> return (Left $ "In closure call '" ++ fnName ++ "': " ++ err)
            Right () -> return (Right retTy)
    Nothing ->
      case Map.lookup fnName (envFns env) of
        Nothing -> return (Left $ "Unknown fn: " ++ fnName)
        Just fnTyTemplate -> do
          argResult <- infer env arg
          case argResult of
            Left err -> return (Left err)
            Right argTy -> do
              fnTy <- instantiateType (envLevel env) fnTyTemplate
              retTy <- freshTVar (envLevel env)
              e <- unify fnTy (TFun argTy retTy)
              case e of
                Left err -> return (Left $ "In call to '" ++ fnName ++ "': " ++ err)
                Right () -> return (Right retTy)

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

-- Qualified expressions should be resolved before type checking, but
-- handle them as their desugared forms as a fallback.
infer env (QualCall modN fn arg) = infer env (Call (modN ++ "__" ++ fn) arg)
infer env (QualVar modN name) = infer env (Var (modN ++ "__" ++ name))
infer env (QualRecord modN typN fields) = infer env (NamedRecord (modN ++ "__" ++ typN) fields)

inferOneofField :: Env -> String -> String -> IO (Either TypeError Type)
inferOneofField env oneofName field =
  case Map.lookup oneofName (envOneofs env) of
    Nothing -> return (Left $ "Unknown oneof: " ++ oneofName)
    Just variants -> do
      resolved <- mapM resolveVariantField variants
      case sequence resolved of
        Left err -> return (Left err)
        Right [] -> return (Left $ "Oneof '" ++ oneofName ++ "' has no variants")
        Right (firstTy : rest) -> unifyAll firstTy rest
  where
    resolveVariantField (variantName, fields) =
      case [ann | Field name ann <- fields, name == field] of
        [] -> return (Left $ "Field '" ++ field ++ "' is not present in variant '" ++ variantName ++ "'")
        ann : _ -> resolveTypeAnnIO env ann

    unifyAll firstTy [] = return (Right firstTy)
    unifyAll firstTy (ty : rest) = do
      result <- unify firstTy ty
      case result of
        Left err -> return (Left $ "Field '" ++ field ++ "' has inconsistent types in oneof '" ++ oneofName ++ "': " ++ err)
        Right () -> unifyAll firstTy rest

rowContainsField :: String -> Row -> IO Bool
rowContainsField wanted row = do
  row' <- resolveRow row
  case row' of
    REmpty -> return False
    RVar _ -> return False
    RExtend name _ rest
      | name == wanted -> return True
      | otherwise -> rowContainsField wanted rest

rowsHaveSameFields :: Row -> Row -> IO Bool
rowsHaveSameFields left right = do
  leftNames <- rowFieldNames left
  rightNames <- rowFieldNames right
  return (Set.fromList leftNames == Set.fromList rightNames)

rowFieldNames :: Row -> IO [String]
rowFieldNames row = do
  row' <- resolveRow row
  case row' of
    REmpty -> return []
    RVar _ -> return []
    RExtend name _ rest -> (name :) <$> rowFieldNames rest

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
    Just (oneofName, fields)
      | null fields -> do
          e <- unify ty (TOneof oneofName)
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
    Just (oneofName, fields) -> do
      eTag <- unify ty (TOneof oneofName)
      case eTag of
        Left err -> return (Left $ "Variant pattern '" ++ vname ++ "': " ++ err)
        Right () -> do
          resolvedFields <- mapM (\(Field n t) -> do
                                    result <- resolveTypeAnnIO env t
                                    case result of
                                      Left err -> return (Left err)
                                      Right fieldTy -> return (Right (n, fieldTy))) fields
          case sequence resolvedFields of
            Left err -> return (Left err)
            Right payloadFields ->
              let payloadRow = foldr (\(n, t) acc -> RExtend n t acc) REmpty payloadFields
              in inferPattern env innerPat (TRec payloadRow)
inferPattern env (PQualVariant modN vname innerPat) ty =
  inferPattern env (PVariant (modN ++ "__" ++ vname) innerPat) ty
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
              resultTy' <- resolveType resultTy
              case (ty', resultTy', resultTy) of
                -- Legacy structural tagged records form open unions. Keep
                -- their result row open so later field access is explicit in
                -- the row constraints; declared oneofs use TOneof instead.
                (TRec bodyRow, TRec resultRow, TVar resultRef) -> do
                  bodyTagged <- rowContainsField "tag" bodyRow
                  resultTagged <- rowContainsField "tag" resultRow
                  sameShape <- rowsHaveSameFields bodyRow resultRow
                  if bodyTagged && resultTagged
                    then do
                      openRow <- freshRVar (envLevel env)
                      writeIORef resultRef (Link (TRec openRow))
                      return (Right ())
                    else if sameShape && "Infinite type" `isPrefixOf` err
                      then return (Right ())
                      else return (Left $ "Clause result type mismatch: " ++ err)
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
  let declaredOneofs = Set.fromList [name | OneofDecl name _ <- decls]
      builtinEnv = (registerBuiltinFns emptyEnv) { envOneofNames = declaredOneofs }
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
      -- read : {| path: String |} -> String
      [ ("read",  TFun (TRec (RExtend "path" TStr REmpty)) TStr)
      -- write : {| path: String, content: String |} -> Void
      , ("write", TFun (TRec (RExtend "path" TStr (RExtend "content" TStr REmpty))) TVoid)
      -- file_exists : {| path: String |} -> Int
      , ("file_exists", TFun (TRec (RExtend "path" TStr REmpty)) TInt)
      -- argc : {| |} -> Int
      , ("argc",     TFun (TRec REmpty) TInt)
      -- argv : {| n: Int |} -> String
      , ("argv",     TFun (TRec (RExtend "n" TInt REmpty)) TStr)
      -- sh : {| command: String |} -> Int
      , ("sh",       TFun (TRec (RExtend "command" TStr REmpty)) TInt)
      -- terminate : {| code: Int |} -> Never
      , ("terminate", TFun (TRec (RExtend "code" TInt REmpty)) TNever)
      -- spawn : {| command: String |} -> Int
      , ("spawn",    TFun (TRec (RExtend "command" TStr REmpty)) TInt)
      -- await : {| pid: Int |} -> Int
      , ("await",    TFun (TRec (RExtend "pid" TInt REmpty)) TInt)
      -- sleep_ms : {| ms: Int |} -> Void
      , ("sleep_ms", TFun (TRec (RExtend "ms" TInt REmpty)) TVoid)
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
  if Map.member name (envStructs env)
    then return (Left $ "Duplicate struct declaration: " ++ name)
    else if Map.member name (envOneofs env)
      then return (Left $ "Name '" ++ name ++ "' already used by oneof")
      else if Map.member name (envFns env)
        then return (Left $ "Name '" ++ name ++ "' already used by fn")
        else do
          resolvedFields <- mapM (\(Field n t) -> do
                                    result <- resolveTypeAnnIO env t
                                    case result of
                                      Right ty -> return (Right (n, ty))
                                      Left err -> return (Left err)) fields
          case sequence resolvedFields of
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
        else case clashes of
          clash : _ -> return (Left $ "Variant name already declared: " ++ clash)
          [] -> do
            -- Register the oneof before validating fields (allows self-referential type annotations)
            let variantMap = Map.fromList [(vname, (name, vfields)) | (vname, vfields) <- variants]
                env' = env { envOneofs = Map.insert name variants (envOneofs env)
                           , envVariants = Map.union variantMap (envVariants env) }
            let validateField (Field _ t) = case resolveTypeAnnInEnv env' t of
                  Left err -> Left err
                  Right _  -> Right ()
                validateVariant (_vname, vfields) = traverse validateField vfields
            case traverse validateVariant variants of
              Left err -> return (Left err)
              Right _ -> return (Right env')
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
addDecl env (TestDecl _ _) = return (Right env)
addDecl env (ImportDecl _) = return (Right env)
addDecl env (OpenDecl _) = return (Right env)

-- | Resolve a surface type annotation to an internal type.
resolveTypeAnnInEnv :: Env -> TypeAnn -> Either TypeError Type
resolveTypeAnnInEnv _ (TAName "Int")    = Right TInt
resolveTypeAnnInEnv _ (TAName "String") = Right TStr
resolveTypeAnnInEnv _ (TAName "Void")   = Right TVoid
resolveTypeAnnInEnv _ (TAName "_")      = Right TVoid  -- placeholder; use resolveTypeAnnIO for actual fresh vars
resolveTypeAnnInEnv env (TAName name) =
  case Map.lookup name (envStructs env) of
    Just fields ->
      let row = foldr (\(n, t) acc -> RExtend n t acc) REmpty fields
      in Right (TRec (RExtend "__tag" TStr row))
    Nothing ->
      case Map.lookup name (envOneofs env) of
        Just _  -> Right (TOneof name)
        Nothing
          | Set.member name (envOneofNames env) -> Right (TOneof name)
          | otherwise -> Left $ "Unknown type annotation: " ++ name
resolveTypeAnnInEnv _ (TARecord _) =
  Left "Record type annotations are not supported yet"
resolveTypeAnnInEnv _ (TAFun _ _) =
  Left "Function type annotations are not supported yet"

-- | Like resolveTypeAnnInEnv but in IO, so fresh type variables are unique.
-- Use this instead of resolveTypeAnnInEnv whenever you need actual type variables
-- (not just validation).
resolveTypeAnnIO :: Env -> TypeAnn -> IO (Either TypeError Type)
resolveTypeAnnIO env (TAName "_") = Right <$> freshTVar (envLevel env)
resolveTypeAnnIO env (TAName name)
  | Set.member name (envOneofNames env) = return (Right (TOneof name))
  | otherwise = return (resolveTypeAnnInEnv env (TAName name))
resolveTypeAnnIO env ta = return (resolveTypeAnnInEnv env ta)

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
checkDecl env (TestDecl name stmts) = do
  result <- inferStmts env stmts
  case result of
    Left err -> return (Left $ "In test '" ++ name ++ "': " ++ err)
    Right _  -> return (Right ())
checkDecl _ (ImportDecl _) = return (Right ())
checkDecl _ (OpenDecl _) = return (Right ())

-- ---------------------------------------------------------------------------
-- Type display (for error messages)
-- ---------------------------------------------------------------------------

showType :: Type -> String
showType TInt = "Int"
showType TStr = "String"
showType TVoid = "Void"
showType TNever = "Never"
showType (TOneof name) = name
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
