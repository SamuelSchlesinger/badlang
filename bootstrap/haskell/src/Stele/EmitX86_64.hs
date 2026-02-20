-- | x86-64 assembly code generator for Stele.
--
-- Consumes the IR and emits a @.s@ file suitable for assembling and
-- linking with the C runtime via @cc@.
--
-- Strategy: all IR variables are stored on the stack. We primarily
-- operate through memory with a few scratch registers. This is simple,
-- correct, and sufficient for the language's scope.
--
-- Supports macOS (Mach-O) and Linux (ELF) targets:
-- * macOS: @_@ symbol prefix, @__TEXT@ sections, @L@ local labels
-- * Linux: no prefix, @.text@/@.rodata@ sections, @.L@ local labels
-- * Both use RIP-relative addressing and @\@GOTPCREL@ for globals
module Stele.EmitX86_64
  ( emitX86_64
  , X86Target(..)
  ) where

import Stele.IR
import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import Control.Monad.Trans.State.Strict (State, execState, get, modify')

-- ---------------------------------------------------------------------------
-- Target configuration
-- ---------------------------------------------------------------------------

data X86Target = MacOS_x86_64 | Linux_x86_64
  deriving (Eq, Show)

symPrefix :: X86Target -> String
symPrefix MacOS_x86_64 = "_"
symPrefix Linux_x86_64 = ""

textSection :: X86Target -> String
textSection MacOS_x86_64 = ".section __TEXT,__text"
textSection Linux_x86_64 = ".text"

cstringSection :: X86Target -> String
cstringSection MacOS_x86_64 = ".section __TEXT,__cstring"
cstringSection Linux_x86_64 = ".section .rodata"

localPrefix :: X86Target -> String
localPrefix MacOS_x86_64 = "L"
localPrefix Linux_x86_64 = ".L"

-- ---------------------------------------------------------------------------
-- Code generation state
-- ---------------------------------------------------------------------------

data AsmState = AsmState
  { asmOutput     :: [String]           -- lines of assembly (reversed)
  , asmStrTable   :: [(String, String)] -- (label, string value)
  , asmStrCounter :: !Int
  , asmVarMap     :: Map Var Int        -- var -> stack slot index
  , asmNextSlot   :: !Int               -- next available stack slot
  , asmFrameSize  :: !Int               -- total frame size for current func
  , asmMatchStrs  :: [(String, String)] -- (label, match fail message)
  , asmLabelPfx   :: String             -- prefix for block labels (func name)
  , asmTarget     :: X86Target          -- target platform
  }

type Asm = State AsmState

initState :: X86Target -> AsmState
initState tgt = AsmState [] [] 0 Map.empty 0 0 [] "" tgt

-- | Prefix a block ID with the current function prefix to make it unique.
pfxLabel :: String -> Asm String
pfxLabel bid = do
  st <- get
  return (asmLabelPfx st ++ bid)

line :: String -> Asm ()
line s = modify' (\st -> st { asmOutput = s : asmOutput st })

getTarget :: Asm X86Target
getTarget = asmTarget <$> get

-- | Get or allocate a stack slot for a variable.
-- Returns offset from rbp: -(slot + 1) * 8.
varSlot :: Var -> Asm Int
varSlot v = do
  st <- get
  case Map.lookup v (asmVarMap st) of
    Just off -> return off
    Nothing -> do
      let slot = asmNextSlot st
          off  = -(slot + 1) * 8
      modify' (\s -> s { asmVarMap = Map.insert v off (asmVarMap s)
                       , asmNextSlot = slot + 1 })
      return off

-- | Register a string literal, returning its label.
addString :: String -> Asm String
addString s = do
  st <- get
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
-- x86-64 supports 32-bit displacements, so no large-offset workaround needed.
loadVar :: Var -> String -> Asm ()
loadVar v reg = do
  off <- varSlot v
  line $ "  movq " ++ show off ++ "(%rbp), " ++ reg

-- | Store a register into a variable's stack slot.
storeVar :: Var -> String -> Asm ()
storeVar v reg = do
  off <- varSlot v
  line $ "  movq " ++ reg ++ ", " ++ show off ++ "(%rbp)"

