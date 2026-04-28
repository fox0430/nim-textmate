import std/unittest

import textmate

suite "registry":
  test "addGrammar registers a grammar under its scopeName":
    let jsonStr = """
    {
      "scopeName": "source.test",
      "patterns": [ { "match": "foo", "name": "x" } ]
    }
    """
    let reg = newRegistry()
    let g = reg.addGrammar(parseRawGrammar(jsonStr))

    check g.scopeName == "source.test"
    check reg.grammarForScope("source.test") == g

  test "grammarForScope raises GrammarError for unknown scope":
    let reg = newRegistry()

    expect GrammarError:
      discard reg.grammarForScope("source.missing")

  test "addGrammar overwrites a previous registration with the same scopeName":
    let firstJson = """
    { "scopeName": "source.test", "patterns": [ { "match": "a", "name": "x" } ] }
    """
    let secondJson = """
    { "scopeName": "source.test", "patterns": [ { "match": "b", "name": "y" } ] }
    """
    let reg = newRegistry()
    discard reg.addGrammar(parseRawGrammar(firstJson))
    let g2 = reg.addGrammar(parseRawGrammar(secondJson))

    check reg.grammarForScope("source.test") == g2
