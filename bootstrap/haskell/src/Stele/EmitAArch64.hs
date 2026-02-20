-- | AArch64 assembly code generator for Stele.
--
-- Consumes the IR and emits a @.s@ file suitable for assembling and
-- linking with the C runtime via @cc@.
--
-- Strategy: all IR variables are stored on the stack. Scratch registers
-- (x8, x9, etc.) are used for temporary values within instruction sequences.
-- This is simple, correct, and sufficient for the language's scope.
--
-- Supports macOS (Mach-O) and Linux (ELF) targets:
-- * macOS: @_@ symbol prefix, @__TEXT@ sections, @L@ local labels
-- * Linux: no prefix, @.text@/@.rodata@ sections, @.L@ local labels
-- * Both: 16-byte stack alignment, x29/x30 frame linkage
module Stele.EmitAArch64
  ( emitAArch64
  , emitAArch64With
  , AArch64Target(..)
  ) where

import Stele.IR
import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import Control.Monad.Trans.State.Strict (State, execState, get, modify')

-- ---------------------------------------------------------------------------
-- Target configuration
-- ---------------------------------------------------------------------------

data AArch64Target = MacOS_AArch64 | Linux_AArch64
  deriving (Eq, Show)

symPrefix :: AArch64Target -> String
symPrefix MacOS_AArch64 = "_"
symPrefix Linux_AArch64 = ""

textSection :: AArch64Target -> String
textSection MacOS_AArch64 = ".section __TEXT,__text"
textSection Linux_AArch64 = ".text"

cstringSection :: AArch64Target -> String
cstringSection MacOS_AArch64 = ".section __TEXT,__cstring"
cstringSection Linux_AArch64 = ".section .rodata"

localPrefix :: AArch64Target -> String
localPrefix MacOS_AArch64 = "L"
localPrefix Linux_AArch64 = ".L"

-- ---------------------------------------------------------------------------
-- Code generation state
-- ---------------------------------------------------------------------------

data AsmState = AsmState
  { asmOutput     :: [String]           -- lines of assembly (reversed)
  , asmStrTable   :: [(String, String)] -- (label, string value)
  , asmStrCounter :: !Int
  , asmVarMap     :: Map Var Int        -- var -> stack offset from frame base
  , asmNextSlot   :: !Int               -- next available stack slot (grows up)
  , asmFrameSize  :: !Int               -- total frame size for current func
  , asmMatchStrs  :: [(String, String)] -- (label, match fail message)
  , asmLabelPfx   :: String             -- prefix for block labels (func name)
  , asmTarget     :: AArch64Target      -- target platform
  }

type Asm = State AsmState

initState :: AArch64Target -> AsmState
initState tgt = AsmState [] [] 0 Map.empty 0 0 [] "" tgt

-- | Prefix a block ID with the current function prefix to make it unique.
pfxLabel :: String -> Asm String
pfxLabel bid = do
  st <- get
  return (asmLabelPfx st ++ bid)

line :: String -> Asm ()
line s = modify' (\st -> st { asmOutput = s : asmOutput st })

getTarget :: Asm AArch64Target
getTarget = asmTarget <$> get

-- | Get or allocate a stack slot for a variable. Returns offset from x29.
varSlot :: Var -> Asm Int
varSlot v = do
  st <- get
  case Map.lookup v (asmVarMap st) of
    Just off -> return off
    Nothing -> do
      let slot = asmNextSlot st
          off  = -(16 + (slot + 1) * 8)  -- below saved x29/x30
      modify' (\s -> s { asmVarMap = Map.insert v off (asmVarMap s)
                       , asmNextSlot = slot + 1 })
      return off

-- | Register a string literal, returning its label.
addString :: String -> Asm String
addString s = do
  st <- get
  -- Check if we already have this string
  case lookup s [(v, l) | (l, v) <- asmStrTable st] of
    Just lbl -> return lbl
    Nothing -> do
      let idx = asmStrCounter st
      tgt <- getTarget
      let lbl = localPrefix tgt ++ "str" ++ show idx
      modify' (\st' -> st' { asmStrTable = (lbl, s) : asmStrTable st'
                           , asmStrCounter = idx + 1 })
      return lbl

