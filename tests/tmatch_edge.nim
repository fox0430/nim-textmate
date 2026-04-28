import std/unittest

import textmate

suite "match edge":
  test "empty input returns no tokens":
    let jsonStr = """
    {
      "scopeName": "source.test",
      "patterns": [ { "match": "foo", "name": "x" } ]
    }
    """
    let g = compileGrammar(parseRawGrammar(jsonStr))
    let lt = tokenizeLine("", initialStack(g))

    check lt.tokens.len == 0

  test "capture group 0 adds a scope to the entire match":
    let jsonStr = """
    {
      "scopeName": "source.test",
      "patterns": [ {
        "match": "foo",
        "name": "rule.name",
        "captures": { "0": { "name": "whole.match" } }
      } ]
    }
    """
    let g = compileGrammar(parseRawGrammar(jsonStr))
    let lt = tokenizeLine("foo", initialStack(g))

    check lt.tokens.len == 1
    check lt.tokens[0].startIndex == 0
    check lt.tokens[0].endIndex == 3
    check lt.tokens[0].scopes == @["source.test", "rule.name", "whole.match"]

  test "zero-width match does not loop forever on multi-byte input":
    let jsonStr = """
    {
      "scopeName": "source.test",
      "patterns": [ { "match": "\\b", "name": "boundary" } ]
    }
    """
    let g = compileGrammar(parseRawGrammar(jsonStr))
    # Should terminate; we only assert that the call returns and tokens
    # cover the input length monotonically.
    let lt = tokenizeLine("あfoo", initialStack(g))
    var prev = 0
    for tok in lt.tokens:
      check tok.startIndex >= prev
      check tok.endIndex >= tok.startIndex
      prev = tok.endIndex
    check prev <= "あfoo".len

  test "zero-width matches never produce empty tokens":
    # A lookahead-only rule produces a zero-width match. Token emission
    # must drop it entirely — `startIndex == endIndex` tokens force every
    # consumer to filter the same way. Only the gap that follows survives.
    let jsonStr = """
    {
      "scopeName": "source.test",
      "patterns": [ { "match": "(?=x)", "name": "meta.zw" } ]
    }
    """
    let g = compileGrammar(parseRawGrammar(jsonStr))
    let lt = tokenizeLine("xyz", initialStack(g))

    for tok in lt.tokens:
      check tok.endIndex > tok.startIndex
    check lt.tokens.len == 1
    check lt.tokens[0].startIndex == 1
    check lt.tokens[0].endIndex == 3
    check lt.tokens[0].scopes == @["source.test"]
