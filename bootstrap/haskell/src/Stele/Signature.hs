-- | Parses @.steli@ signature files that control which names a module exports.
--
-- Format: one export per line, prefixed with its declaration kind:
--
-- @
-- fn factorial
-- fn square
-- struct Point
-- oneof Shape
-- @
--
-- Lines starting with @--@ are comments. Blank lines are ignored.
-- If a @.steli@ file does not exist for a module, all declarations are exported.
module Stele.Signature
  ( parseSignature
  ) where

import qualified Data.Set as Set

-- | Parse the contents of a @.steli@ file into a set of exported names.
parseSignature :: String -> Either String (Set.Set String)
parseSignature contents =
  let ls = lines contents
      parsed = mapM parseLine (filter (not . isIgnored) ls)
  in  Set.fromList <$> parsed

isIgnored :: String -> Bool
isIgnored l =
  let stripped = dropWhile (== ' ') l
  in  null stripped || take 2 stripped == "--"

parseLine :: String -> Either String String
parseLine l =
  let stripped = dropWhile (== ' ') l
  in case break (== ' ') stripped of
    (kind, rest)
      | kind `elem` ["fn", "struct", "oneof", "do", "test"] ->
          let name = dropWhile (== ' ') rest
          in  if null name
              then Left $ "Signature line missing name: " ++ l
              else Right (takeWhile (/= ' ') name)
      | otherwise -> Left $ "Unknown signature kind: " ++ kind ++ " in line: " ++ l