-- | Register a match fail message string.
addMatchStr :: String -> Asm String
addMatchStr msg = do
  st <- get
  case lookup msg [(v, l) | (l, v) <- asmMatchStrs st] of
    Just lbl -> return lbl
    Nothing -> do
      let idx = length (asmMatchStrs st)
      tgt <- getTarget
      let lbl = localPrefix tgt ++ "match" ++ show idx
      modify' (\s -> s { asmMatchStrs = (lbl, msg) : asmMatchStrs s })
      return lbl

-- | Load a variable from stack into a register.
-- Uses x29 as frame base. For offsets outside [-256, 255], uses a
-- two-instruction sequence with a scratch register.
loadVar :: Var -> String -> Asm ()
loadVar v reg = do
  off <- varSlot v
  if off >= -256 && off <= 255
    then line $ "  ldur " ++ reg ++ ", [x29, #" ++ show off ++ "]"
    else do
      -- Large offset: compute address in x16 (scratch)
      emitMovImm "x16" off
      line $ "  ldr " ++ reg ++ ", [x29, x16]"

-- | Store a register into a variable's stack slot.
storeVar :: Var -> String -> Asm ()
storeVar v reg = do
  off <- varSlot v
  if off >= -256 && off <= 255
    then line $ "  stur " ++ reg ++ ", [x29, #" ++ show off ++ "]"
    else do
      -- Large offset: compute address in x16 (scratch)
      emitMovImm "x16" off
      line $ "  str " ++ reg ++ ", [x29, x16]"

-- | Emit a mov for a signed integer (handles negatives via movn).
emitMovImm :: String -> Int -> Asm ()
emitMovImm reg n
  | n >= 0 && n < 65536 = line $ "  mov " ++ reg ++ ", #" ++ show n
  | n < 0 && n >= -65536 = line $ "  movn " ++ reg ++ ", #" ++ show (-(n + 1))
  | otherwise = do
      line $ "  mov " ++ reg ++ ", #" ++ show (abs n)
      line $ "  neg " ++ reg ++ ", " ++ reg

-- | Emit sub sp, sp, #n handling large immediates.
emitSubSp :: Int -> Asm ()
emitSubSp n
  | n <= 0 = return ()
  | n <= 4095 = line $ "  sub sp, sp, #" ++ show n
  | otherwise = do
      -- Split into multiple subs
      let (q, r) = n `divMod` 4096
      when (q > 0) $ line $ "  sub sp, sp, #" ++ show (q * 4096)
      when (r > 0) $ line $ "  sub sp, sp, #" ++ show r

-- | Emit add sp, sp, #n handling large immediates.
emitAddSp :: Int -> Asm ()
emitAddSp n
  | n <= 0 = return ()
  | n <= 4095 = line $ "  add sp, sp, #" ++ show n
  | otherwise = do
      let (q, r) = n `divMod` 4096
      when (q > 0) $ line $ "  add sp, sp, #" ++ show (q * 4096)
      when (r > 0) $ line $ "  add sp, sp, #" ++ show r

-- ---------------------------------------------------------------------------
-- Pre-scan: count variables to determine frame size
-- ---------------------------------------------------------------------------

countVars :: IRFuncBody -> Int
countVars (IRFuncBody _ blocks) =
  length $ concatMap blockVars blocks
  where
    blockVars (Block _ instrs _) = concatMap instrVars instrs
    instrVars (IConst v _)       = [v]
    instrVars (IBinOp v _ _ _)   = [v]
    instrVars (IUnOp v _ _)      = [v]
    instrVars (IRecord v _)      = [v]
    instrVars (IFieldGet v _ _)  = [v]
    instrVars (ICall v _ _)      = [v]
    instrVars (IClosure v _ _)   = [v]
    instrVars (ICallClosure v _ _) = [v]
    instrVars (IRetain _)        = []
    instrVars (IRelease _)       = []
    instrVars (ITagCheck v _ _)  = [v]
    instrVars (INullCheck v _)   = [v]
    instrVars (IIntEq v _ _)     = [v]
    instrVars (IStrEq v _ _)     = [v]
    instrVars (IPrint _)         = []
    instrVars (IWrite _)         = []
    instrVars (IReadLn v)        = [v]
    instrVars (IReadInt v)       = [v]
    instrVars (ICopy v _)        = [v]

