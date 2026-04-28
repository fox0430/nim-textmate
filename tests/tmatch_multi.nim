import std/unittest

import textmate

suite "match multi":
  test "leftmost match wins when multiple patterns compete":
    let jsonStr = """
    {
      "scopeName": "source.test",
      "patterns": [
        { "match": "cat", "name": "animal.cat" },
        { "match": "dog", "name": "animal.dog" }
      ]
    }
    """
    let g = compileGrammar(parseRawGrammar(jsonStr))
    # "a dog and a cat" - "dog" appears earlier, so "dog" wins at pos 0
    let lt = tokenizeLine("a dog and a cat", initialStack(g))

    check lt.tokens.len == 4

    check lt.tokens[0].startIndex == 0
    check lt.tokens[0].endIndex == 2
    check lt.tokens[0].scopes == @["source.test"]

    check lt.tokens[1].startIndex == 2
    check lt.tokens[1].endIndex == 5
    check lt.tokens[1].scopes == @["source.test", "animal.dog"]

    check lt.tokens[2].startIndex == 5
    check lt.tokens[2].endIndex == 12
    check lt.tokens[2].scopes == @["source.test"]

    check lt.tokens[3].startIndex == 12
    check lt.tokens[3].endIndex == 15
    check lt.tokens[3].scopes == @["source.test", "animal.cat"]

  test "when ordering in the pattern list does not match document order, document order still wins":
    let jsonStr = """
    {
      "scopeName": "source.test",
      "patterns": [
        { "match": "dog", "name": "animal.dog" },
        { "match": "cat", "name": "animal.cat" }
      ]
    }
    """
    let g = compileGrammar(parseRawGrammar(jsonStr))
    let lt = tokenizeLine("cat dog", initialStack(g))

    check lt.tokens.len == 3
    check lt.tokens[0].scopes == @["source.test", "animal.cat"]
    check lt.tokens[1].scopes == @["source.test"]
    check lt.tokens[2].scopes == @["source.test", "animal.dog"]
