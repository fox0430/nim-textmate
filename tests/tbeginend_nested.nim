import std/unittest

import textmate

suite "begin/end nested patterns":
  test "nested match rule fires inside a begin/end block with contentName scope":
    let jsonStr = """
    {
      "scopeName": "source.test",
      "patterns": [ {
        "begin": "\"", "end": "\"",
        "name": "string.quoted",
        "contentName": "meta.string.body",
        "patterns": [
          { "match": "\\\\.", "name": "constant.character.escape" }
        ]
      } ]
    }
    """
    let g = compileGrammar(parseRawGrammar(jsonStr))
    let lt = tokenizeLine("\"a\\nb\"", initialStack(g))

    # "  a  \n  b  "
    # 0  1  23  4  5
    check lt.tokens.len == 5
    check lt.tokens[0].startIndex == 0
    check lt.tokens[0].endIndex == 1
    check lt.tokens[0].scopes == @["source.test", "string.quoted"]
    check lt.tokens[1].startIndex == 1
    check lt.tokens[1].endIndex == 2
    check lt.tokens[1].scopes == @["source.test", "string.quoted", "meta.string.body"]
    check lt.tokens[2].startIndex == 2
    check lt.tokens[2].endIndex == 4
    check lt.tokens[2].scopes ==
      @["source.test", "string.quoted", "meta.string.body", "constant.character.escape"]
    check lt.tokens[3].startIndex == 4
    check lt.tokens[3].endIndex == 5
    check lt.tokens[3].scopes == @["source.test", "string.quoted", "meta.string.body"]
    check lt.tokens[4].startIndex == 5
    check lt.tokens[4].endIndex == 6
    check lt.tokens[4].scopes == @["source.test", "string.quoted"]

  test "nested begin/end inside a begin/end pushes another stack level":
    let jsonStr = """
    {
      "scopeName": "source.test",
      "patterns": [ {
        "begin": "\\(", "end": "\\)",
        "name": "outer",
        "patterns": [ {
          "begin": "\\[", "end": "\\]",
          "name": "inner"
        } ]
      } ]
    }
    """
    let g = compileGrammar(parseRawGrammar(jsonStr))
    let lt = tokenizeLine("(a[b]c)", initialStack(g))

    # (  a  [  b  ]  c  )
    # 0  1  2  3  4  5  6
    check lt.tokens.len == 7
    check lt.tokens[0].scopes == @["source.test", "outer"]
    check lt.tokens[1].scopes == @["source.test", "outer"]
    check lt.tokens[2].scopes == @["source.test", "outer", "inner"]
    check lt.tokens[3].scopes == @["source.test", "outer", "inner"]
    check lt.tokens[4].scopes == @["source.test", "outer", "inner"]
    check lt.tokens[5].scopes == @["source.test", "outer"]
    check lt.tokens[6].scopes == @["source.test", "outer"]

  test "nested patterns do not fire outside the begin/end block":
    let jsonStr = """
    {
      "scopeName": "source.test",
      "patterns": [ {
        "begin": "\"", "end": "\"",
        "name": "string.quoted",
        "patterns": [
          { "match": "\\d+", "name": "constant.numeric" }
        ]
      } ]
    }
    """
    let g = compileGrammar(parseRawGrammar(jsonStr))
    let lt = tokenizeLine("42 \"99\"", initialStack(g))

    # "42 " stays at source.test (numeric pattern is local to the block),
    # "99" inside gets numeric scope.
    check lt.tokens[0].startIndex == 0
    check lt.tokens[0].endIndex == 3
    check lt.tokens[0].scopes == @["source.test"]
    # Find the token covering "99".
    var sawInnerNumeric = false
    for tok in lt.tokens:
      if tok.startIndex == 4 and tok.endIndex == 6:
        check tok.scopes == @["source.test", "string.quoted", "constant.numeric"]
        sawInnerNumeric = true
    check sawInnerNumeric

  test "end wins ties when the end and a nested match start at the same position":
    # Pinned: at position 3, both `"` (end) and `"` (nested match with a
    # different scope name) can fire. The end pattern wins; the nested
    # match rule never gets a chance to decorate the closing quote.
    #
    # Phase 5 `applyEndPatternLast` will let this tie flip — this test
    # forces a touchpoint when that lands.
    let jsonStr = """
    {
      "scopeName": "source.test",
      "patterns": [ {
        "begin": "\"", "end": "\"",
        "name": "string.quoted",
        "patterns": [
          { "match": "\"", "name": "nested.quote" }
        ]
      } ]
    }
    """
    let g = compileGrammar(parseRawGrammar(jsonStr))
    let lt = tokenizeLine("\"x\"", initialStack(g))

    check lt.tokens.len == 3
    check lt.tokens[0].scopes == @["source.test", "string.quoted"]
    check lt.tokens[1].scopes == @["source.test", "string.quoted"]
    check lt.tokens[2].scopes == @["source.test", "string.quoted"]

  test "$self inside nested patterns resolves to the pushing grammar":
    # The nested block's `$self` must pull in the rule list of the
    # grammar that owns the pushed begin/end rule (here, the only
    # grammar) — not some outer scope. Verify by nesting the same
    # begin/end recursively.
    let jsonStr = """
    {
      "scopeName": "source.test",
      "patterns": [ {
        "begin": "\\(", "end": "\\)",
        "name": "group",
        "patterns": [
          { "include": "$self" }
        ]
      } ]
    }
    """
    let g = compileGrammar(parseRawGrammar(jsonStr))
    let lt = tokenizeLine("(a(b)c)", initialStack(g))

    # (  a  (  b  )  c  )
    # 0  1  2  3  4  5  6
    check lt.tokens[0].scopes == @["source.test", "group"]
    check lt.tokens[2].scopes == @["source.test", "group", "group"]
    check lt.tokens[3].scopes == @["source.test", "group", "group"]
    check lt.tokens[4].scopes == @["source.test", "group", "group"]
    check lt.tokens[6].scopes == @["source.test", "group"]

  test "nested begin/end that crosses a line boundary persists via ruleStack":
    let jsonStr = """
    {
      "scopeName": "source.test",
      "patterns": [ {
        "begin": "\\(", "end": "\\)",
        "name": "outer",
        "patterns": [ {
          "begin": "\\[", "end": "\\]",
          "name": "inner"
        } ]
      } ]
    }
    """
    let g = compileGrammar(parseRawGrammar(jsonStr))
    let line1 = tokenizeLine("(a[b", initialStack(g))
    let line2 = tokenizeLine("c]d)", line1.ruleStack)

    # Line1 ends inside the inner block.
    check line1.tokens[^1].scopes == @["source.test", "outer", "inner"]
    # Line2 closes inner, then outer.
    check line2.tokens[0].scopes == @["source.test", "outer", "inner"]
    check line2.tokens[^1].scopes == @["source.test", "outer"]

  test "empty patterns array in a begin/end rule behaves like no patterns":
    let jsonStr = """
    {
      "scopeName": "source.test",
      "patterns": [ {
        "begin": "\"", "end": "\"",
        "name": "string.quoted",
        "contentName": "meta.string.body",
        "patterns": []
      } ]
    }
    """
    let g = compileGrammar(parseRawGrammar(jsonStr))
    let lt = tokenizeLine("\"hi\"", initialStack(g))

    check lt.tokens.len == 3
    check lt.tokens[0].scopes == @["source.test", "string.quoted"]
    check lt.tokens[1].scopes == @["source.test", "string.quoted", "meta.string.body"]
    check lt.tokens[2].scopes == @["source.test", "string.quoted"]

  test "depth-4 nested begin/end preserves intermediate scopes at every level":
    let jsonStr = """
    {
      "scopeName": "source.test",
      "patterns": [ {
        "begin": "\\(", "end": "\\)",
        "name": "l1",
        "patterns": [ {
          "begin": "\\[", "end": "\\]",
          "name": "l2",
          "patterns": [ {
            "begin": "\\{", "end": "\\}",
            "name": "l3",
            "patterns": [ {
              "begin": "<", "end": ">",
              "name": "l4"
            } ]
          } ]
        } ]
      } ]
    }
    """
    let g = compileGrammar(parseRawGrammar(jsonStr))
    let lt = tokenizeLine("([{<x>}])", initialStack(g))

    # (  [  {  <  x  >  }  ]  )
    # 0  1  2  3  4  5  6  7  8
    check lt.tokens.len == 9
    check lt.tokens[0].scopes == @["source.test", "l1"]
    check lt.tokens[1].scopes == @["source.test", "l1", "l2"]
    check lt.tokens[2].scopes == @["source.test", "l1", "l2", "l3"]
    check lt.tokens[3].scopes == @["source.test", "l1", "l2", "l3", "l4"]
    check lt.tokens[4].scopes == @["source.test", "l1", "l2", "l3", "l4"]
    check lt.tokens[5].scopes == @["source.test", "l1", "l2", "l3", "l4"]
    check lt.tokens[6].scopes == @["source.test", "l1", "l2", "l3"]
    check lt.tokens[7].scopes == @["source.test", "l1", "l2"]
    check lt.tokens[8].scopes == @["source.test", "l1"]

  test "empty line inside depth-3 nested begin/end preserves carried scope stack":
    let jsonStr = """
    {
      "scopeName": "source.test",
      "patterns": [ {
        "begin": "\\(", "end": "\\)",
        "name": "l1",
        "patterns": [ {
          "begin": "\\[", "end": "\\]",
          "name": "l2",
          "patterns": [ {
            "begin": "\\{", "end": "\\}",
            "name": "l3"
          } ]
        } ]
      } ]
    }
    """
    let g = compileGrammar(parseRawGrammar(jsonStr))
    # Open three levels, hit an empty line in the middle, then close them all.
    let l1 = tokenizeLine("([{", initialStack(g))
    let l2 = tokenizeLine("", l1.ruleStack)
    let l3 = tokenizeLine("}])", l2.ruleStack)

    # Empty line emits no tokens but must preserve the stack.
    check l2.tokens.len == 0
    check fullScopes(l2.ruleStack) == @["source.test", "l1", "l2", "l3"]
    # Closing line peels the stack frame-by-frame.
    check l3.tokens[0].scopes == @["source.test", "l1", "l2", "l3"]
    check l3.tokens[1].scopes == @["source.test", "l1", "l2"]
    check l3.tokens[2].scopes == @["source.test", "l1"]
