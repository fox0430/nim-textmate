import std/unittest

import textmate

suite "firstLineMatch":
  test "grammar with matching firstLineMatch returns true":
    let jsonStr = """
    {
      "scopeName": "source.python",
      "firstLineMatch": "^#!.*python",
      "patterns": []
    }
    """
    let g = compileGrammar(parseRawGrammar(jsonStr))
    check matchesFirstLine(g, "#!/usr/bin/env python3")

  test "non-matching first line returns false":
    let jsonStr = """
    {
      "scopeName": "source.python",
      "firstLineMatch": "^#!.*python",
      "patterns": []
    }
    """
    let g = compileGrammar(parseRawGrammar(jsonStr))
    check not matchesFirstLine(g, "print('hi')")

  test "grammar without firstLineMatch returns false (no error)":
    let jsonStr = """
    {
      "scopeName": "source.plain",
      "patterns": []
    }
    """
    let g = compileGrammar(parseRawGrammar(jsonStr))
    check not matchesFirstLine(g, "anything")

  test "detectGrammar picks the grammar whose firstLineMatch hits":
    let jsonA = """
    {
      "scopeName": "source.python",
      "firstLineMatch": "^#!.*python",
      "patterns": []
    }
    """
    let jsonB = """
    {
      "scopeName": "source.ruby",
      "firstLineMatch": "^#!.*ruby",
      "patterns": []
    }
    """
    let reg = newRegistry()
    discard reg.addGrammar(parseRawGrammar(jsonA))
    discard reg.addGrammar(parseRawGrammar(jsonB))

    let picked = reg.detectGrammar("#!/usr/bin/env ruby")
    check picked != nil
    check picked.scopeName == "source.ruby"

    let none = reg.detectGrammar("plain text")
    check none.isNil

  test "invalid firstLineMatch regex surfaces as GrammarError":
    # Unbalanced group — compileRegex should raise.
    let jsonStr = """
    {
      "scopeName": "source.bad",
      "firstLineMatch": "(",
      "patterns": []
    }
    """
    expect GrammarError:
      discard compileGrammar(parseRawGrammar(jsonStr))

  test "detectGrammar returns the first-registered grammar when multiple firstLineMatch hit":
    # Both firstLineMatch patterns match the same input line. Because
    # the registry preserves registration order (OrderedTable), the
    # earliest-added grammar must win.
    let jsonFirst = """
    {
      "scopeName": "source.first",
      "firstLineMatch": "^hello",
      "patterns": []
    }
    """
    let jsonSecond = """
    {
      "scopeName": "source.second",
      "firstLineMatch": "^hello",
      "patterns": []
    }
    """
    let reg = newRegistry()
    discard reg.addGrammar(parseRawGrammar(jsonFirst))
    discard reg.addGrammar(parseRawGrammar(jsonSecond))
    let picked = reg.detectGrammar("hello world")
    check picked != nil
    check picked.scopeName == "source.first"