-- | Load a 64-bit immediate into a register.
loadImm64 :: String -> Integer -> Asm ()
loadImm64 reg n
  | n >= -2147483648 && n <= 2147483647 =
      line $ "  movq $" ++ show n ++ ", " ++ reg
  | otherwise =
      line $ "  movabsq $" ++ show n ++ ", " ++ reg

-- | Align to 16 bytes.
align16 :: Int -> Int
align16 n = ((n + 15) `div` 16) * 16

when :: Bool -> Asm () -> Asm ()
when True  m = m
when False _ = return ()

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

-- ---------------------------------------------------------------------------
-- Top-level emission
-- ---------------------------------------------------------------------------

-- | Generate x86-64 assembly from an IR program.
emitX86_64 :: X86Target -> IRProgram -> String
emitX86_64 tgt (IRProgram decls) =
  let st = execState (emitProgram decls) (initState tgt)
      asmLines = reverse (asmOutput st)
      strData  = emitStringData tgt (asmStrTable st) (asmMatchStrs st)
      gnuStack = case tgt of
                   Linux_x86_64 -> "\n.section .note.GNU-stack,\"\",@progbits\n"
                   _            -> ""
  in unlines asmLines ++ strData ++ gnuStack

emitProgram :: [IRDecl] -> Asm ()
emitProgram decls = do
  tgt <- getTarget
  line (textSection tgt)
  line ".p2align 4"
  line ""
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
  let nVars = countVars body + 10
      frameSize = align16 (nVars * 8)
      pfx = drop 1 label ++ "_"
  modify' (\s -> s { asmVarMap = Map.empty, asmNextSlot = 0
                   , asmFrameSize = frameSize, asmLabelPfx = pfx })

  line $ ".globl " ++ label
  line $ label ++ ":"
  -- Prologue
  line "  pushq %rbp"
  line "  movq %rsp, %rbp"
  when (frameSize > 0) $
    line $ "  subq $" ++ show frameSize ++ ", %rsp"

  -- Store arg (%rdi) to its slot
  storeVar (funcParam body) "%rdi"

  -- Emit blocks
  mapM_ emitBlockAsm (funcBlocks body)

  line ""

emitMainFunc :: IRFuncBody -> Asm ()
emitMainFunc body = do
  tgt <- getTarget
  let nVars = countVars body + 10
      frameSize = align16 (nVars * 8)
      pfx = symPrefix tgt ++ "main_"
  modify' (\s -> s { asmVarMap = Map.empty, asmNextSlot = 0
                   , asmFrameSize = frameSize, asmLabelPfx = pfx })

  let mainLabel = symPrefix tgt ++ "main"
  line $ ".globl " ++ mainLabel
  line $ mainLabel ++ ":"
  -- Prologue
  line "  pushq %rbp"
  line "  movq %rsp, %rbp"
  when (frameSize > 0) $
    line $ "  subq $" ++ show frameSize ++ ", %rsp"

  -- Save argc/argv to globals via GOT
  let sp = symPrefix tgt
  line $ "  movq " ++ sp ++ "g_argc@GOTPCREL(%rip), %r8"
  line "  movl %edi, (%r8)"
  line $ "  movq " ++ sp ++ "g_argv@GOTPCREL(%rip), %r8"
  line "  movq %rsi, (%r8)"

  -- Store arg (not used in main, but consistent)
  storeVar (funcParam body) "%rdi"

  -- Emit blocks (use main-specific block emitter that handles TReturn)
  mapM_ emitBlockAsmMain (funcBlocks body)

  line ""

-- | Emit a block for main (TReturn becomes return 0)
emitBlockAsmMain :: Block -> Asm ()
emitBlockAsmMain (Block bid instrs term) = do
  lbl <- pfxLabel bid
  line $ lbl ++ ":"
  mapM_ emitInstrAsm instrs
  emitTermAsmMain term

emitTermAsmMain :: Terminator -> Asm ()
emitTermAsmMain (TReturn v) = do
  tgt <- getTarget
  -- Release the void value, then return 0
  loadVar v "%rdi"
  line $ "  callq " ++ symPrefix tgt ++ "rc_release"
  line "  xorl %eax, %eax"
  st <- get
  let fs = asmFrameSize st
  when (fs > 0) $
    line $ "  addq $" ++ show fs ++ ", %rsp"
  line "  popq %rbp"
  line "  retq"
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
  tgt <- getTarget
  loadImm64 "%rdi" n
  line $ "  callq " ++ symPrefix tgt ++ "make_int"
  storeVar v "%rax"

