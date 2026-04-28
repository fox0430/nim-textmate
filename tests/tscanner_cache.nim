import std/unittest

import textmate

suite "Phase 6 scanner cache":
  test "same begin/end rule fires multiple times per line":
    # Scanner must let the same rule match at distinct positions on the
    # same line. If the first match were cached as the only result, the
    # second and third strings would disappear.
    let jsonStr = """
    {
      "scopeName": "source.test",
      "patterns": [ {
        "begin": "\"", "end": "\"",
        "name": "string.quoted",
        "contentName": "meta.string.body"
      } ]
    }
    """
    let g = compileGrammar(parseRawGrammar(jsonStr))
    let lt = tokenizeLine("\"a\" \"b\" \"c\"", initialStack(g))

    # Expected layout: begin "a" end <gap> begin "b" end <gap> begin "c" end.
    check lt.tokens.len == 11
    check lt.tokens[0].scopes == @["source.test", "string.quoted"]
    check lt.tokens[0].startIndex == 0
    check lt.tokens[0].endIndex == 1
    check lt.tokens[1].scopes == @["source.test", "string.quoted", "meta.string.body"]
    check lt.tokens[2].scopes == @["source.test", "string.quoted"]
    check lt.tokens[3].scopes == @["source.test"]
    check lt.tokens[4].scopes == @["source.test", "string.quoted"]
    check lt.tokens[5].scopes == @["source.test", "string.quoted", "meta.string.body"]
    check lt.tokens[6].scopes == @["source.test", "string.quoted"]
    check lt.tokens[7].scopes == @["source.test"]
    check lt.tokens[8].scopes == @["source.test", "string.quoted"]
    check lt.tokens[9].scopes == @["source.test", "string.quoted", "meta.string.body"]
    check lt.tokens[10].scopes == @["source.test", "string.quoted"]

  test "multiple match rules, first rule hits far to the right, second rule hits in the middle":
    # Reproduces the typical `bar` far-right / `foo` middle case. After
    # the first iteration, the scanner caches bar's far-right position.
    # The second iteration should reuse that cache while correctly
    # re-searching for foo.
    let jsonStr = """
    {
      "scopeName": "source.test",
      "patterns": [
        { "match": "\\bfoo\\b", "name": "kw.foo" },
        { "match": "\\bbar\\b", "name": "kw.bar" }
      ]
    }
    """
    let g = compileGrammar(parseRawGrammar(jsonStr))
    let lt = tokenizeLine("x foo y bar z foo w", initialStack(g))

    # x  foo  y  bar  z  foo  w
    check lt.tokens.len == 7
    check lt.tokens[0].scopes == @["source.test"]
    check lt.tokens[1].scopes == @["source.test", "kw.foo"]
    check lt.tokens[2].scopes == @["source.test"]
    check lt.tokens[3].scopes == @["source.test", "kw.bar"]
    check lt.tokens[4].scopes == @["source.test"]
    check lt.tokens[5].scopes == @["source.test", "kw.foo"]
    check lt.tokens[6].scopes == @["source.test"]

  test "same rule id across grammars does not collide in the scanner":
    # RuleId is per-grammar, so two rules from different grammars can
    # share the same numeric id. The scanner must key on `Rule` identity,
    # not on the numeric id.
    let innerJson = """
    {
      "scopeName": "source.inner",
      "patterns": [
        { "include": "#back" },
        { "match": "\\bfoo\\b", "name": "kw.foo" }
      ],
      "repository": {
        "back": { "include": "$base" }
      }
    }
    """
    let outerJson = """
    {
      "scopeName": "source.outer",
      "patterns": [
        { "include": "source.inner" },
        { "match": "\\bbar\\b", "name": "kw.bar" }
      ]
    }
    """
    let reg = newRegistry()
    discard reg.addGrammar(parseRawGrammar(innerJson))
    let outer = reg.addGrammar(parseRawGrammar(outerJson))
    let lt = tokenizeLine("foo bar", initialStack(outer))

    check lt.tokens.len == 3
    check lt.tokens[0].scopes == @["source.outer", "kw.foo"]
    check lt.tokens[1].scopes == @["source.outer"]
    check lt.tokens[2].scopes == @["source.outer", "kw.bar"]

  test "backreference terminator cache is reused for repeated delimiters":
    # The same heredoc delimiter appearing twice on one line used to
    # compile the terminator regex twice. With the resolvedTerminatorCache
    # it should compile once and reuse it — but behaviour must be
    # indistinguishable from the uncached path.
    let jsonStr = """
    {
      "scopeName": "source.test",
      "patterns": [ {
        "begin": "<<(\\w+)", "end": "\\1",
        "name": "heredoc"
      } ]
    }
    """
    let g = compileGrammar(parseRawGrammar(jsonStr))
    let lt = tokenizeLine("<<EOF a EOF <<EOF b EOF", initialStack(g))

    # Both heredocs should close cleanly (same delimiter both times),
    # leaving the stack back at the root grammar.
    check lt.ruleStack.contentName == "source.test"

  test "backreference terminator cache does not conflate distinct delimiters":
    # Two heredocs on the same line, with different delimiters. Each
    # cache entry must key on the resolved pattern so the second heredoc
    # does not close against the first heredoc's delimiter.
    let jsonStr = """
    {
      "scopeName": "source.test",
      "patterns": [ {
        "begin": "<<(\\w+)", "end": "\\1",
        "name": "heredoc"
      } ]
    }
    """
    let g = compileGrammar(parseRawGrammar(jsonStr))
    let lt = tokenizeLine("<<EOF a EOF <<END b END", initialStack(g))

    check lt.ruleStack.contentName == "source.test"

  test "multiple lines share rule state without scanner leakage":
    # A new LineScanner is created per tokenizeLine call. State from one
    # line should not leak into the next: even if rule X matched at pos
    # 5 on line 1, on line 2 it should be searched fresh.
    let jsonStr = """
    {
      "scopeName": "source.test",
      "patterns": [ { "match": "\\bfoo\\b", "name": "kw.foo" } ]
    }
    """
    let g = compileGrammar(parseRawGrammar(jsonStr))
    let line1 = tokenizeLine("aaa foo", initialStack(g))
    let line2 = tokenizeLine("foo bbb", line1.ruleStack)

    check line1.tokens.len == 2
    check line1.tokens[1].scopes == @["source.test", "kw.foo"]
    check line2.tokens.len == 2
    check line2.tokens[0].scopes == @["source.test", "kw.foo"]
