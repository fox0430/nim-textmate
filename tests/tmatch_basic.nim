import std/unittest

import textmate

suite "match basic":
  test "single match rule emits gap, match, gap tokens":
    let jsonStr = """
    {
      "scopeName": "source.test",
      "patterns": [ { "match": "\\bfoo\\b", "name": "keyword.foo" } ]
    }
    """
    let g = compileGrammar(parseRawGrammar(jsonStr))
    let lt = tokenizeLine("hello foo bar", initialStack(g))

    check lt.tokens.len == 3

    check lt.tokens[0].startIndex == 0
    check lt.tokens[0].endIndex == 6
    check lt.tokens[0].scopes == @["source.test"]

    check lt.tokens[1].startIndex == 6
    check lt.tokens[1].endIndex == 9
    check lt.tokens[1].scopes == @["source.test", "keyword.foo"]

    check lt.tokens[2].startIndex == 9
    check lt.tokens[2].endIndex == 13
    check lt.tokens[2].scopes == @["source.test"]

  test "no match returns a single default-scope token covering the whole line":
    let jsonStr = """
    {
      "scopeName": "source.test",
      "patterns": [ { "match": "\\bnope\\b", "name": "x" } ]
    }
    """
    let g = compileGrammar(parseRawGrammar(jsonStr))
    let lt = tokenizeLine("hello world", initialStack(g))

    check lt.tokens.len == 1
    check lt.tokens[0].startIndex == 0
    check lt.tokens[0].endIndex == 11
    check lt.tokens[0].scopes == @["source.test"]