emitInstrAsm (IConst v (OStr s)) = do
  tgt <- getTarget
  lbl <- addString s
  line $ "  leaq " ++ lbl ++ "(%rip), %rdi"
  line $ "  callq " ++ symPrefix tgt ++ "make_str"
  storeVar v "%rax"

emitInstrAsm (IConst v OVoid) = do
  tgt <- getTarget
  line $ "  callq " ++ symPrefix tgt ++ "make_void"
  storeVar v "%rax"

emitInstrAsm (IBinOp v Eq l r) = do
  tgt <- getTarget
  loadVar l "%rdi"
  loadVar r "%rsi"
  line $ "  callq " ++ symPrefix tgt ++ "stele_value_eq"
  line "  movl %eax, %edi"  -- zero-extend 32-bit int return to 64-bit arg
  line $ "  callq " ++ symPrefix tgt ++ "make_int"
  storeVar v "%rax"

emitInstrAsm (IBinOp v Neq l r) = do
  tgt <- getTarget
  loadVar l "%rdi"
  loadVar r "%rsi"
  line $ "  callq " ++ symPrefix tgt ++ "stele_value_neq"
  line "  movl %eax, %edi"  -- zero-extend 32-bit int return to 64-bit arg
  line $ "  callq " ++ symPrefix tgt ++ "make_int"
  storeVar v "%rax"

emitInstrAsm (IBinOp v op l r) = do
  tgt <- getTarget
  loadVar l "%r8"
  line "  movq 8(%r8), %r8"     -- r8 = l->int_val
  loadVar r "%r9"
  line "  movq 8(%r9), %r9"     -- r9 = r->int_val
  emitBinOpAsm op
  line $ "  callq " ++ symPrefix tgt ++ "make_int"
  storeVar v "%rax"

emitInstrAsm (IUnOp v Neg src) = do
  tgt <- getTarget
  loadVar src "%r8"
  line "  movq 8(%r8), %r8"
  line "  negq %r8"
  line "  movq %r8, %rdi"
  line $ "  callq " ++ symPrefix tgt ++ "make_int"
  storeVar v "%rax"

emitInstrAsm (IUnOp v Not src) = do
  tgt <- getTarget
  loadVar src "%r8"
  line "  movq 8(%r8), %r8"
  line "  testq %r8, %r8"
  line "  sete %dil"
  line "  movzbl %dil, %edi"
  line $ "  callq " ++ symPrefix tgt ++ "make_int"
  storeVar v "%rax"

emitInstrAsm (IRecord v fields) = do
  tgt <- getTarget
  let n = length fields
      namesSize = n * 8
      valsSize = n * 8
      totalSize = align16 (namesSize + valsSize)
  -- Allocate temp space on stack
  when (totalSize > 0) $
    line $ "  subq $" ++ show totalSize ++ ", %rsp"
  -- Store names and values
  mapM_ (\(i, (fname, fvar)) -> do
    lbl <- addString fname
    line $ "  leaq " ++ lbl ++ "(%rip), %r8"
    line $ "  movq %r8, " ++ show (i * 8) ++ "(%rsp)"
    loadVar fvar "%r9"
    line $ "  movq %r9, " ++ show (namesSize + i * 8) ++ "(%rsp)"
    ) (zip [0..] fields)
  -- Call make_record_with_fields(n, names, values)
  loadImm64 "%rdi" (fromIntegral n)
  line "  movq %rsp, %rsi"
  line $ "  leaq " ++ show namesSize ++ "(%rsp), %rdx"
  line $ "  callq " ++ symPrefix tgt ++ "make_record_with_fields"
  when (totalSize > 0) $
    line $ "  addq $" ++ show totalSize ++ ", %rsp"
  storeVar v "%rax"

emitInstrAsm (IFieldGet v rec fld) = do
  tgt <- getTarget
  loadVar rec "%rdi"
  lbl <- addString fld
  line $ "  leaq " ++ lbl ++ "(%rip), %rsi"
  line $ "  callq " ++ symPrefix tgt ++ "record_field"
  storeVar v "%rax"

