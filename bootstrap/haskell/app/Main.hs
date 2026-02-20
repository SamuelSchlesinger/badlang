module Main where

import System.Environment (getArgs)
import System.IO (hPutStrLn, stderr)
import System.Exit (exitFailure, exitWith, ExitCode(..))
import System.Process (rawSystem)
import System.Info (arch, os)
import Data.List (elemIndices, isPrefixOf)
import Stele.Grammar (parseProgram)
import Stele.Types (typeCheck)
import Stele.Lower (lowerProgram)
import Stele.EmitC (emitCFromIR, emitCFromIRTest)
import Stele.EmitAArch64 (emitAArch64With, AArch64Target(..))
import Stele.EmitX86_64 (emitX86_64, X86Target(..))
import Stele.Runtime (runtimeSource)
import Stele.Resolve (resolveModules)

data NativeTarget = AArch64_macOS | AArch64_Linux | X86_64_macOS | X86_64_Linux
  deriving (Eq, Show)

detectTarget :: Maybe NativeTarget
detectTarget = case (arch, os) of
  ("aarch64", "darwin") -> Just AArch64_macOS
  ("aarch64", "linux")  -> Just AArch64_Linux
  ("x86_64",  "darwin") -> Just X86_64_macOS
  ("x86_64",  "linux")  -> Just X86_64_Linux
  _                      -> Nothing

parseTarget :: String -> Maybe NativeTarget
parseTarget "aarch64-macos" = Just AArch64_macOS
parseTarget "aarch64-linux" = Just AArch64_Linux
parseTarget "x86_64-macos"  = Just X86_64_macOS
parseTarget "x86_64-linux"  = Just X86_64_Linux
parseTarget _               = Nothing

-- | Extract search paths (-I / --search-path flags) and remaining args.
extractSearchPaths :: [String] -> ([FilePath], [String])
extractSearchPaths [] = ([], [])
extractSearchPaths ("-I":p:rest) =
  let (ps, args) = extractSearchPaths rest in (p:ps, args)
extractSearchPaths ("--search-path":p:rest) =
  let (ps, args) = extractSearchPaths rest in (p:ps, args)
extractSearchPaths (a:rest)
  | "-I" `isPrefixOf` a =
      let p = drop 2 a
          (ps, args) = extractSearchPaths rest
      in (p:ps, args)
  | otherwise =
      let (ps, args) = extractSearchPaths rest in (ps, a:args)

main :: IO ()
main = do
  allArgs <- getArgs
  let (searchPaths, args) = extractSearchPaths allArgs
  case args of
    ["--native", "--target", tgt, "--run", file] -> withTarget tgt (compileNativeAndRun file searchPaths)
    ["--native", "--run", "--target", tgt, file] -> withTarget tgt (compileNativeAndRun file searchPaths)
    ["--native", "--run", file]                  -> withDetectedTarget (compileNativeAndRun file searchPaths)
    ["--native", "--target", tgt, file]          -> withTarget tgt (compileNative file searchPaths)
    ["--native", file]                           -> withDetectedTarget (compileNative file searchPaths)
    ["--test", "--run", file]                     -> compileTestAndRun file searchPaths
    ["--test", file]                             -> compileTest file searchPaths
    ["--run", file]                              -> compileAndRun file searchPaths
    [file]                                       -> compile file searchPaths
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
      hPutStrLn stderr "Options:"
      hPutStrLn stderr "  -I <path>, --search-path <path>   Add module search path"
      hPutStrLn stderr ""
      hPutStrLn stderr "Targets: aarch64-macos, aarch64-linux, x86_64-macos, x86_64-linux"
      exitFailure

withTarget :: String -> (NativeTarget -> IO ()) -> IO ()
withTarget tgtStr action =
  case parseTarget tgtStr of
    Just tgt -> action tgt
    Nothing -> do
      hPutStrLn stderr $ "Unknown target: " ++ tgtStr
      hPutStrLn stderr "Supported targets: aarch64-macos, aarch64-linux, x86_64-macos, x86_64-linux"
      exitFailure

