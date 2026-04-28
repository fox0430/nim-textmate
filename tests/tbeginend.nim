import std/unittest

import textmate

suite "begin/end basic":
  test "begin/end emits begin, content, end tokens with contentName between":
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
    let lt = tokenizeLine("\"hi\"", initialStack(g))

    check lt.tokens.len == 3

    check lt.tokens[0].startIndex == 0
    check lt.tokens[0].endIndex == 1
    check lt.tokens[0].scopes == @["source.test", "string.quoted"]

    check lt.tokens[1].startIndex == 1
    check lt.tokens[1].endIndex == 3
    check lt.tokens[1].scopes == @["source.test", "string.quoted", "meta.string.body"]

    check lt.tokens[2].startIndex == 3
    check lt.tokens[2].endIndex == 4
    check lt.tokens[2].scopes == @["source.test", "string.quoted"]

  test "leading and trailing gaps outside the begin/end get the base scope":
    let jsonStr = """
    {
      "scopeName": "source.test",
      "patterns": [ {
        "begin": "\"", "end": "\"",
        "name": "string.quoted"
      } ]
    }
    """
    let g = compileGrammar(parseRawGrammar(jsonStr))
    let lt = tokenizeLine("x \"hi\" y", initialStack(g))

    check lt.tokens.len == 5
    check lt.tokens[0].scopes == @["source.test"]
    check lt.tokens[0].startIndex == 0
    check lt.tokens[0].endIndex == 2
    check lt.tokens[1].scopes == @["source.test", "string.quoted"]
    check lt.tokens[1].startIndex == 2
    check lt.tokens[1].endIndex == 3
    check lt.tokens[2].scopes == @["source.test", "string.quoted"]
    check lt.tokens[2].startIndex == 3
    check lt.tokens[2].endIndex == 5
    check lt.tokens[3].scopes == @["source.test", "string.quoted"]
    check lt.tokens[3].startIndex == 5
    check lt.tokens[3].endIndex == 6
    check lt.tokens[4].scopes == @["source.test"]
    check lt.tokens[4].startIndex == 6
    check lt.tokens[4].endIndex == 8

  test "begin/end without contentName omits the inner scope layer":
    let jsonStr = """
    {
      "scopeName": "source.test",
      "patterns": [ {
        "begin": "\"", "end": "\"",
        "name": "string.quoted"
      } ]
    }
    """
    let g = compileGrammar(parseRawGrammar(jsonStr))
    let lt = tokenizeLine("\"hi\"", initialStack(g))

    check lt.tokens.len == 3
    for tok in lt.tokens:
      check tok.scopes == @["source.test", "string.quoted"]

  test "two begin/end constructs on the same line pop and re-enter cleanly":
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
    let lt = tokenizeLine("\"a\" \"b\"", initialStack(g))

    check lt.tokens.len == 7
    check lt.tokens[0].scopes == @["source.test", "string.quoted"]
    check lt.tokens[1].scopes == @["source.test", "string.quoted", "meta.string.body"]
    check lt.tokens[2].scopes == @["source.test", "string.quoted"]
    check lt.tokens[3].scopes == @["source.test"]
    check lt.tokens[4].scopes == @["source.test", "string.quoted"]
    check lt.tokens[5].scopes == @["source.test", "string.quoted", "meta.string.body"]
    check lt.tokens[6].scopes == @["source.test", "string.quoted"]

suite "begin/end captures":
  test "beginCaptures split the begin match, endCaptures split the end match":
    let jsonStr = """
    {
      "scopeName": "source.test",
      "patterns": [ {
        "begin": "(<)(\\w+)",
        "end": "(/)(>)",
        "name": "tag",
        "beginCaptures": {
          "1": { "name": "punct.open" },
          "2": { "name": "tag.name" }
        },
        "endCaptures": {
          "1": { "name": "punct.close" },
          "2": { "name": "punct.angle" }
        }
      } ]
    }
    """
    let g = compileGrammar(parseRawGrammar(jsonStr))
    let lt = tokenizeLine("<div/>", initialStack(g))

    # <  div  /  >  (no content between begin and end)
    check lt.tokens.len == 4
    check lt.tokens[0].startIndex == 0
    check lt.tokens[0].endIndex == 1
    check lt.tokens[0].scopes == @["source.test", "tag", "punct.open"]
    check lt.tokens[1].startIndex == 1
    check lt.tokens[1].endIndex == 4
    check lt.tokens[1].scopes == @["source.test", "tag", "tag.name"]
    check lt.tokens[2].startIndex == 4
    check lt.tokens[2].endIndex == 5
    check lt.tokens[2].scopes == @["source.test", "tag", "punct.close"]
    check lt.tokens[3].startIndex == 5
    check lt.tokens[3].endIndex == 6
    check lt.tokens[3].scopes == @["source.test", "tag", "punct.angle"]

  test "contentName does not leak into the begin or end captures":
    let jsonStr = """
    {
      "scopeName": "source.test",
      "patterns": [ {
        "begin": "(\\()",
        "end": "(\\))",
        "name": "group",
        "contentName": "group.body",
        "beginCaptures": { "1": { "name": "punct.open" } },
        "endCaptures": { "1": { "name": "punct.close" } }
      } ]
    }
    """
    let g = compileGrammar(parseRawGrammar(jsonStr))
    let lt = tokenizeLine("(x)", initialStack(g))

    check lt.tokens.len == 3
    check lt.tokens[0].scopes == @["source.test", "group", "punct.open"]
    check lt.tokens[1].scopes == @["source.test", "group", "group.body"]
    check lt.tokens[2].scopes == @["source.test", "group", "punct.close"]