emitInstrAsm (ICall v riteName arg) = do
  tgt <- getTarget
  loadVar arg "%rdi"
  line $ "  callq " ++ symPrefix tgt ++ "fn_" ++ riteName
  storeVar v "%rax"

emitInstrAsm (IClosure v lambdaName envFields) = do
  tgt <- getTarget
  if null envFields
    then do
      -- No captures: make_closure(fn_ptr, NULL)
      line $ "  leaq " ++ symPrefix tgt ++ "fn_" ++ lambdaName ++ "(%rip), %rdi"
      line "  xorq %rsi, %rsi"
      line $ "  callq " ++ symPrefix tgt ++ "make_closure"
      storeVar v "%rax"
    else do
      -- Retain captured values so env record owns them
      mapM_ (\(_, fvar) -> do
        loadVar fvar "%rdi"
        line $ "  callq " ++ symPrefix tgt ++ "rc_retain"
        ) envFields
      -- Build env record
      let n = length envFields
          namesSize = n * 8
          valsSize = n * 8
          totalSize = align16 (namesSize + valsSize)
      when (totalSize > 0) $
        line $ "  subq $" ++ show totalSize ++ ", %rsp"
      mapM_ (\(i, (fname, fvar)) -> do
        lbl <- addString fname
        line $ "  leaq " ++ lbl ++ "(%rip), %r8"
        line $ "  movq %r8, " ++ show (i * 8) ++ "(%rsp)"
        loadVar fvar "%r9"
        line $ "  movq %r9, " ++ show (namesSize + i * 8) ++ "(%rsp)"
        ) (zip [0..] envFields)
      loadImm64 "%rdi" (fromIntegral n)
      line "  movq %rsp, %rsi"
      line $ "  leaq " ++ show namesSize ++ "(%rsp), %rdx"
      line $ "  callq " ++ symPrefix tgt ++ "make_record_with_fields"
      when (totalSize > 0) $
        line $ "  addq $" ++ show totalSize ++ ", %rsp"
      -- %rax = env record, save to %rbx (callee-saved)
      line "  movq %rax, %rbx"
      line $ "  leaq " ++ symPrefix tgt ++ "fn_" ++ lambdaName ++ "(%rip), %rdi"
      line "  movq %rbx, %rsi"
      line $ "  callq " ++ symPrefix tgt ++ "make_closure"
      storeVar v "%rax"

emitInstrAsm (ICallClosure v clos arg) = do
  tgt <- getTarget
  loadVar clos "%rdi"
  loadVar arg "%rsi"
  line $ "  callq " ++ symPrefix tgt ++ "stele_call_closure"
  storeVar v "%rax"

emitInstrAsm (IRetain v) = do
  tgt <- getTarget
  loadVar v "%rdi"
  line $ "  callq " ++ symPrefix tgt ++ "rc_retain"

emitInstrAsm (IRelease v) = do
  tgt <- getTarget
  loadVar v "%rdi"
  line $ "  callq " ++ symPrefix tgt ++ "rc_release"

emitInstrAsm (ITagCheck v op tag) = do
  loadVar op "%r8"
  line "  movl (%r8), %r9d"
  line $ "  cmpl $" ++ show (tagNum tag) ++ ", %r9d"
  line "  sete %al"
  line "  movzbl %al, %eax"
  storeVar v "%rax"

emitInstrAsm (INullCheck v op) = do
  loadVar op "%r8"
  line "  testq %r8, %r8"
  line "  setne %al"
  line "  movzbl %al, %eax"
  storeVar v "%rax"

emitInstrAsm (IIntEq v op n) = do
  loadVar op "%r8"
  line "  movq 8(%r8), %r8"
  loadImm64 "%r9" n
  line "  cmpq %r9, %r8"
  line "  sete %al"
  line "  movzbl %al, %eax"
  storeVar v "%rax"

emitInstrAsm (IStrEq v op s) = do
  tgt <- getTarget
  loadVar op "%r8"
  line "  movq 8(%r8), %rdi"
  lbl <- addString s
  line $ "  leaq " ++ lbl ++ "(%rip), %rsi"
  line $ "  callq " ++ symPrefix tgt ++ "strcmp"
  line "  testl %eax, %eax"
  line "  sete %al"
  line "  movzbl %al, %eax"
  storeVar v "%rax"