-- | Align to 16 bytes.
align16 :: Int -> Int
align16 n = ((n + 15) `div` 16) * 16

-- | Load address of a string/local label into a register.
emitLoadLabelAddr :: String -> String -> Asm ()
emitLoadLabelAddr reg lbl = do
  tgt <- getTarget
  case tgt of
    MacOS_AArch64 -> do
      line $ "  adrp " ++ reg ++ ", " ++ lbl ++ "@PAGE"
      line $ "  add "  ++ reg ++ ", " ++ reg ++ ", " ++ lbl ++ "@PAGEOFF"
    Linux_AArch64 -> do
      line $ "  adrp " ++ reg ++ ", " ++ lbl
      line $ "  add "  ++ reg ++ ", " ++ reg ++ ", :lo12:" ++ lbl

-- | Load address of a global symbol pointer into a register.
emitLoadGlobalPtr :: String -> String -> Asm ()
emitLoadGlobalPtr reg sym = do
  tgt <- getTarget
  let fullSym = symPrefix tgt ++ sym
  case tgt of
    MacOS_AArch64 -> do
      line $ "  adrp " ++ reg ++ ", " ++ fullSym ++ "@GOTPAGE"
      line $ "  ldr "  ++ reg ++ ", [" ++ reg ++ ", " ++ fullSym ++ "@GOTPAGEOFF]"
    Linux_AArch64 -> do
      line $ "  adrp " ++ reg ++ ", :got:" ++ fullSym
      line $ "  ldr "  ++ reg ++ ", [" ++ reg ++ ", :got_lo12:" ++ fullSym ++ "]"

callSym :: String -> Asm ()
callSym sym = do
  tgt <- getTarget
  line $ "  bl " ++ symPrefix tgt ++ sym

-- ---------------------------------------------------------------------------
-- Top-level emission
-- ---------------------------------------------------------------------------

-- | Generate AArch64 assembly from an IR program.
emitAArch64 :: IRProgram -> String
emitAArch64 = emitAArch64With MacOS_AArch64

-- | Generate AArch64 assembly for a specific target.
emitAArch64With :: AArch64Target -> IRProgram -> String
emitAArch64With tgt (IRProgram decls) =
  let st = execState (emitProgram decls) (initState tgt)
      asmLines = reverse (asmOutput st)
      strData  = emitStringData tgt (asmStrTable st) (asmMatchStrs st)
      gnuStack = case tgt of
                   Linux_AArch64 -> "\n.section .note.GNU-stack,\"\",@progbits\n"
                   _             -> ""
  in unlines asmLines ++ strData ++ gnuStack

emitProgram :: [IRDecl] -> Asm ()
emitProgram decls = do
  tgt <- getTarget
  line (textSection tgt)
  line ".align 2"
  line ""
  -- Emit all rites
  mapM_ emitDecl decls

emitDecl :: IRDecl -> Asm ()
emitDecl (IRFunc name body) = do
  tgt <- getTarget
  emitFunc (symPrefix tgt ++ "fn_" ++ name) body
emitDecl (IRMain body) = emitMainFunc body
emitDecl (IRTest _ _) = return ()

-- ---------------------------------------------------------------------------
-- Function emission
-- ---------------------------------------------------------------------------

emitFunc :: String -> IRFuncBody -> Asm ()
emitFunc label body = do
  tgt <- getTarget
  let nVars = countVars body + 10  -- extra slots for safety
      frameVarSpace = nVars * 8
      frameSize = align16 (16 + frameVarSpace)  -- 16 for x29/x30
      pfx = drop (length (symPrefix tgt)) label ++ "_"
  -- Reset variable map
  modify' (\s -> s { asmVarMap = Map.empty, asmNextSlot = 0, asmFrameSize = frameSize, asmLabelPfx = pfx })

  line $ ".globl " ++ label
  line $ label ++ ":"
  -- Prologue: save x29/x30 first with pre-index, then allocate frame
  line "  stp x29, x30, [sp, #-16]!"
  line "  mov x29, sp"
  emitSubSp (frameSize - 16)

  -- Store arg (x0) to its slot
  storeVar (funcParam body) "x0"

  -- Emit blocks
  mapM_ emitBlockAsm (funcBlocks body)

  line ""

