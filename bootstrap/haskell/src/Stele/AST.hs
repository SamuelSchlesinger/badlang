-- | The Abstract Syntax Tree of Stele.
--
-- A Stele program is a sequence of top-level declarations ('Decl'), each
-- of which is one of:
--
-- * __Struct__ ('StructDecl') — a named record type with typed fields.
-- * __Fn__ ('FnDecl') — a pure function defined by pattern-matching
--   clauses (@case ... => ...@). Every fn takes a single argument
--   (typically a record) and dispatches on its shape.
-- * __Do__ ('DoDecl') — an effectful entry point (like @main@),
--   containing a sequence of statements.
-- * __Oneof__ ('OneofDecl') — a sum type with named variants.
--
-- = Core Design
--
-- All functions in Stele take a single structural record as their argument.
-- Pattern matching (@case@ clauses) is the only mechanism for inspecting
-- data. Combined with structural subtyping, this means a fn that
-- pattern-matches @{| x, y |}@ will accept any record with /at least/
-- those fields — extra fields are silently permitted (width subtyping).
--
-- = Expression Language
--
-- The 'Expr' type covers integer and string literals, variables, binary
-- and unary operations, record construction, field access, function
-- invocation, let bindings, and inline pattern matching (@match@).
module Stele.AST
  ( -- * Program Structure
    Program(..)
  , Decl(..)
  , Field(..)
  , CaseClause(..)
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

-- | A complete Stele program.
newtype Program = Program [Decl]
  deriving (Show, Eq)

-- | Top-level declarations.
data Decl
  = StructDecl !String [Field]            -- ^ @struct Point x : Int, y : Int end@
  | FnDecl     !String [CaseClause]       -- ^ @fn f case ... => ... end@
  | DoDecl     !String [Stmt]             -- ^ @do main ... end@
  | OneofDecl  !String [(String, [Field])] -- ^ @oneof Shape Circle { radius : Int } ... end@
  | TestDecl   !String [Stmt]             -- ^ @test "name" ... end@
  deriving (Show, Eq)

-- | A field in a struct declaration.
data Field = Field
  { fieldName :: !String
  , fieldType :: !TypeAnn
  } deriving (Show, Eq)

-- | A pattern-matching clause in a fn definition.
data CaseClause = CaseClause
  { casePattern :: !Pattern
  , caseBody    :: !Expr
  } deriving (Show, Eq)

-- | Statements in do bodies.
data Stmt
  = LetStmt   !String !Expr     -- ^ @let name = expr@
  | PrintStmt !Expr             -- ^ @print expr@
  | WriteStmt !Expr             -- ^ @write expr@ (print without newline)
  | ExprStmt  !Expr             -- ^ bare expression
  deriving (Show, Eq)

-- | Expressions — the heart of computation.
data Expr
  = IntLit      !Integer                          -- ^ @42@
  | StrLit      !String                           -- ^ @"hello"@
  | Var         !String                           -- ^ @x@
  | BinOp       !BinOp !Expr !Expr                -- ^ @a + b@
  | UnOp        !UnOp !Expr                       -- ^ @-x@
  | FieldAccess !Expr !String                     -- ^ @point.x@
  | Record      [(String, Expr)]                  -- ^ @{| x: 1, y: 2 |}@
  | NamedRecord !String [(String, Expr)]          -- ^ @Point {| x: 1, y: 2 |}@
  | Call        !String !Expr                     -- ^ @call f {| n: 5 |}@
  | LetIn       !String !Expr !Expr               -- ^ @let x = e1 in e2@ (desugared from let sequences)
  | Match       !Expr [CaseClause]                -- ^ @match expr case ... end@
  | Closure     [CaseClause]                      -- ^ @fn case ... end@ — anonymous function
  | ReadLn                                        -- ^ @readln@ — read line from stdin
  | ReadInt                                       -- ^ @readint@ — read integer from stdin
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

-- | Patterns for @case@ clauses.
data Pattern
  = PVar     !String                -- ^ @x@ — binds a variable
  | PLit     !Expr                  -- ^ @0@, @"hello"@ — matches a literal value
  | PRec     [PatField]             -- ^ @{| x: 0, y |}@ — matches a record
  | PWild                           -- ^ @_@ — matches anything
  | PVariant !String !Pattern       -- ^ @Circle {| radius |}@ — matches a variant
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