emitInstrAsm (IPrint v) = do
  tgt <- getTarget
  loadVar v "%rdi"
  line $ "  callq " ++ symPrefix tgt ++ "stele_print"

emitInstrAsm (IWrite v) = do
  tgt <- getTarget
  loadVar v "%rdi"
  line $ "  callq " ++ symPrefix tgt ++ "stele_write"

emitInstrAsm (IReadLn v) = do
  tgt <- getTarget
  line $ "  callq " ++ symPrefix tgt ++ "runtime_readln"
  storeVar v "%rax"

emitInstrAsm (IReadInt v) = do
  tgt <- getTarget
  line $ "  callq " ++ symPrefix tgt ++ "runtime_readint"
  storeVar v "%rax"

emitInstrAsm (ICopy v src) = do
  loadVar src "%r8"
  storeVar v "%r8"

-- ---------------------------------------------------------------------------
-- Terminator emission
-- ---------------------------------------------------------------------------

emitTermAsm :: Terminator -> Asm ()

emitTermAsm (TReturn v) = do
  loadVar v "%rax"
  st <- get
  let fs = asmFrameSize st
  when (fs > 0) $
    line $ "  addq $" ++ show fs ++ ", %rsp"
  line "  popq %rbp"
  line "  retq"

emitTermAsm (TBranch c t f) = do
  tLbl <- pfxLabel t
  fLbl <- pfxLabel f
  loadVar c "%rax"
  line "  testl %eax, %eax"
  line $ "  jne " ++ tLbl
  line $ "  jmp " ++ fLbl

emitTermAsm (TJump lbl) = do
  lbl' <- pfxLabel lbl
  line $ "  jmp " ++ lbl'

emitTermAsm (TMatchFail msg) = do
  tgt <- getTarget
  lbl <- addMatchStr msg
  line $ "  leaq " ++ lbl ++ "(%rip), %rdi"
  line $ "  callq " ++ symPrefix tgt ++ "stele_match_fail"

-- ---------------------------------------------------------------------------
-- Helper: binary operations
-- ---------------------------------------------------------------------------

-- | Emit binary op. Operands are in %r8 (left) and %r9 (right).
-- Result goes to %rdi (first arg register for make_int call).
emitBinOpAsm :: BinOp -> Asm ()
emitBinOpAsm Add = do
  line "  addq %r9, %r8"
  line "  movq %r8, %rdi"
emitBinOpAsm Sub = do
  line "  subq %r9, %r8"
  line "  movq %r8, %rdi"
emitBinOpAsm Mul = do
  line "  imulq %r9, %r8"
  line "  movq %r8, %rdi"
emitBinOpAsm Div = do
  line "  movq %r8, %rax"
  line "  cqo"
  line "  idivq %r9"
  line "  movq %rax, %rdi"
emitBinOpAsm Mod = do
  line "  movq %r8, %rax"
  line "  cqo"
  line "  idivq %r9"
  line "  movq %rdx, %rdi"
emitBinOpAsm Eq = do
  line "  cmpq %r9, %r8"
  line "  sete %dil"
  line "  movzbl %dil, %edi"
emitBinOpAsm Neq = do
  line "  cmpq %r9, %r8"
  line "  setne %dil"
  line "  movzbl %dil, %edi"
emitBinOpAsm Lt = do
  line "  cmpq %r9, %r8"
  line "  setl %dil"
  line "  movzbl %dil, %edi"
emitBinOpAsm Gt = do
  line "  cmpq %r9, %r8"
  line "  setg %dil"
  line "  movzbl %dil, %edi"
emitBinOpAsm Lte = do
  line "  cmpq %r9, %r8"
  line "  setle %dil"
  line "  movzbl %dil, %edi"
emitBinOpAsm Gte = do
  line "  cmpq %r9, %r8"
  line "  setge %dil"
  line "  movzbl %dil, %edi"
emitBinOpAsm And = do
  line "  testq %r8, %r8"
  line "  setne %al"
  line "  testq %r9, %r9"
  line "  setne %cl"
  line "  andb %cl, %al"
  line "  movzbl %al, %edi"
emitBinOpAsm Or = do
  line "  orq %r9, %r8"
  line "  testq %r8, %r8"
  line "  setne %dil"
  line "  movzbl %dil, %edi"

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

emitStringData :: X86Target -> [(String, String)] -> [(String, String)] -> String
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
