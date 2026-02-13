module Main where

import System.Environment (getArgs)
import System.IO (hPutStrLn, stderr)
import System.Exit (exitFailure, exitWith, ExitCode(..))
import System.Process (rawSystem)
import System.Info (arch, os)
import Data.List (elemIndices)
import Stele.Grammar (parseProgram)
import Stele.Types (typeCheck)
import Stele.Lower (lowerProgram)
import Stele.EmitC (emitCFromIR)
import Stele.EmitAArch64 (emitAArch64)
import Stele.EmitX86_64 (emitX86_64, X86Target(..))
import Stele.Runtime (runtimeSource)

data NativeTarget = AArch64_macOS | X86_64_macOS | X86_64_Linux
  deriving (Eq, Show)

detectTarget :: Maybe NativeTarget
detectTarget = case (arch, os) of
  ("aarch64", "darwin") -> Just AArch64_macOS
  ("x86_64",  "darwin") -> Just X86_64_macOS
  ("x86_64",  "linux")  -> Just X86_64_Linux
  _                      -> Nothing

parseTarget :: String -> Maybe NativeTarget
parseTarget "aarch64-macos" = Just AArch64_macOS
parseTarget "x86_64-macos"  = Just X86_64_macOS
parseTarget "x86_64-linux"  = Just X86_64_Linux
parseTarget _               = Nothing

main :: IO ()
main = do
  args <- getArgs
  case args of
    ["--native", "--target", tgt, "--run", file] -> withTarget tgt (compileNativeAndRun file)
    ["--native", "--run", "--target", tgt, file] -> withTarget tgt (compileNativeAndRun file)
    ["--native", "--run", file]                  -> withDetectedTarget (compileNativeAndRun file)
    ["--native", "--target", tgt, file]          -> withTarget tgt (compileNative file)
    ["--native", file]                           -> withDetectedTarget (compileNative file)
    ["--run", file]                              -> compileAndRun file
    [file]                                       -> compile file
    _                                            -> do
      hPutStrLn stderr "stele — a small language with structural records and sum types"
      hPutStrLn stderr ""
      hPutStrLn stderr "Usage:"
      hPutStrLn stderr "  stele <source.stele>                              Compile to C"
      hPutStrLn stderr "  stele --run <source.stele>                        Compile to C, build, and run"
      hPutStrLn stderr "  stele --native <source.stele>                     Compile to native (auto-detect)"
      hPutStrLn stderr "  stele --native --run <source.stele>               Compile native and run"
      hPutStrLn stderr "  stele --native --target <target> <source.stele>   Compile to specific target"
      hPutStrLn stderr ""
      hPutStrLn stderr "Targets: aarch64-macos, x86_64-macos, x86_64-linux"
      exitFailure

withTarget :: String -> (NativeTarget -> IO ()) -> IO ()
withTarget tgtStr action =
  case parseTarget tgtStr of
    Just tgt -> action tgt
    Nothing -> do
      hPutStrLn stderr $ "Unknown target: " ++ tgtStr
      hPutStrLn stderr "Supported targets: aarch64-macos, x86_64-macos, x86_64-linux"
      exitFailure

withDetectedTarget :: (NativeTarget -> IO ()) -> IO ()
withDetectedTarget action =
  case detectTarget of
    Just tgt -> action tgt
    Nothing -> do
      hPutStrLn stderr $ "Cannot auto-detect native target for " ++ arch ++ "-" ++ os
      hPutStrLn stderr "Use --target to specify: aarch64-macos, x86_64-macos, x86_64-linux"
      exitFailure

compile :: FilePath -> IO ()
compile path = do
  src <- readFile path
  case pipelineC src of
    Left err -> do
      hPutStrLn stderr err
      exitFailure
    Right cCode -> do
      let outPath = replaceExtension path ".c"
      writeFile outPath cCode
      putStrLn $ "Compiled to " ++ outPath

compileAndRun :: FilePath -> IO ()
compileAndRun path = do
  src <- readFile path
  case pipelineC src of
    Left err -> do
      hPutStrLn stderr err
      exitFailure
    Right cCode -> do
      let cPath   = replaceExtension path ".c"
          binPath = replaceExtension path ""
      writeFile cPath cCode
      exitCode <- rawSystem "cc" ["-o", binPath, cPath]
      case exitCode of
        ExitSuccess -> do
          rc <- rawSystem binPath []
          exitWith rc
        ExitFailure n -> do
          hPutStrLn stderr $ "C compilation failed (exit " ++ show n ++ ")"
          exitFailure

-- | Extra cc flags for cross-compilation.
ccFlags :: NativeTarget -> [String]
ccFlags AArch64_macOS = []
ccFlags X86_64_macOS  = ["-arch", "x86_64"]
ccFlags X86_64_Linux  = []  -- requires native or cross-compiler

compileNative :: FilePath -> NativeTarget -> IO ()
compileNative path tgt = do
  src <- readFile path
  case pipelineNative tgt src of
    Left err -> do
      hPutStrLn stderr err
      exitFailure
    Right (asmCode, rtCode) -> do
      let asmPath = replaceExtension path ".s"
          rtPath  = replaceExtension path "_rt.c"
          binPath = replaceExtension path ""
      writeFile asmPath asmCode
      writeFile rtPath rtCode
      exitCode <- rawSystem "cc" (ccFlags tgt ++ ["-o", binPath, asmPath, rtPath])
      case exitCode of
        ExitSuccess ->
          putStrLn $ "Compiled to " ++ binPath
        ExitFailure n -> do
          hPutStrLn stderr $ "Native compilation failed (exit " ++ show n ++ ")"
          exitFailure

compileNativeAndRun :: FilePath -> NativeTarget -> IO ()
compileNativeAndRun path tgt = do
  src <- readFile path
  case pipelineNative tgt src of
    Left err -> do
      hPutStrLn stderr err
      exitFailure
    Right (asmCode, rtCode) -> do
      let asmPath = replaceExtension path ".s"
          rtPath  = replaceExtension path "_rt.c"
          binPath = replaceExtension path ""
      writeFile asmPath asmCode
      writeFile rtPath rtCode
      exitCode <- rawSystem "cc" (ccFlags tgt ++ ["-o", binPath, asmPath, rtPath])
      case exitCode of
        ExitSuccess -> do
          rc <- rawSystem binPath []
          exitWith rc
        ExitFailure n -> do
          hPutStrLn stderr $ "Native compilation failed (exit " ++ show n ++ ")"
          exitFailure

pipelineC :: String -> Either String String
pipelineC src = do
  ast     <- parseProgram src
  checked <- typeCheck ast
  let ir = lowerProgram checked
  return (emitCFromIR ir)

pipelineNative :: NativeTarget -> String -> Either String (String, String)
pipelineNative tgt src = do
  ast     <- parseProgram src
  checked <- typeCheck ast
  let ir  = lowerProgram checked
      asm = case tgt of
              AArch64_macOS -> emitAArch64 ir
              X86_64_macOS  -> emitX86_64 MacOS_x86_64 ir
              X86_64_Linux  -> emitX86_64 Linux_x86_64 ir
  return (asm, runtimeSource)

replaceExtension :: FilePath -> String -> FilePath
replaceExtension path newExt =
  let (revFile, revDir) = break (== '/') (reverse path)
      file = reverse revFile
      dir  = reverse revDir
      stripExt f =
        case filter (> 0) (elemIndices '.' f) of
          [] -> f
          xs -> take (last xs) f
  in dir ++ stripExt file ++ newExt
