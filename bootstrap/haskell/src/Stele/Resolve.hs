-- | Module resolution for Stele's ML-style module system.
--
-- Each @.stele@ file is a module. @import Math@ loads @math.stele@ and
-- makes its exports available as @Math.name@. @open Math@ brings all
-- exported names into unqualified scope.
--
-- Resolution works by name-mangling: @fn foo@ in @math.stele@ becomes
-- @fn Math__foo@ in the flattened output. Qualified references like
-- @Math.foo@ are rewritten to @Math__foo@. Everything downstream
-- (type checker, lowering, codegen) sees a flat program with no
-- module constructs.
module Stele.Resolve
  ( resolveModules
  ) where

import           Stele.AST
import           Stele.Grammar (parseProgram)
import           Stele.Signature (parseSignature)
import           Data.Char (isUpper, toLower)
import           Data.List (isInfixOf, intercalate)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import           System.FilePath (takeDirectory, (</>), (<.>))
import           System.Directory (doesFileExist)

-- | A loaded module: its mangled declarations and its exported names.
data LoadedModule = LoadedModule
  { lmDecls   :: [Decl]         -- ^ Mangled declarations
  , lmExports :: Set.Set String  -- ^ Original (unmangled) exported names
  }

-- | State threaded through module loading.
data ResolveState = ResolveState
  { rsLoaded  :: Map.Map String LoadedModule  -- ^ Module name → loaded module
  , rsLoading :: Set.Set String               -- ^ Currently loading (cycle detection)
  }

emptyState :: ResolveState
emptyState = ResolveState Map.empty Set.empty

-- | Resolve all imports/opens in a program, producing a flat program.
--
-- The resulting 'Program' has no 'ImportDecl' or 'OpenDecl' nodes.
-- All imported declarations are mangled and prepended; qualified
-- references are rewritten.
resolveModules :: FilePath -> [FilePath] -> Program -> IO (Either String Program)
resolveModules mainPath searchPaths (Program decls) = do
  -- Validate no __ in user-defined names
  case validateNoDoubleUnderscore decls of
    Left err -> return (Left err)
    Right () -> do
      let (imports, opens, localDecls) = partitionDecls decls
          allModules = Set.toList (Set.fromList (imports ++ opens))
          mainDir = takeDirectory mainPath
      -- Load all imported/opened modules
      result <- loadModules mainDir searchPaths allModules emptyState
      case result of
        Left err -> return (Left err)
        Right st -> do
          let loaded = rsLoaded st
          -- Check that all imported/opened modules were loaded
          case checkModulesExist allModules loaded of
            Left err -> return (Left err)
            Right () -> do
              -- Collect opened module names for unqualified resolution
              let openedMods = opens
              -- Resolve references in local declarations
              case resolveDecls loaded openedMods localDecls of
                Left err -> return (Left err)
                Right resolvedLocal -> do
                  -- Collect ALL loaded module declarations (includes transitives)
                  let importedDecls = concatMap lmDecls (Map.elems loaded)
                  return (Right (Program (importedDecls ++ resolvedLocal)))

-- | Partition declarations into imports, opens, and everything else.
partitionDecls :: [Decl] -> ([String], [String], [Decl])
partitionDecls [] = ([], [], [])
partitionDecls (d:ds) =
  let (is, os, rest) = partitionDecls ds
  in case d of
    ImportDecl m -> (m:is, os, rest)
    OpenDecl   m -> (is, m:os, rest)
    _            -> (is, os, d:rest)

-- | Reject declarations containing __ in their names.
validateNoDoubleUnderscore :: [Decl] -> Either String ()
validateNoDoubleUnderscore [] = Right ()
validateNoDoubleUnderscore (d:ds) =
  case d of
    StructDecl n _    -> check n >> validateNoDoubleUnderscore ds
    FnDecl n _        -> check n >> validateNoDoubleUnderscore ds
    DoDecl n _        -> check n >> validateNoDoubleUnderscore ds
    OneofDecl n vs    -> check n >> mapM_ (check . fst) vs >> validateNoDoubleUnderscore ds
    TestDecl _ _      -> validateNoDoubleUnderscore ds
    ImportDecl _      -> validateNoDoubleUnderscore ds
    OpenDecl _        -> validateNoDoubleUnderscore ds
  where
    check name
      | "__" `isInfixOf` name = Left $ "Name '" ++ name ++ "' contains '__', which is reserved for module name mangling"
      | otherwise = Right ()

