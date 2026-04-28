import std/unittest

import textmate

suite "capture patterns":
  test "capture patterns add scopes on top of the capture's own scope":
    let jsonStr = """
    {
      "scopeName": "source.test",
      "patterns": [ {
        "match": "(\\w+)",
        "name": "meta.word",
        "captures": {
          "1": {
            "name": "string.quoted",
            "patterns": [ { "match": "\\d+", "name": "constant.numeric" } ]
          }
        }
      } ]
    }
    """
    let g = compileGrammar(parseRawGrammar(jsonStr))
    let lt = tokenizeLine("abc42", initialStack(g))

    # The capture covers [0,5). Inside it, `\d+` matches "42" at [3,5).
    # Letters ahead of the digits carry the capture's own scope only.
    check lt.tokens.len == 2
    check lt.tokens[0].startIndex == 0
    check lt.tokens[0].endIndex == 3
    check lt.tokens[0].scopes == @["source.test", "meta.word", "string.quoted"]
    check lt.tokens[1].startIndex == 3
    check lt.tokens[1].endIndex == 5
    check lt.tokens[1].scopes ==
      @["source.test", "meta.word", "string.quoted", "constant.numeric"]

  test "capture patterns can reference a repository include":
    let jsonStr = """
    {
      "scopeName": "source.test",
      "patterns": [ {
        "match": "(\\w+)",
        "name": "meta.word",
        "captures": {
          "1": {
            "name": "outer",
            "patterns": [ { "include": "#num" } ]
          }
        }
      } ],
      "repository": {
        "num": { "match": "\\d+", "name": "constant.numeric" }
      }
    }
    """
    let g = compileGrammar(parseRawGrammar(jsonStr))
    let lt = tokenizeLine("abc42", initialStack(g))

    check lt.tokens.len == 2
    check lt.tokens[0].scopes == @["source.test", "meta.word", "outer"]
    check lt.tokens[1].scopes ==
      @["source.test", "meta.word", "outer", "constant.numeric"]

  test "captures sharing the same span layer by group index (smaller = outer)":
    # Group 0 spans the whole match; group 1 also spans the whole match.
    # The sort in `emitSpanWithCaptures` tie-breaks identical spans by
    # ascending group index, so group 0 sits outside group 1.
    let jsonStr = """
    {
      "scopeName": "source.test",
      "patterns": [ {
        "match": "(foo)",
        "name": "meta.x",
        "captures": {
          "0": { "name": "outer.zero" },
          "1": { "name": "inner.one" }
        }
      } ]
    }
    """
    let g = compileGrammar(parseRawGrammar(jsonStr))
    let lt = tokenizeLine("foo", initialStack(g))

    check lt.tokens.len == 1
    check lt.tokens[0].startIndex == 0
    check lt.tokens[0].endIndex == 3
    check lt.tokens[0].scopes == @["source.test", "meta.x", "outer.zero", "inner.one"]

  test "capture group 0 with patterns recursively tokenises the whole match":
    let jsonStr = """
    {
      "scopeName": "source.test",
      "patterns": [ {
        "match": "\\w+\\d+",
        "name": "meta.whole",
        "captures": {
          "0": {
            "name": "outer",
            "patterns": [ { "match": "\\d+", "name": "constant.numeric" } ]
          }
        }
      } ]
    }
    """
    let g = compileGrammar(parseRawGrammar(jsonStr))
    let lt = tokenizeLine("abc42", initialStack(g))

    check lt.tokens.len == 2
    check lt.tokens[0].startIndex == 0
    check lt.tokens[0].endIndex == 3
    check lt.tokens[0].scopes == @["source.test", "meta.whole", "outer"]
    check lt.tokens[1].startIndex == 3
    check lt.tokens[1].endIndex == 5
    check lt.tokens[1].scopes ==
      @["source.test", "meta.whole", "outer", "constant.numeric"]

  test "capture patterns that match nothing leave a single capture-scoped token":
    let jsonStr = """
    {
      "scopeName": "source.test",
      "patterns": [ {
        "match": "(\\w+)",
        "name": "meta.word",
        "captures": {
          "1": {
            "name": "outer",
            "patterns": [ { "match": "\\d+", "name": "constant.numeric" } ]
          }
        }
      } ]
    }
    """
    let g = compileGrammar(parseRawGrammar(jsonStr))
    let lt = tokenizeLine("abcdef", initialStack(g))

    check lt.tokens.len == 1
    check lt.tokens[0].startIndex == 0
    check lt.tokens[0].endIndex == 6
    check lt.tokens[0].scopes == @["source.test", "meta.word", "outer"]

  test "rkBeginEnd inside capture patterns is skipped (deferred to Phase 5)":
    # Phase 4 does not fire begin/end rules inside a capture's span —
    # capture patterns are match-only. A begin/end that would otherwise
    # fire here is silently ignored, leaving the plain capture token.
    let jsonStr = """
    {
      "scopeName": "source.test",
      "patterns": [ {
        "match": "(\\w+)",
        "name": "meta.word",
        "captures": {
          "1": {
            "name": "outer",
            "patterns": [
              { "begin": "a", "end": "c", "name": "inner.block" }
            ]
          }
        }
      } ]
    }
    """
    let g = compileGrammar(parseRawGrammar(jsonStr))
    let lt = tokenizeLine("abcdef", initialStack(g))

    check lt.tokens.len == 1
    check lt.tokens[0].scopes == @["source.test", "meta.word", "outer"]

  test "a capture without patterns is unchanged from Phase 1 behaviour":
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
    check lt.tokens[0].scopes == @["source.test", "meta.assignment", "variable"]
    check lt.tokens[1].scopes == @["source.test", "meta.assignment"]
    check lt.tokens[2].scopes == @["source.test", "meta.assignment", "number"]

  test "$self include inside capture patterns terminates when the outer rule could re-match":
    # The outer rule `(\w+)` matches its own capture span, so a naive
    # `$self` expansion would re-enter `emitSpanWithCaptures` with the
    # same rule and loop forever. The `visitedRules` guard filters the
    # enclosing rule out of `tokenizeRange`'s candidate set; the sibling
    # `\d+` rule still fires, tokenising the digit run inside the capture.
    let jsonStr = """
    {
      "scopeName": "source.test",
      "patterns": [
        { "match": "\\d+", "name": "constant.numeric" },
        {
          "match": "(\\w+)",
          "name": "meta.word",
          "captures": {
            "1": {
              "name": "outer",
              "patterns": [ { "include": "$self" } ]
            }
          }
        }
      ]
    }
    """
    let g = compileGrammar(parseRawGrammar(jsonStr))
    let lt = tokenizeLine("abc42", initialStack(g))

    check lt.tokens.len == 2
    check lt.tokens[0].startIndex == 0
    check lt.tokens[0].endIndex == 3
    check lt.tokens[0].scopes == @["source.test", "meta.word", "outer"]
    check lt.tokens[1].startIndex == 3
    check lt.tokens[1].endIndex == 5
    check lt.tokens[1].scopes ==
      @["source.test", "meta.word", "outer", "constant.numeric"]

  test "$self include inside capture patterns reuses root rules":
    # The capture's `patterns` list includes `$self`, which expands back
    # into the grammar's root rules. A sibling `bar` match must surface
    # inside the captured span.
    let jsonStr = """
    {
      "scopeName": "source.test",
      "patterns": [
        { "match": "bar", "name": "keyword.bar" },
        {
          "match": "foo(bar)",
          "name": "meta.word",
          "captures": {
            "1": {
              "name": "outer",
              "patterns": [ { "include": "$self" } ]
            }
          }
        }
      ]
    }
    """
    let g = compileGrammar(parseRawGrammar(jsonStr))
    let lt = tokenizeLine("foobar", initialStack(g))

    check lt.tokens.len == 2
    check lt.tokens[0].startIndex == 0
    check lt.tokens[0].endIndex == 3
    check lt.tokens[0].scopes == @["source.test", "meta.word"]
    check lt.tokens[1].startIndex == 3
    check lt.tokens[1].endIndex == 6
    check lt.tokens[1].scopes == @["source.test", "meta.word", "outer", "keyword.bar"]

  test "cross-grammar include inside capture patterns pulls in another grammar's rules":
    # Capture's `patterns` list includes `source.inner`. The inner
    # grammar's rootRules must be reachable from inside the captured
    # span, layered under the outer capture's scope.
    let innerJson = """
    {
      "scopeName": "source.inner",
      "patterns": [ { "match": "\\d+", "name": "constant.numeric" } ]
    }
    """
    let outerJson = """
    {
      "scopeName": "source.outer",
      "patterns": [ {
        "match": "(\\w+)",
        "name": "meta.word",
        "captures": {
          "1": {
            "name": "outer.cap",
            "patterns": [ { "include": "source.inner" } ]
          }
        }
      } ]
    }
    """
    let reg = newRegistry()
    discard reg.addGrammar(parseRawGrammar(innerJson))
    let outer = reg.addGrammar(parseRawGrammar(outerJson))
    let lt = tokenizeLine("abc42", initialStack(outer))

    check lt.tokens.len == 2
    check lt.tokens[0].scopes == @["source.outer", "meta.word", "outer.cap"]
    check lt.tokens[1].scopes ==
      @["source.outer", "meta.word", "outer.cap", "constant.numeric"]

  test "tokenizeRange continues past boundary-crossing matches to find later valid matches":
    # Inside a capture's bounded span, the leftmost sub-pattern match can
    # extend past the capture's `endPos`. The fix skips the out-of-range
    # match and continues searching so later in-range matches still fire.
    # Capture 1 span = [0,3); the first sub-pattern reaches [0,5) and is
    # rejected, the second sub-pattern's [1,2) match must still surface.
    let jsonStr = """
    {
      "scopeName": "source.test",
      "patterns": [ {
        "match": "(abc)42xyz",
        "name": "meta.outer",
        "captures": {
          "1": {
            "name": "cap",
            "patterns": [
              { "match": "abc\\d+", "name": "bad.crosses" },
              { "match": "b", "name": "good.inside" }
            ]
          }
        }
      } ]
    }
    """
    let g = compileGrammar(parseRawGrammar(jsonStr))
    let lt = tokenizeLine("abc42xyz", initialStack(g))

    check lt.tokens.len == 4
    check lt.tokens[0].startIndex == 0
    check lt.tokens[0].endIndex == 1
    check lt.tokens[0].scopes == @["source.test", "meta.outer", "cap"]
    check lt.tokens[1].startIndex == 1
    check lt.tokens[1].endIndex == 2
    check lt.tokens[1].scopes == @["source.test", "meta.outer", "cap", "good.inside"]
    check lt.tokens[2].startIndex == 2
    check lt.tokens[2].endIndex == 3
    check lt.tokens[2].scopes == @["source.test", "meta.outer", "cap"]
    check lt.tokens[3].startIndex == 3
    check lt.tokens[3].endIndex == 8
    check lt.tokens[3].scopes == @["source.test", "meta.outer"]

  test "cross-grammar repo include (source.xxx#name) inside capture patterns":
    # `source.inner#num` targets a single repository entry. Siblings in
    # the inner grammar's repository must not leak into the captured
    # span.
    let innerJson = """
    {
      "scopeName": "source.inner",
      "patterns": [],
      "repository": {
        "num": { "match": "\\d+", "name": "constant.numeric" },
        "letters": { "match": "[a-z]+", "name": "keyword.letters" }
      }
    }
    """
    let outerJson = """
    {
      "scopeName": "source.outer",
      "patterns": [ {
        "match": "(\\w+)",
        "name": "meta.word",
        "captures": {
          "1": {
            "name": "outer.cap",
            "patterns": [ { "include": "source.inner#num" } ]
          }
        }
      } ]
    }
    """
    let reg = newRegistry()
    discard reg.addGrammar(parseRawGrammar(innerJson))
    let outer = reg.addGrammar(parseRawGrammar(outerJson))
    let lt = tokenizeLine("abc42", initialStack(outer))

    # Digits get the numeric scope; letters stay at plain capture scope
    # because the `letters` repo entry was not pulled in.
    check lt.tokens.len == 2
    check lt.tokens[0].scopes == @["source.outer", "meta.word", "outer.cap"]
    check lt.tokens[1].scopes ==
      @["source.outer", "meta.word", "outer.cap", "constant.numeric"]
