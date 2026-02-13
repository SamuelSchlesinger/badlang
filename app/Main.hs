module Main where

import System.Environment (getArgs)
import System.IO (hPutStrLn, stderr)
import System.Exit (exitFailure, exitWith, ExitCode(..))
import System.Process (rawSystem)
import Stele.Grammar (parseProgram)
import Stele.Types (typeCheck)
import Stele.Lower (lowerProgram)
import Stele.EmitC (emitCFromIR)
import Stele.EmitAArch64 (emitAArch64)
import Stele.Runtime (runtimeSource)

main :: IO ()
main = do
  args <- getArgs
  case args of
    ["--native", "--run", file] -> compileNativeAndRun file
    ["--native", file]          -> compileNative file
    ["--run", file]             -> compileAndRun file
    [file]                      -> compile file
    _                           -> do
      hPutStrLn stderr "stele — a small language with structural records and sum types"
      hPutStrLn stderr ""
      hPutStrLn stderr "Usage:"
      hPutStrLn stderr "  stele <source.stele>                Compile to C"
      hPutStrLn stderr "  stele --run <source.stele>          Compile to C, build, and run"
      hPutStrLn stderr "  stele --native <source.stele>       Compile to native (aarch64)"
      hPutStrLn stderr "  stele --native --run <source.stele> Compile native and run"
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

compileNative :: FilePath -> IO ()
compileNative path = do
  src <- readFile path
  case pipelineNative src of
    Left err -> do
      hPutStrLn stderr err
      exitFailure
    Right (asmCode, rtCode) -> do
      let asmPath = replaceExtension path ".s"
          rtPath  = replaceExtension path "_rt.c"
          binPath = replaceExtension path ""
      writeFile asmPath asmCode
      writeFile rtPath rtCode
      exitCode <- rawSystem "cc" ["-o", binPath, asmPath, rtPath]
      case exitCode of
        ExitSuccess ->
          putStrLn $ "Compiled to " ++ binPath
        ExitFailure n -> do
          hPutStrLn stderr $ "Native compilation failed (exit " ++ show n ++ ")"
          exitFailure

compileNativeAndRun :: FilePath -> IO ()
compileNativeAndRun path = do
  src <- readFile path
  case pipelineNative src of
    Left err -> do
      hPutStrLn stderr err
      exitFailure
    Right (asmCode, rtCode) -> do
      let asmPath = replaceExtension path ".s"
          rtPath  = replaceExtension path "_rt.c"
          binPath = replaceExtension path ""
      writeFile asmPath asmCode
      writeFile rtPath rtCode
      exitCode <- rawSystem "cc" ["-o", binPath, asmPath, rtPath]
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

pipelineNative :: String -> Either String (String, String)
pipelineNative src = do
  ast     <- parseProgram src
  checked <- typeCheck ast
  let ir = lowerProgram checked
  return (emitAArch64 ir, runtimeSource)

replaceExtension :: FilePath -> String -> FilePath
replaceExtension path newExt =
  case break (== '.') (reverse path) of
    (_, _ : rest) -> reverse rest ++ newExt
    _             -> path ++ newExt
