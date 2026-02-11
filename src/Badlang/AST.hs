-- | The Abstract Syntax Tree of badlang.
--
-- A badlang program is a sequence of top-level declarations ('Decl'), each
-- of which is one of:
--
-- * __Altar__ ('AltarDecl') — a named record type with typed fields.
-- * __Rite__ ('RiteDecl') — a pure function defined by pattern-matching
--   clauses (@given ... => ...@). Every rite takes a single argument
--   (typically a record) and dispatches on its shape.
-- * __Ritual__ ('RitualDecl') — an effectful entry point (like @main@),
--   containing a sequence of statements.
--
-- = Core Design
--
-- All functions in badlang take a single structural record as their argument.
-- Pattern matching (@given@ clauses) is the only mechanism for inspecting
-- data. Combined with structural subtyping, this means a rite that
-- pattern-matches @{| x, y |}@ will accept any record with /at least/
-- those fields — extra fields are silently permitted (width subtyping).
--
-- = Expression Language
--
-- The 'Expr' type covers integer and string literals, variables, binary
-- and unary operations, record construction, field access, function
-- invocation, let bindings, and inline pattern matching (@divine@).
module Badlang.AST
  ( -- * Program Structure
    Program(..)
  , Decl(..)
  , Field(..)
  , GivenClause(..)
  , Stmt(..)
    -- * Expressions
  , Expr(..)
  , BinOp(..)
  , UnOp(..)
    -- * Patterns
  , Pattern(..)
  , PatField(..)
    -- * Type Annotations
  , TypeAnn(..)
  ) where

-- | A complete badlang program.
newtype Program = Program [Decl]
  deriving (Show, Eq)

-- | Top-level declarations.
data Decl
  = AltarDecl  !String [Field]            -- ^ @altar Point x : Int, y : Int seal@
  | RiteDecl   !String [GivenClause]      -- ^ @rite f given ... => ... seal@
  | RitualDecl !String [Stmt]             -- ^ @ritual main ... seal@
  deriving (Show, Eq)

-- | A field in an altar declaration.
data Field = Field
  { fieldName :: !String
  , fieldType :: !TypeAnn
  } deriving (Show, Eq)

-- | A pattern-matching clause in a rite definition.
data GivenClause = GivenClause
  { givenPattern :: !Pattern
  , givenBody    :: !Expr
  } deriving (Show, Eq)

-- | Statements in ritual bodies.
data Stmt
  = LetStmt  !String !Expr     -- ^ @let name = expr@
  | UtterStmt !Expr            -- ^ @utter expr@
  | WhisperStmt !Expr          -- ^ @whisper expr@ (print without newline)
  | ExprStmt  !Expr            -- ^ bare expression
  deriving (Show, Eq)

-- | Expressions — the heart of computation.
data Expr
  = IntLit   !Integer                          -- ^ @42@
  | StrLit   !String                           -- ^ @"hello"@
  | Var      !String                           -- ^ @x@
  | BinOp    !BinOp !Expr !Expr                -- ^ @a + b@
  | UnOp     !UnOp !Expr                       -- ^ @-x@
  | FieldAccess !Expr !String                  -- ^ @point.x@
  | Record   [(String, Expr)]                  -- ^ @{| x: 1, y: 2 |}@
  | Summon   !String [(String, Expr)]          -- ^ @summon Point {| x: 1, y: 2 |}@
  | Invoke   !String !Expr                     -- ^ @invoke f {| n: 5 |}@
  | LetIn    !String !Expr !Expr               -- ^ @let x = e1 in e2@ (desugared from let sequences)
  | Divine   !Expr [GivenClause]               -- ^ @divine expr given ... seal@
  | Hearken                                    -- ^ @hearken@ — read line from stdin
  | Scry                                       -- ^ @scry@ — read integer from stdin
  deriving (Show, Eq)

-- | Binary operators.
data BinOp
  = Add | Sub | Mul | Div | Mod
  | Eq | Neq | Lt | Gt | Lte | Gte
  | And | Or
  deriving (Show, Eq)

-- | Unary operators.
data UnOp
  = Neg   -- ^ @-x@
  | Not   -- ^ @!x@  (reserved for future use)
  deriving (Show, Eq)

-- | Patterns for @given@ clauses.
data Pattern
  = PVar     !String                -- ^ @x@ — binds a variable
  | PLit     !Expr                  -- ^ @0@, @"hello"@ — matches a literal value
  | PRec     [PatField]             -- ^ @{| x: 0, y |}@ — matches a record
  | PWild                           -- ^ @_@ — matches anything
  deriving (Show, Eq)

-- | A field in a record pattern.
data PatField = PatField
  { pfName    :: !String            -- ^ Field name
  , pfPattern :: !(Maybe Pattern)   -- ^ @Nothing@ means bind the field as a variable
  } deriving (Show, Eq)

-- | Type annotations (surface syntax).
data TypeAnn
  = TAName   !String                -- ^ @Int@, @String@, @Point@
  | TARecord [(String, TypeAnn)]    -- ^ @{| x: Int, y: Int |}@
  | TAFun    !TypeAnn !TypeAnn      -- ^ @A -> B@ (for future use)
  deriving (Show, Eq)