emitMainFunc :: IRFuncBody -> Asm ()
emitMainFunc body = do
  tgt <- getTarget
  let nVars = countVars body + 10
      frameVarSpace = nVars * 8
      frameSize = align16 (16 + frameVarSpace)
  modify' (\s -> s { asmVarMap = Map.empty, asmNextSlot = 0, asmFrameSize = frameSize, asmLabelPfx = "main_" })

  let mainSym = symPrefix tgt ++ "main"
  line $ ".globl " ++ mainSym
  line $ mainSym ++ ":"
  -- Prologue: save x29/x30 first with pre-index, then allocate frame
  line "  stp x29, x30, [sp, #-16]!"
  line "  mov x29, sp"
  line $ "  sub sp, sp, #" ++ show (frameSize - 16)

  -- Save argc/argv to globals
  emitLoadGlobalPtr "x8" "g_argc"
  line "  str w0, [x8]"
  emitLoadGlobalPtr "x8" "g_argv"
  line "  str x1, [x8]"

  -- Store arg (not used in main, but consistent)
  storeVar (funcParam body) "x0"

  -- Emit blocks (use main-specific block emitter that handles TReturn)
  mapM_ emitBlockAsmMain (funcBlocks body)

  line ""

-- | Emit a block for main (TReturn becomes return 0 instead of returning a Value*)
emitBlockAsmMain :: Block -> Asm ()
emitBlockAsmMain (Block bid instrs term) = do
  lbl <- pfxLabel bid
  line $ lbl ++ ":"
  mapM_ emitInstrAsm instrs
  emitTermAsmMain term

emitTermAsmMain :: Terminator -> Asm ()
emitTermAsmMain (TReturn v) = do
  -- Release the void value, then return 0
  loadVar v "x0"
  callSym "rc_release"
  line "  mov x0, #0"
  st <- get
  let fs = asmFrameSize st
  emitAddSp (fs - 16)
  line "  ldp x29, x30, [sp], #16"
  line "  ret"
emitTermAsmMain other = emitTermAsm other

-- ---------------------------------------------------------------------------
-- Block emission
-- ---------------------------------------------------------------------------

emitBlockAsm :: Block -> Asm ()
emitBlockAsm (Block bid instrs term) = do
  lbl <- pfxLabel bid
  line $ lbl ++ ":"
  mapM_ emitInstrAsm instrs
  emitTermAsm term

-- ---------------------------------------------------------------------------
-- Instruction emission
-- ---------------------------------------------------------------------------

emitInstrAsm :: Instr -> Asm ()

emitInstrAsm (IConst v (OInt n)) = do
  loadImm64 "x0" n
  callSym "make_int"
  storeVar v "x0"

emitInstrAsm (IConst v (OStr s)) = do
  lbl <- addString s
  emitLoadLabelAddr "x0" lbl
  callSym "make_str"
  storeVar v "x0"

emitInstrAsm (IConst v OVoid) = do
  callSym "make_void"
  storeVar v "x0"

emitInstrAsm (IBinOp v Eq l r) = do
  loadVar l "x0"
  loadVar r "x1"
  callSym "stele_value_eq"
  callSym "make_int"
  storeVar v "x0"

emitInstrAsm (IBinOp v Neq l r) = do
  loadVar l "x0"
  loadVar r "x1"
  callSym "stele_value_neq"
  callSym "make_int"
  storeVar v "x0"

emitInstrAsm (IBinOp v op l r) = do
  loadVar l "x8"
  line "  ldr x8, [x8, #8]"     -- x8 = l->int_val
  loadVar r "x9"
  line "  ldr x9, [x9, #8]"     -- x9 = r->int_val
  emitBinOpAsm op "x8" "x9" "x0"
  callSym "make_int"
  storeVar v "x0"

emitInstrAsm (IUnOp v Neg src) = do
  loadVar src "x8"
  line "  ldr x8, [x8, #8]"
  line "  neg x0, x8"
  callSym "make_int"
  storeVar v "x0"