-- | Load a list of modules, handling circular imports and caching.
loadModules :: FilePath -> [FilePath] -> [String] -> ResolveState -> IO (Either String ResolveState)
loadModules _ _ [] st = return (Right st)
loadModules mainDir searchPaths (m:ms) st = do
  result <- loadModule mainDir searchPaths m st
  case result of
    Left err -> return (Left err)
    Right st' -> loadModules mainDir searchPaths ms st'

-- | Load a single module by name.
loadModule :: FilePath -> [FilePath] -> String -> ResolveState -> IO (Either String ResolveState)
loadModule mainDir searchPaths modName st
  -- Already loaded — skip
  | Map.member modName (rsLoaded st) = return (Right st)
  -- Circular import detection
  | Set.member modName (rsLoading st) =
      return (Left $ "Circular import detected: module " ++ modName)
  | otherwise = do
      let fileName = map toLower (take 1 modName) ++ drop 1 modName <.> "stele"
          sigFileName = map toLower (take 1 modName) ++ drop 1 modName <.> "steli"
          candidates = [mainDir </> fileName] ++
                       [sp </> fileName | sp <- searchPaths]
      found <- findExisting candidates
      case found of
        Nothing -> return (Left $ "Cannot find module " ++ modName ++
                    ": searched " ++ intercalate ", " candidates)
        Just filePath -> do
          src <- readFile filePath
          case parseProgram src of
            Left err -> return (Left $ "Parse error in module " ++ modName ++ ": " ++ err)
            Right (Program modDecls) -> do
              -- Check for __ in imported module's names
              case validateNoDoubleUnderscore modDecls of
                Left err -> return (Left $ "In module " ++ modName ++ ": " ++ err)
                Right () -> do
                  -- Mark as loading for cycle detection
                  let st1 = st { rsLoading = Set.insert modName (rsLoading st) }
                  -- Recursively resolve imports within this module
                  let (subImports, subOpens, subLocalDecls) = partitionDecls modDecls
                      subAllModules = Set.toList (Set.fromList (subImports ++ subOpens))
                      modDir = takeDirectory filePath
                  result <- loadModules modDir searchPaths subAllModules st1
                  case result of
                    Left err -> return (Left err)
                    Right st2 -> do
                      -- Load signature file if it exists
                      let sigPath = takeDirectory filePath </> sigFileName
                      sigExists <- doesFileExist sigPath
                      exports <- if sigExists
                        then do
                          sigContent <- readFile sigPath
                          case parseSignature sigContent of
                            Left err -> return (Left $ "Signature error in " ++ modName ++ ": " ++ err)
                            Right s  -> return (Right (expandOneofExports subLocalDecls s))
                        else return (Right (allDeclNames subLocalDecls))
                      case exports of
                        Left err -> return (Left err)
                        Right exportSet -> do
                          -- Resolve internal references within this module
                          let subLoaded = rsLoaded st2
                          case resolveModuleInternal modName subLoaded subOpens subLocalDecls of
                            Left err -> return (Left $ "In module " ++ modName ++ ": " ++ err)
                            Right mangledDecls -> do
                              let lm = LoadedModule
                                    { lmDecls = mangledDecls
                                    , lmExports = exportSet
                                    }
                                  st3 = st2
                                    { rsLoaded = Map.insert modName lm (rsLoaded st2)
                                    , rsLoading = Set.delete modName (rsLoading st2)
                                    }
                              return (Right st3)

-- | Resolve references inside a module's own declarations.
-- Mangles all declarations and rewrites internal references.
resolveModuleInternal :: String -> Map.Map String LoadedModule -> [String] -> [Decl] -> Either String [Decl]
resolveModuleInternal modName loaded openedMods decls =
  let -- Collect all local declaration names for internal reference rewriting
      localNames = allDeclNames decls
      -- Mangle declarations
      mangledDecls = map (mangleDecl modName) decls
  in  mapM (resolveDeclRefs modName localNames loaded openedMods) mangledDecls

-- | Expand a signature's export set to include variant names for any
-- exported oneof declarations.
expandOneofExports :: [Decl] -> Set.Set String -> Set.Set String
expandOneofExports decls sigNames = foldl expand sigNames decls
  where
    expand s (OneofDecl n vs)
      | Set.member n s = foldl (\acc (vn, _) -> Set.insert vn acc) s vs
    expand s _ = s

