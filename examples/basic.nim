## Minimal example: tokenize a single line with a tiny inline grammar.
##
## Run from the project root:
##   nim c -r examples/hello.nim

import std/strutils

import pkg/textmate

const GrammarJson = """
{
  "scopeName": "source.demo",
  "patterns": [
    { "match": "\\bfoo\\b", "name": "keyword.foo" },
    { "match": "\\b\\d+\\b", "name": "constant.numeric" }
  ]
}
"""

let g = compileGrammar(parseRawGrammar(GrammarJson))
let line = "hello foo 42 bar"
let lt = tokenizeLine(line, initialStack(g))

echo "input: ", line
for tok in lt.tokens:
  let text = line[tok.startIndex ..< tok.endIndex]
  echo tok.startIndex,
    "..", tok.endIndex, "  ", text.escape, "  ", tok.scopes.join(", ")