emitInstrAsm (IUnOp v Not src) = do
  loadVar src "x8"
  line "  ldr x8, [x8, #8]"
  line "  cmp x8, #0"
  line "  cset x0, eq"
  callSym "make_int"
  storeVar v "x0"

emitInstrAsm (IRecord v fields) = do
  let n = length fields
      namesSize = n * 8
      valsSize = n * 8
      totalSize = align16 (namesSize + valsSize)
  -- Allocate temp space on stack
  emitSubSp totalSize
  -- Store names and values
  mapM_ (\(i, (fname, fvar)) -> do
    lbl <- addString fname
    emitLoadLabelAddr "x8" lbl
    line $ "  str x8, [sp, #" ++ show (i * 8) ++ "]"  -- names[i]
    loadVar fvar "x9"
    line $ "  str x9, [sp, #" ++ show (namesSize + i * 8) ++ "]"  -- values[i]
    ) (zip [0..] fields)
  -- Call make_record_with_fields(n, names, values)
  loadImm64 "x0" (fromIntegral n)
  line "  mov x1, sp"                                    -- names array
  line $ "  add x2, sp, #" ++ show namesSize              -- values array
  callSym "make_record_with_fields"
  emitAddSp totalSize
  storeVar v "x0"

emitInstrAsm (IFieldGet v rec fld) = do
  loadVar rec "x0"
  lbl <- addString fld
  emitLoadLabelAddr "x1" lbl
  callSym "record_field"
  storeVar v "x0"

emitInstrAsm (ICall v riteName arg) = do
  loadVar arg "x0"
  callSym ("fn_" ++ riteName)
  storeVar v "x0"

emitInstrAsm (IClosure v lambdaName envFields) = do
  tgt <- getTarget
  if null envFields
    then do
      -- No captures: make_closure(fn_ptr, NULL)
      emitLoadLabelAddr "x0" (symPrefix tgt ++ "fn_" ++ lambdaName)
      line "  mov x1, #0"
      callSym "make_closure"
      storeVar v "x0"
    else do
      -- Retain captured values so env record owns them
      mapM_ (\(_, fvar) -> do
        loadVar fvar "x0"
        callSym "rc_retain"
        ) envFields
      -- Build env record
      let n = length envFields
          namesSize = n * 8
          valsSize = n * 8
          totalSize = align16 (namesSize + valsSize)
      emitSubSp totalSize
      mapM_ (\(i, (fname, fvar)) -> do
        lbl <- addString fname
        emitLoadLabelAddr "x8" lbl
        line $ "  str x8, [sp, #" ++ show (i * 8) ++ "]"
        loadVar fvar "x9"
        line $ "  str x9, [sp, #" ++ show (namesSize + i * 8) ++ "]"
        ) (zip [0..] envFields)
      loadImm64 "x0" (fromIntegral n)
      line "  mov x1, sp"
      line $ "  add x2, sp, #" ++ show namesSize
      callSym "make_record_with_fields"
      emitAddSp totalSize
      -- x0 = env record, move to x1 first (emitLoadLabelAddr only touches x0)
      line "  mov x1, x0"
      emitLoadLabelAddr "x0" (symPrefix tgt ++ "fn_" ++ lambdaName)
      callSym "make_closure"
      storeVar v "x0"

emitInstrAsm (ICallClosure v clos arg) = do
  loadVar clos "x0"
  loadVar arg "x1"
  callSym "stele_call_closure"
  storeVar v "x0"

emitInstrAsm (IRetain v) = do
  loadVar v "x0"
  callSym "rc_retain"

emitInstrAsm (IRelease v) = do
  loadVar v "x0"
  callSym "rc_release"

emitInstrAsm (ITagCheck v op tag) = do
  loadVar op "x8"
  line "  ldr w9, [x8]"              -- w9 = op->tag
  line $ "  cmp w9, #" ++ show (tagNum tag)
  line "  cset w0, eq"
  -- Store as 64-bit (zero-extended) to keep slot consistent
  storeVar v "w0"