-- | Get all declared names from a list of declarations.
allDeclNames :: [Decl] -> Set.Set String
allDeclNames = foldl addNames Set.empty
  where
    addNames s (StructDecl n _)   = Set.insert n s
    addNames s (FnDecl n _)       = Set.insert n s
    addNames s (DoDecl n _)       = Set.insert n s
    addNames s (OneofDecl n vs)   = Set.insert n (foldl (\acc (vn, _) -> Set.insert vn acc) s vs)
    addNames s (TestDecl _ _)     = s
    addNames s (ImportDecl _)     = s
    addNames s (OpenDecl _)       = s

-- | Mangle a declaration's name with the module prefix.
mangleDecl :: String -> Decl -> Decl
mangleDecl modName (StructDecl n fields)  = StructDecl (mangle modName n) (map (mangleField modName) fields)
mangleDecl modName (FnDecl n clauses)     = FnDecl (mangle modName n) clauses
mangleDecl modName (DoDecl n stmts)       = DoDecl (mangle modName n) stmts
mangleDecl modName (OneofDecl n variants) =
  OneofDecl (mangle modName n) [(mangle modName vn, map (mangleField modName) fs) | (vn, fs) <- variants]
mangleDecl _       (TestDecl n stmts)     = TestDecl n stmts
mangleDecl _       d@(ImportDecl _)       = d
mangleDecl _       d@(OpenDecl _)         = d

-- | Mangle type annotations in struct/oneof field declarations.
mangleField :: String -> Field -> Field
mangleField modName (Field n (TAName tn))
  | tn `elem` ["Int", "String", "Void", "_"] = Field n (TAName tn)
  | otherwise = Field n (TAName (mangle modName tn))
mangleField _ f = f

-- | Produce the mangled name: "Module__name".
mangle :: String -> String -> String
mangle modName name = modName ++ "__" ++ name

-- | Builtin names that should never be mangled.
-- These are C runtime primitives only — user-defined utility functions
-- (nil, cons, str_eq, etc.) are resolved through the module system.
builtinNames :: Set.Set String
builtinNames = Set.fromList
  [ "read", "write", "file_exists", "argc", "argv", "sh", "terminate"
  , "spawn", "await", "sleep_ms"
  , "strlen", "char_at", "substr", "concat"
  , "int_to_str", "char_of_int", "strcmp"
  ]

-- | Check that all referenced modules exist.
checkModulesExist :: [String] -> Map.Map String LoadedModule -> Either String ()
checkModulesExist [] _ = Right ()
checkModulesExist (m:ms) loaded
  | Map.member m loaded = checkModulesExist ms loaded
  | otherwise = Left $ "Module " ++ m ++ " was not loaded"

-- | Find the first path that exists.
findExisting :: [FilePath] -> IO (Maybe FilePath)
findExisting [] = return Nothing
findExisting (p:ps) = do
  exists <- doesFileExist p
  if exists then return (Just p) else findExisting ps

-- | Resolve references in a single (already-mangled) declaration.
-- Rewrites unqualified names that belong to the current module,
-- and qualified names to their mangled forms.
resolveDeclRefs :: String -> Set.Set String -> Map.Map String LoadedModule -> [String] -> Decl -> Either String Decl
resolveDeclRefs modName locals loaded openedMods decl = case decl of
  StructDecl n fields  -> Right (StructDecl n fields)
  FnDecl n clauses     -> FnDecl n <$> mapM (resolveClause ctx) clauses
  DoDecl n stmts       -> DoDecl n <$> mapM (resolveStmt ctx) stmts
  OneofDecl n variants -> Right (OneofDecl n variants)
  TestDecl n stmts     -> TestDecl n <$> mapM (resolveStmt ctx) stmts
  ImportDecl _         -> Right decl
  OpenDecl _           -> Right decl
  where
    ctx = ResolveCtx modName locals loaded openedMods

-- | Context for resolving references within expressions.
data ResolveCtx = ResolveCtx
  { rcModule    :: String                          -- ^ Current module name
  , rcLocals    :: Set.Set String                  -- ^ Local declaration names (unmangled)
  , rcLoaded    :: Map.Map String LoadedModule     -- ^ All loaded modules
  , rcOpenedMods :: [String]                       -- ^ Opened module names
  }

resolveClause :: ResolveCtx -> CaseClause -> Either String CaseClause
resolveClause ctx (CaseClause pat body) =
  CaseClause <$> resolvePat ctx pat <*> resolveExpr ctx body

