-- | Intermediate representation for Stele.
--
-- The IR sits between the AST and code generation backends (C and AArch64).
-- It uses explicit basic blocks with named temporaries. Pattern matching,
-- match expressions, and let-in chains are lowered to flat instructions
-- and conditional branches, so backends are purely mechanical translations.
--
-- Key properties:
--
-- * __Flat instructions__: No nested expressions. Every subexpression is
--   named, producing a @Var@ that subsequent instructions reference.
-- * __Explicit RC__: 'IRetain' and 'IRelease' are first-class instructions.
-- * __Pattern matching lowered to primitives__: 'ITagCheck', 'INullCheck',
--   'IIntEq', 'IStrEq' combined with 'TBranch' create explicit control
--   flow graphs. Backends have zero pattern-matching logic.
-- * __No SSA phi nodes__: Join points (match results) use a pre-declared
--   result variable written by whichever branch succeeds.
module Stele.IR
  ( -- * Program structure
    IRProgram(..)
  , IRDecl(..)
  , IRFuncBody(..)
  , Block(..)
    -- * Instructions
  , Var
  , BlockId
  , Instr(..)
  , Tag(..)
  , Operand(..)
    -- * Terminators
  , Terminator(..)
    -- * Re-exports from AST
  , BinOp(..)
  , UnOp(..)
  ) where

import Stele.AST (BinOp(..), UnOp(..))

-- | A variable name in the IR (e.g. @"_t0"@, @"stele_n"@, @"arg"@).
type Var = String

-- | A basic block label (e.g. @"entry"@, @"clause_0_test"@, @"done"@).
type BlockId = String

-- | A complete IR program.
newtype IRProgram = IRProgram [IRDecl]

-- | A top-level IR declaration.
data IRDecl
  = IRFunc !String IRFuncBody    -- ^ A fn compiled to IR
  | IRMain IRFuncBody            -- ^ The do main

-- | A function body: a parameter name and a list of basic blocks
-- (entry block first).
data IRFuncBody = IRFuncBody
  { funcParam  :: Var            -- ^ Parameter name ("arg")
  , funcBlocks :: [Block]        -- ^ Basic blocks, entry first
  }

-- | A basic block: a label, a sequence of instructions, and a terminator.
data Block = Block
  { blockId     :: BlockId
  , blockInstrs :: [Instr]
  , blockTerm   :: Terminator
  }

-- | IR instructions. Every instruction that produces a value binds it
-- to a 'Var'. No nested expressions.
data Instr
  -- Values
  = IConst     Var Operand              -- ^ @var = make_int(n) / make_str(s) / make_void()@
  | IBinOp     Var BinOp Var Var        -- ^ @var = binop(left, right)@
  | IUnOp      Var UnOp Var             -- ^ @var = unop(operand)@
  | IRecord    Var [(String, Var)]      -- ^ @var = make_record(fields...)@
  | IFieldGet  Var Var String           -- ^ @var = record_field(rec, "name")@
  -- Calls
  | ICall      Var String Var           -- ^ @var = fn_name(arg)@
  -- Reference counting
  | IRetain    Var                      -- ^ @rc_retain(var)@
  | IRelease   Var                      -- ^ @rc_release(var)@
  -- Pattern match primitives
  | ITagCheck  Var Var Tag              -- ^ @var = (operand->tag == tag)@
  | INullCheck Var Var                  -- ^ @var = (operand != NULL)@
  | IIntEq     Var Var Integer          -- ^ @var = (operand->int_val == n)@
  | IStrEq     Var Var String           -- ^ @var = strcmp(operand->str_val, s) == 0@
  -- IO
  | IPrint     Var                      -- ^ @stele_print(var)@
  | IWrite     Var                      -- ^ @stele_write(var)@
  | IReadLn    Var                      -- ^ @var = runtime_readln()@
  | IReadInt   Var                      -- ^ @var = runtime_readint()@
  -- Plumbing
  | ICopy      Var Var                  -- ^ @var = source@ (pointer copy, no retain)

-- | Runtime type tags.
data Tag = TagInt | TagStr | TagRecord | TagVoid
  deriving (Eq, Show)

-- | Constant operands.
data Operand = OInt Integer | OStr String | OVoid

-- | Block terminators.
data Terminator
  = TReturn    Var                      -- ^ @return var@
  | TBranch    Var BlockId BlockId      -- ^ @if (var) goto true else goto false@
  | TJump      BlockId                  -- ^ Unconditional goto
  | TMatchFail String                   -- ^ @fprintf(stderr, ...) + exit(1)@