emitInstrAsm (INullCheck v op) = do
  loadVar op "x8"
  line "  cmp x8, #0"
  line "  cset w0, ne"
  storeVar v "w0"

emitInstrAsm (IIntEq v op n) = do
  loadVar op "x8"
  line "  ldr x8, [x8, #8]"          -- x8 = op->int_val
  loadImm64 "x9" n
  line "  cmp x8, x9"
  line "  cset w0, eq"
  storeVar v "w0"

emitInstrAsm (IStrEq v op s) = do
  loadVar op "x8"
  line "  ldr x0, [x8, #8]"          -- x0 = op->str_val
  lbl <- addString s
  emitLoadLabelAddr "x1" lbl
  callSym "strcmp"
  line "  cmp w0, #0"
  line "  cset w0, eq"
  storeVar v "w0"

emitInstrAsm (IPrint v) = do
  loadVar v "x0"
  callSym "stele_print"

emitInstrAsm (IWrite v) = do
  loadVar v "x0"
  callSym "stele_write"

emitInstrAsm (IReadLn v) = do
  callSym "runtime_readln"
  storeVar v "x0"

emitInstrAsm (IReadInt v) = do
  callSym "runtime_readint"
  storeVar v "x0"

emitInstrAsm (ICopy v src) = do
  loadVar src "x8"
  storeVar v "x8"

-- ---------------------------------------------------------------------------
-- Terminator emission
-- ---------------------------------------------------------------------------

emitTermAsm :: Terminator -> Asm ()

emitTermAsm (TReturn v) = do
  loadVar v "x0"
  -- Epilogue: restore sp, then restore x29/x30 with post-index
  st <- get
  let fs = asmFrameSize st
  emitAddSp (fs - 16)
  line "  ldp x29, x30, [sp], #16"
  line "  ret"

emitTermAsm (TBranch c t f) = do
  tLbl <- pfxLabel t
  fLbl <- pfxLabel f
  loadVar c "w8"
  line $ "  cbnz w8, " ++ tLbl
  line $ "  b " ++ fLbl

emitTermAsm (TJump lbl) = do
  lbl' <- pfxLabel lbl
  line $ "  b " ++ lbl'

emitTermAsm (TMatchFail msg) = do
  lbl <- addMatchStr msg
  emitLoadLabelAddr "x0" lbl
  callSym "stele_match_fail"

-- ---------------------------------------------------------------------------
-- Helper: binary operations
-- ---------------------------------------------------------------------------

emitBinOpAsm :: BinOp -> String -> String -> String -> Asm ()
emitBinOpAsm Add l r dst = line $ "  add " ++ dst ++ ", " ++ l ++ ", " ++ r
emitBinOpAsm Sub l r dst = line $ "  sub " ++ dst ++ ", " ++ l ++ ", " ++ r
emitBinOpAsm Mul l r dst = line $ "  mul " ++ dst ++ ", " ++ l ++ ", " ++ r
emitBinOpAsm Div l r dst = line $ "  sdiv " ++ dst ++ ", " ++ l ++ ", " ++ r
emitBinOpAsm Mod l r dst = do
  line $ "  sdiv x10, " ++ l ++ ", " ++ r
  line $ "  msub " ++ dst ++ ", x10, " ++ r ++ ", " ++ l
emitBinOpAsm Eq  l r dst = do
  line $ "  cmp " ++ l ++ ", " ++ r
  line $ "  cset " ++ dst ++ ", eq"
emitBinOpAsm Neq l r dst = do
  line $ "  cmp " ++ l ++ ", " ++ r
  line $ "  cset " ++ dst ++ ", ne"
emitBinOpAsm Lt  l r dst = do
  line $ "  cmp " ++ l ++ ", " ++ r
  line $ "  cset " ++ dst ++ ", lt"
emitBinOpAsm Gt  l r dst = do
  line $ "  cmp " ++ l ++ ", " ++ r
  line $ "  cset " ++ dst ++ ", gt"
emitBinOpAsm Lte l r dst = do
  line $ "  cmp " ++ l ++ ", " ++ r
  line $ "  cset " ++ dst ++ ", le"
emitBinOpAsm Gte l r dst = do
  line $ "  cmp " ++ l ++ ", " ++ r
  line $ "  cset " ++ dst ++ ", ge"