withDetectedTarget :: (NativeTarget -> IO ()) -> IO ()
withDetectedTarget action =
  case detectTarget of
    Just tgt -> action tgt
    Nothing -> do
      hPutStrLn stderr $ "Cannot auto-detect native target for " ++ arch ++ "-" ++ os
      hPutStrLn stderr "Use --target to specify: aarch64-macos, aarch64-linux, x86_64-macos, x86_64-linux"
      exitFailure

compile :: FilePath -> [FilePath] -> IO ()
compile path searchPaths = do
  src <- readFile path
  result <- pipelineC path searchPaths src
  case result of
    Left err -> do
      hPutStrLn stderr err
      exitFailure
    Right cCode -> do
      let outPath = replaceExtension path ".c"
      writeFile outPath cCode
      putStrLn $ "Compiled to " ++ outPath

compileAndRun :: FilePath -> [FilePath] -> IO ()
compileAndRun path searchPaths = do
  src <- readFile path
  result <- pipelineC path searchPaths src
  case result of
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
ccFlags AArch64_Linux = []
ccFlags X86_64_macOS  = ["-arch", "x86_64"]
ccFlags X86_64_Linux  = []  -- requires native or cross-compiler

compileNative :: FilePath -> [FilePath] -> NativeTarget -> IO ()
compileNative path searchPaths tgt = do
  src <- readFile path
  result <- pipelineNative tgt path searchPaths src
  case result of
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

compileNativeAndRun :: FilePath -> [FilePath] -> NativeTarget -> IO ()
compileNativeAndRun path searchPaths tgt = do
  src <- readFile path
  result <- pipelineNative tgt path searchPaths src
  case result of
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

compileTest :: FilePath -> [FilePath] -> IO ()
compileTest path searchPaths = do
  src <- readFile path
  result <- pipelineCTest path searchPaths src
  case result of
    Left err -> do
      hPutStrLn stderr err
      exitFailure
    Right cCode -> do
      let outPath = replaceExtension path ".c"
      writeFile outPath cCode
      putStrLn $ "Compiled test runner to " ++ outPath

compileTestAndRun :: FilePath -> [FilePath] -> IO ()
compileTestAndRun path searchPaths = do
  src <- readFile path
  result <- pipelineCTest path searchPaths src
  case result of
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

pipelineC :: FilePath -> [FilePath] -> String -> IO (Either String String)
pipelineC path searchPaths src =
  case parseProgram src of
    Left err -> return (Left err)
    Right ast -> do
      resolved <- resolveModules path searchPaths ast
      return $ resolved >>= \flat -> typeCheck flat >>= \checked ->
        Right (emitCFromIR (lowerProgram checked))

pipelineCTest :: FilePath -> [FilePath] -> String -> IO (Either String String)
pipelineCTest path searchPaths src =
  case parseProgram src of
    Left err -> return (Left err)
    Right ast -> do
      resolved <- resolveModules path searchPaths ast
      return $ resolved >>= \flat -> typeCheck flat >>= \checked ->
        Right (emitCFromIRTest (lowerProgram checked))

pipelineNative :: NativeTarget -> FilePath -> [FilePath] -> String -> IO (Either String (String, String))
pipelineNative tgt path searchPaths src =
  case parseProgram src of
    Left err -> return (Left err)
    Right ast -> do
      resolved <- resolveModules path searchPaths ast
      return $ resolved >>= \flat -> typeCheck flat >>= \checked ->
        let ir  = lowerProgram checked
            asm = case tgt of
                    AArch64_macOS -> emitAArch64With MacOS_AArch64 ir
                    AArch64_Linux -> emitAArch64With Linux_AArch64 ir
                    X86_64_macOS  -> emitX86_64 MacOS_x86_64 ir
                    X86_64_Linux  -> emitX86_64 Linux_x86_64 ir
        in Right (asm, runtimeSource)

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