resolveStmt :: ResolveCtx -> Stmt -> Either String Stmt
resolveStmt ctx (LetStmt n e)  = LetStmt n <$> resolveExpr ctx e
resolveStmt ctx (PrintStmt e)  = PrintStmt <$> resolveExpr ctx e
resolveStmt ctx (WriteStmt e)  = WriteStmt <$> resolveExpr ctx e
resolveStmt ctx (ExprStmt e)   = ExprStmt <$> resolveExpr ctx e

resolveExpr :: ResolveCtx -> Expr -> Either String Expr
resolveExpr _   e@(IntLit _)      = Right e
resolveExpr _   e@(StrLit _)      = Right e
resolveExpr ctx (Var name)        = resolveVarRef ctx name
resolveExpr ctx (BinOp op l r)    = BinOp op <$> resolveExpr ctx l <*> resolveExpr ctx r
resolveExpr ctx (UnOp op e)       = UnOp op <$> resolveExpr ctx e
resolveExpr ctx (FieldAccess e f) = FieldAccess <$> resolveExpr ctx e <*> Right f
resolveExpr ctx (Record fields)   = Record <$> mapM (\(n,e) -> (,) n <$> resolveExpr ctx e) fields
resolveExpr ctx (NamedRecord n fields) = do
  let resolved = resolveTypeName ctx n
  fields' <- mapM (\(fn',e) -> (,) fn' <$> resolveExpr ctx e) fields
  Right (NamedRecord resolved fields')
resolveExpr ctx (Call name arg) = do
  let resolved = resolveCallName ctx name
  arg' <- resolveExpr ctx arg
  Right (Call resolved arg')
resolveExpr ctx (LetIn n val body) =
  LetIn n <$> resolveExpr ctx val <*> resolveExpr ctx body
resolveExpr ctx (Match scrut clauses) =
  Match <$> resolveExpr ctx scrut <*> mapM (resolveClause ctx) clauses
resolveExpr ctx (Closure clauses) =
  Closure <$> mapM (resolveClause ctx) clauses
resolveExpr _   ReadLn  = Right ReadLn
resolveExpr _   ReadInt = Right ReadInt
resolveExpr ctx (QualCall modN fn arg) = do
  checkExport ctx modN fn
  arg' <- resolveExpr ctx arg
  Right (Call (mangle modN fn) arg')
resolveExpr ctx (QualVar modN name) = do
  checkExport ctx modN name
  Right (Var (mangle modN name))
resolveExpr ctx (QualRecord modN typN fields) = do
  checkExport ctx modN typN
  fields' <- mapM (\(fn',e) -> (,) fn' <$> resolveExpr ctx e) fields
  Right (NamedRecord (mangle modN typN) fields')

resolvePat :: ResolveCtx -> Pattern -> Either String Pattern
resolvePat ctx p@(PVar name)
  | startsUpper name = Right (PVar (resolveTypeName ctx name))
  | otherwise = Right p
resolvePat _   p@(PLit _)      = Right p
resolvePat ctx (PRec fields)   = PRec <$> mapM (resolvePatField ctx) fields
resolvePat _   PWild           = Right PWild
resolvePat ctx (PVariant name pat) = do
  let resolved = resolveTypeName ctx name
  PVariant resolved <$> resolvePat ctx pat
resolvePat ctx (PQualVariant modN name pat) = do
  checkExport ctx modN name
  PVariant (mangle modN name) <$> resolvePat ctx pat

resolvePatField :: ResolveCtx -> PatField -> Either String PatField
resolvePatField ctx (PatField n mp) =
  PatField n <$> traverse (resolvePat ctx) mp

-- | Resolve a variable reference: check if it's a local name that needs mangling.
resolveVarRef :: ResolveCtx -> String -> Either String Expr
resolveVarRef ctx name
  | Set.member name builtinNames = Right (Var name)
  | Set.member name (rcLocals ctx) = Right (Var (mangle (rcModule ctx) name))
  | otherwise = case findInOpened ctx name of
      Right modN -> Right (Var (mangle modN name))
      Left _     -> Right (Var name)  -- could be a local binding (let-bound variable)

-- | Resolve a function call name.
resolveCallName :: ResolveCtx -> String -> String
resolveCallName ctx name
  | Set.member name builtinNames = name
  | Set.member name (rcLocals ctx) = mangle (rcModule ctx) name
  | otherwise = case findInOpened ctx name of
      Right modN -> mangle modN name
      Left _     -> name  -- might be a closure or let-bound fn

-- | Resolve a type/variant name (uppercase) — used for NamedRecord and PVariant.
resolveTypeName :: ResolveCtx -> String -> String
resolveTypeName ctx name
  | Set.member name (rcLocals ctx) = mangle (rcModule ctx) name
  | otherwise = case findInOpened ctx name of
      Right modN -> mangle modN name
      Left _     -> name

-- | Check that a name is exported from a module.
checkExport :: ResolveCtx -> String -> String -> Either String ()
checkExport ctx modN name =
  case Map.lookup modN (rcLoaded ctx) of
    Nothing -> Left $ "Module " ++ modN ++ " is not imported"
    Just lm
      | Set.member name (lmExports lm) -> Right ()
      | otherwise -> Left $ "Name '" ++ name ++ "' is not exported from module " ++ modN

-- | Find a name in opened modules. Returns the module it was found in,
-- or an error if not found or ambiguous.
findInOpened :: ResolveCtx -> String -> Either String String
findInOpened ctx name =
  let matches = [m | m <- rcOpenedMods ctx
                    , case Map.lookup m (rcLoaded ctx) of
                        Just lm -> Set.member name (lmExports lm)
                        Nothing -> False
                ]
  in case matches of
    [m] -> Right m
    []  -> Left $ "Name '" ++ name ++ "' not found in any opened module"
    ms  -> Left $ "Ambiguous name '" ++ name ++ "' found in modules: " ++ intercalate ", " ms

-- | Resolve references in the main file's local declarations (not from a module).
-- These are NOT mangled — they stay as-is, but qualified refs are resolved.
resolveDecls :: Map.Map String LoadedModule -> [String] -> [Decl] -> Either String [Decl]
resolveDecls loaded openedMods decls =
  mapM (resolveLocalDecl loaded openedMods) decls

resolveLocalDecl :: Map.Map String LoadedModule -> [String] -> Decl -> Either String Decl
resolveLocalDecl loaded openedMods decl = case decl of
  StructDecl n fields  -> Right (StructDecl n fields)
  FnDecl n clauses     -> FnDecl n <$> mapM (resolveClauseLocal ctx) clauses
  DoDecl n stmts       -> DoDecl n <$> mapM (resolveStmtLocal ctx) stmts
  OneofDecl n variants -> Right (OneofDecl n variants)
  TestDecl n stmts     -> TestDecl n <$> mapM (resolveStmtLocal ctx) stmts
  ImportDecl _         -> Right decl
  OpenDecl _           -> Right decl
  where
    ctx = LocalCtx loaded openedMods

data LocalCtx = LocalCtx
  { lcLoaded    :: Map.Map String LoadedModule
  , lcOpenedMods :: [String]
  }

resolveClauseLocal :: LocalCtx -> CaseClause -> Either String CaseClause
resolveClauseLocal ctx (CaseClause pat body) =
  CaseClause <$> resolvePatLocal ctx pat <*> resolveExprLocal ctx body

resolveStmtLocal :: LocalCtx -> Stmt -> Either String Stmt
resolveStmtLocal ctx (LetStmt n e)  = LetStmt n <$> resolveExprLocal ctx e
resolveStmtLocal ctx (PrintStmt e)  = PrintStmt <$> resolveExprLocal ctx e
resolveStmtLocal ctx (WriteStmt e)  = WriteStmt <$> resolveExprLocal ctx e
resolveStmtLocal ctx (ExprStmt e)   = ExprStmt <$> resolveExprLocal ctx e

resolveExprLocal :: LocalCtx -> Expr -> Either String Expr
resolveExprLocal _   e@(IntLit _)      = Right e
resolveExprLocal _   e@(StrLit _)      = Right e
resolveExprLocal ctx (Var name)        = resolveVarLocal ctx name
resolveExprLocal ctx (BinOp op l r)    = BinOp op <$> resolveExprLocal ctx l <*> resolveExprLocal ctx r
resolveExprLocal ctx (UnOp op e)       = UnOp op <$> resolveExprLocal ctx e
resolveExprLocal ctx (FieldAccess e f) = FieldAccess <$> resolveExprLocal ctx e <*> Right f
resolveExprLocal ctx (Record fields)   = Record <$> mapM (\(n,e) -> (,) n <$> resolveExprLocal ctx e) fields
resolveExprLocal ctx (NamedRecord n fields) = do
  let resolved = resolveTypeNameLocal ctx n
  fields' <- mapM (\(fn',e) -> (,) fn' <$> resolveExprLocal ctx e) fields
  Right (NamedRecord resolved fields')
resolveExprLocal ctx (Call name arg) = do
  let resolved = resolveCallNameLocal ctx name
  arg' <- resolveExprLocal ctx arg
  Right (Call resolved arg')
resolveExprLocal ctx (LetIn n val body) =
  LetIn n <$> resolveExprLocal ctx val <*> resolveExprLocal ctx body
resolveExprLocal ctx (Match scrut clauses) =
  Match <$> resolveExprLocal ctx scrut <*> mapM (resolveClauseLocal ctx) clauses
resolveExprLocal ctx (Closure clauses) =
  Closure <$> mapM (resolveClauseLocal ctx) clauses
resolveExprLocal _   ReadLn  = Right ReadLn
resolveExprLocal _   ReadInt = Right ReadInt
resolveExprLocal ctx (QualCall modN fn arg) = do
  checkExportLocal ctx modN fn
  arg' <- resolveExprLocal ctx arg
  Right (Call (mangle modN fn) arg')
resolveExprLocal ctx (QualVar modN name) = do
  checkExportLocal ctx modN name
  Right (Var (mangle modN name))
resolveExprLocal ctx (QualRecord modN typN fields) = do
  checkExportLocal ctx modN typN
  fields' <- mapM (\(fn',e) -> (,) fn' <$> resolveExprLocal ctx e) fields
  Right (NamedRecord (mangle modN typN) fields')

resolvePatLocal :: LocalCtx -> Pattern -> Either String Pattern
resolvePatLocal ctx p@(PVar name)
  | startsUpper name = Right (PVar (resolveTypeNameLocal ctx name))
  | otherwise = Right p
resolvePatLocal _   p@(PLit _)      = Right p
resolvePatLocal ctx (PRec fields)   = PRec <$> mapM (resolvePatFieldLocal ctx) fields
resolvePatLocal _   PWild           = Right PWild
resolvePatLocal ctx (PVariant name pat) = do
  let resolved = resolveTypeNameLocal ctx name
  PVariant resolved <$> resolvePatLocal ctx pat
resolvePatLocal ctx (PQualVariant modN name pat) = do
  checkExportLocal ctx modN name
  PVariant (mangle modN name) <$> resolvePatLocal ctx pat

resolvePatFieldLocal :: LocalCtx -> PatField -> Either String PatField
resolvePatFieldLocal ctx (PatField n mp) =
  PatField n <$> traverse (resolvePatLocal ctx) mp

startsUpper :: String -> Bool
startsUpper (c:_) = isUpper c
startsUpper []    = False

resolveVarLocal :: LocalCtx -> String -> Either String Expr
resolveVarLocal ctx name =
  case findInOpenedLocal ctx name of
    Right modN -> Right (Var (mangle modN name))
    Left _     -> Right (Var name)

resolveCallNameLocal :: LocalCtx -> String -> String
resolveCallNameLocal ctx name =
  case findInOpenedLocal ctx name of
    Right modN -> mangle modN name
    Left _     -> name

resolveTypeNameLocal :: LocalCtx -> String -> String
resolveTypeNameLocal ctx name =
  case findInOpenedLocal ctx name of
    Right modN -> mangle modN name
    Left _     -> name

checkExportLocal :: LocalCtx -> String -> String -> Either String ()
checkExportLocal ctx modN name =
  case Map.lookup modN (lcLoaded ctx) of
    Nothing -> Left $ "Module " ++ modN ++ " is not imported"
    Just lm
      | Set.member name (lmExports lm) -> Right ()
      | otherwise -> Left $ "Name '" ++ name ++ "' is not exported from module " ++ modN

findInOpenedLocal :: LocalCtx -> String -> Either String String
findInOpenedLocal ctx name =
  let matches = [m | m <- lcOpenedMods ctx
                    , case Map.lookup m (lcLoaded ctx) of
                        Just lm -> Set.member name (lmExports lm)
                        Nothing -> False
                ]
  in case matches of
    [m] -> Right m
    []  -> Left $ "Name '" ++ name ++ "' not found in any opened module"
    ms  -> Left $ "Ambiguous name '" ++ name ++ "' found in modules: " ++ intercalate ", " ms
