import std/unittest

import textmate

suite "match tiebreak":
  test "when two patterns match at the same position, the first defined wins":
    let jsonStr = """
    {
      "scopeName": "source.test",
      "patterns": [
        { "match": "foo", "name": "first.foo" },
        { "match": "foo", "name": "second.foo" }
      ]
    }
    """
    let g = compileGrammar(parseRawGrammar(jsonStr))
    let lt = tokenizeLine("foo", initialStack(g))

    check lt.tokens.len == 1
    check lt.tokens[0].startIndex == 0
    check lt.tokens[0].endIndex == 3
    check lt.tokens[0].scopes == @["source.test", "first.foo"]

  test "longer-prefix pattern does not preempt earlier-defined shorter one at the same position":
    # Both 'foo' and 'foobar' match at pos 0; the first-listed rule wins
    # regardless of match length.
    let jsonStr = """
    {
      "scopeName": "source.test",
      "patterns": [
        { "match": "foo", "name": "short.foo" },
        { "match": "foobar", "name": "long.foobar" }
      ]
    }
    """
    let g = compileGrammar(parseRawGrammar(jsonStr))
    let lt = tokenizeLine("foobar", initialStack(g))

    check lt.tokens.len == 2
    check lt.tokens[0].startIndex == 0
    check lt.tokens[0].endIndex == 3
    check lt.tokens[0].scopes == @["source.test", "short.foo"]
    check lt.tokens[1].startIndex == 3
    check lt.tokens[1].endIndex == 6
    check lt.tokens[1].scopes == @["source.test"]
