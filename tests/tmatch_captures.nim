import std/unittest

import textmate

suite "match captures":
  test "numbered captures split the match into sub-tokens":
    let jsonStr = """
    {
      "scopeName": "source.test",
      "patterns": [ {
        "match": "(\\w+)\\s*=\\s*(\\d+)",
        "name": "meta.assignment",
        "captures": {
          "1": { "name": "variable" },
          "2": { "name": "number" }
        }
      } ]
    }
    """
    let g = compileGrammar(parseRawGrammar(jsonStr))
    let lt = tokenizeLine("x = 42", initialStack(g))

    check lt.tokens.len == 3

    check lt.tokens[0].startIndex == 0
    check lt.tokens[0].endIndex == 1
    check lt.tokens[0].scopes == @["source.test", "meta.assignment", "variable"]

    check lt.tokens[1].startIndex == 1
    check lt.tokens[1].endIndex == 4
    check lt.tokens[1].scopes == @["source.test", "meta.assignment"]

    check lt.tokens[2].startIndex == 4
    check lt.tokens[2].endIndex == 6
    check lt.tokens[2].scopes == @["source.test", "meta.assignment", "number"]

  test "nested captures inherit the outer scope and stack the inner one on top":
    # An inner capture group sitting inside an outer capture group's span
    # must inherit the outer scope. The Oniguruma-style backtracking
    # `(\\w+(\\d+))` on "abc42" settles with outer at [0,5) and inner at
    # [4,5), so the emitted tokens split at position 4.
    let jsonStr = """
    {
      "scopeName": "source.test",
      "patterns": [ {
        "match": "(\\w+(\\d+))",
        "name": "meta.outer",
        "captures": {
          "1": { "name": "outer.scope" },
          "2": { "name": "inner.scope" }
        }
      } ]
    }
    """
    let g = compileGrammar(parseRawGrammar(jsonStr))
    let lt = tokenizeLine("abc42", initialStack(g))

    check lt.tokens.len == 2
    check lt.tokens[0].startIndex == 0
    check lt.tokens[0].endIndex == 4
    check lt.tokens[0].scopes == @["source.test", "meta.outer", "outer.scope"]
    check lt.tokens[1].startIndex == 4
    check lt.tokens[1].endIndex == 5
    check lt.tokens[1].scopes ==
      @["source.test", "meta.outer", "outer.scope", "inner.scope"]
