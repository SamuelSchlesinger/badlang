module Main where

import System.Environment (getArgs)
import System.IO (hPutStrLn, stderr)
import System.Exit (exitFailure, exitWith, ExitCode(..))
import System.Process (rawSystem)
import Badlang.Grammar (parseProgram)
import Badlang.Types (typeCheck)
import Badlang.Emit (emitC)

main :: IO ()
main = do
  args <- getArgs
  case args of
    ["--run", file] -> compileAndRun file
    [file]          -> compile file
    _               -> do
      hPutStrLn stderr "badlang — the language of rites and glyphs"
      hPutStrLn stderr ""
      hPutStrLn stderr "Usage:"
      hPutStrLn stderr "  badlang <source.bad>       Compile to C"
      hPutStrLn stderr "  badlang --run <source.bad>  Compile to C, build, and run"
      exitFailure

compile :: FilePath -> IO ()
compile path = do
  src <- readFile path
  case pipeline src of
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
  case pipeline src of
    Left err -> do
      hPutStrLn stderr err
      exitFailure
    Right cCode -> do
      let cPath  = replaceExtension path ".c"
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

pipeline :: String -> Either String String
pipeline src = do
  ast     <- parseProgram src
  checked <- typeCheck ast
  return (emitC checked)

replaceExtension :: FilePath -> String -> FilePath
replaceExtension path newExt =
  case break (== '.') (reverse path) of
    (_, _ : rest) -> reverse rest ++ newExt
    _             -> path ++ newExt