suite "begin/end multi-line":
  test "unterminated begin carries contentName to end of line and into next line":
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
    let line1 = tokenizeLine("\"hello", initialStack(g))

    check line1.tokens.len == 2
    check line1.tokens[0].scopes == @["source.test", "string.quoted"]
    check line1.tokens[0].startIndex == 0
    check line1.tokens[0].endIndex == 1
    check line1.tokens[1].scopes == @[
      "source.test", "string.quoted", "meta.string.body"
    ]
    check line1.tokens[1].startIndex == 1
    check line1.tokens[1].endIndex == 6

    let line2 = tokenizeLine("world\"", line1.ruleStack)

    check line2.tokens.len == 2
    check line2.tokens[0].scopes == @[
      "source.test", "string.quoted", "meta.string.body"
    ]
    check line2.tokens[0].startIndex == 0
    check line2.tokens[0].endIndex == 5
    check line2.tokens[1].scopes == @["source.test", "string.quoted"]
    check line2.tokens[1].startIndex == 5
    check line2.tokens[1].endIndex == 6

  test "empty line inside a begin/end block emits no tokens and preserves the stack":
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
    let line1 = tokenizeLine("\"open", initialStack(g))
    let line2 = tokenizeLine("", line1.ruleStack)
    let line3 = tokenizeLine("close\"", line2.ruleStack)

    check line2.tokens.len == 0
    check line3.tokens.len == 2
    check line3.tokens[0].scopes == @[
      "source.test", "string.quoted", "meta.string.body"
    ]
    check line3.tokens[1].scopes == @["source.test", "string.quoted"]

suite "begin/end backreferences":
  test "numeric backref in end substitutes the begin capture literally":
    # heredoc-style: the delimiter is whatever begin captured in group 1.
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
    let lt = tokenizeLine("<<EOF body EOF rest", initialStack(g))

    # "<<EOF" begin, " body " content, "EOF" end, " rest" outside.
    check lt.tokens.len == 4
    check lt.tokens[0].scopes == @["source.test", "heredoc"]
    check lt.tokens[0].startIndex == 0
    check lt.tokens[0].endIndex == 5
    check lt.tokens[1].scopes == @["source.test", "heredoc"]
    check lt.tokens[1].startIndex == 5
    check lt.tokens[1].endIndex == 11
    check lt.tokens[2].scopes == @["source.test", "heredoc"]
    check lt.tokens[2].startIndex == 11
    check lt.tokens[2].endIndex == 14
    check lt.tokens[3].scopes == @["source.test"]
    check lt.tokens[3].startIndex == 14
    check lt.tokens[3].endIndex == 19

  test "different begin captures produce different end regexes on the same line":
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
    # First heredoc closes on EOF, second closes on END.
    let lt = tokenizeLine("<<EOF a EOF <<END b END", initialStack(g))
    # Both heredocs should close cleanly, leaving a non-heredoc tail.
    check lt.ruleStack.contentName == "source.test"

  test "named backref \\k<name> in end substitutes the named begin capture":
    let jsonStr = """
    {
      "scopeName": "source.test",
      "patterns": [ {
        "begin": "<<(?<delim>\\w+)", "end": "\\k<delim>",
        "name": "heredoc"
      } ]
    }
    """
    let g = compileGrammar(parseRawGrammar(jsonStr))
    let lt = tokenizeLine("<<EOF body EOF rest", initialStack(g))

    check lt.tokens.len == 4
    check lt.tokens[0].scopes == @["source.test", "heredoc"]
    check lt.tokens[2].scopes == @["source.test", "heredoc"]
    check lt.tokens[3].scopes == @["source.test"]

  test "regex metacharacters in the captured delimiter are escaped on substitution":
    # Begin captures a literal ".": if we did not escape when substituting,
    # end would be a regex dot and match the first non-newline char.
    let jsonStr = """
    {
      "scopeName": "source.test",
      "patterns": [ {
        "begin": "<<(\\.+)", "end": "\\1",
        "name": "heredoc"
      } ]
    }
    """
    let g = compileGrammar(parseRawGrammar(jsonStr))
    let lt = tokenizeLine("<<.. body .. rest", initialStack(g))

    # If "." in end were unescaped, end would match at pos 2 (the second "."
    # of the begin itself) and the tokens would look very different. We
    # expect end to match the literal "..".
    check lt.tokens.len == 4
    check lt.tokens[0].endIndex == 4 # "<<.."
    check lt.tokens[2].startIndex == 10 # ".." at position 10
    check lt.tokens[2].endIndex == 12
    check lt.tokens[3].scopes == @["source.test"]