emitBinOpAsm And l r dst = do
  -- Logical AND: both non-zero -> 1, else 0
  line $ "  cmp " ++ l ++ ", #0"
  line "  cset w10, ne"
  line $ "  cmp " ++ r ++ ", #0"
  line "  cset w11, ne"
  line $ "  and " ++ dst ++ ", x10, x11"
emitBinOpAsm Or  l r dst = do
  -- Logical OR: either non-zero -> 1, else 0
  line $ "  orr x10, " ++ l ++ ", " ++ r
  line "  cmp x10, #0"
  line $ "  cset " ++ dst ++ ", ne"

-- ---------------------------------------------------------------------------
-- Helper: load 64-bit immediate
-- ---------------------------------------------------------------------------

loadImm64 :: String -> Integer -> Asm ()
loadImm64 reg n
  | n >= 0 && n < 65536 =
      line $ "  mov " ++ reg ++ ", #" ++ show n
  | n >= 0 && n < 4294967296 = do
      line $ "  mov " ++ reg ++ ", #" ++ show (n `mod` 65536)
      line $ "  movk " ++ reg ++ ", #" ++ show ((n `div` 65536) `mod` 65536) ++ ", lsl #16"
      when (n >= 4294967296) $ do
        line $ "  movk " ++ reg ++ ", #" ++ show ((n `div` 4294967296) `mod` 65536) ++ ", lsl #32"
  | n < 0 && n >= -65536 = do
      -- Use movn for small negatives
      let pos = -(n + 1)
      line $ "  movn " ++ reg ++ ", #" ++ show pos
  | otherwise = do
      -- For larger values, use mov + movk sequence
      let unsigned = if n < 0 then n + (2^(64::Int)) else n
          w0 = unsigned `mod` 65536
          w1 = (unsigned `div` 65536) `mod` 65536
          w2 = (unsigned `div` 4294967296) `mod` 65536
          w3 = (unsigned `div` 281474976710656) `mod` 65536
      line $ "  mov " ++ reg ++ ", #" ++ show w0
      when (w1 /= 0) $ line $ "  movk " ++ reg ++ ", #" ++ show w1 ++ ", lsl #16"
      when (w2 /= 0) $ line $ "  movk " ++ reg ++ ", #" ++ show w2 ++ ", lsl #32"
      when (w3 /= 0) $ line $ "  movk " ++ reg ++ ", #" ++ show w3 ++ ", lsl #48"

when :: Bool -> Asm () -> Asm ()
when True  m = m
when False _ = return ()

-- ---------------------------------------------------------------------------
-- Tag numbers
-- ---------------------------------------------------------------------------

tagNum :: Tag -> Int
tagNum TagInt    = 0
tagNum TagStr    = 1
tagNum TagRecord = 2
tagNum TagVoid   = 3

-- ---------------------------------------------------------------------------
-- String data emission
-- ---------------------------------------------------------------------------

emitStringData :: AArch64Target -> [(String, String)] -> [(String, String)] -> String
emitStringData tgt strs matchStrs = unlines $
  [ ""
  , cstringSection tgt
  ] ++
  concatMap (\(lbl, s) ->
    [ lbl ++ ":"
    , "  .asciz " ++ asmString s
    ]) (reverse strs) ++
  concatMap (\(lbl, s) ->
    [ lbl ++ ":"
    , "  .asciz " ++ asmString s
    ]) (reverse matchStrs)

-- | Escape a string for assembly .asciz directive.
asmString :: String -> String
asmString s = "\"" ++ concatMap escChar s ++ "\""
  where
    escChar '"'  = "\\\""
    escChar '\\' = "\\\\"
    escChar '\n' = "\\n"
    escChar '\t' = "\\t"
    escChar '\r' = "\\r"
    escChar c
      | c < ' ' || c > '~' = "\\x" ++ hexByte (fromEnum c)
      | otherwise = [c]
    hexByte n = [hexDigit (n `div` 16), hexDigit (n `mod` 16)]
    hexDigit d
      | d < 10    = toEnum (fromEnum '0' + d)
      | otherwise = toEnum (fromEnum 'a' + d - 10)
