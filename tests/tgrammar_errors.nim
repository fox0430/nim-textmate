import std/[strutils, unittest]

import textmate

suite "grammar errors":
  test "malformed JSON raises GrammarError":
    expect GrammarError:
      discard parseRawGrammar("{ this is not json")

  test "missing scopeName raises GrammarError":
    expect GrammarError:
      discard parseRawGrammar("""{ "patterns": [] }""")

  test "non-object grammar root raises GrammarError":
    expect GrammarError:
      discard parseRawGrammar("[]")

  test "invalid regex in match raises GrammarError at compileGrammar":
    let raw = parseRawGrammar(
      """
      { "scopeName": "source.test",
        "patterns": [ { "match": "(", "name": "x" } ] }
      """
    )
    expect GrammarError:
      discard compileGrammar(raw)

  test "non-string match field raises GrammarError":
    expect GrammarError:
      discard parseRawGrammar(
        """
        { "scopeName": "source.test",
          "patterns": [ { "match": 123, "name": "x" } ] }
        """
      )

  test "non-string scopeName raises GrammarError":
    expect GrammarError:
      discard parseRawGrammar("""{ "scopeName": 42 }""")

  test "non-array patterns raises GrammarError":
    expect GrammarError:
      discard parseRawGrammar("""{ "scopeName": "source.test", "patterns": "oops" }""")

  test "non-object capture entry raises GrammarError":
    expect GrammarError:
      discard parseRawGrammar(
        """
        { "scopeName": "source.test",
          "patterns": [ {
            "match": "foo",
            "captures": { "1": "not-an-object" }
          } ] }
        """
      )

  test "begin without end raises GrammarError at compileGrammar":
    let raw = parseRawGrammar(
      """
      { "scopeName": "source.test",
        "patterns": [ { "begin": "\"", "name": "x" } ] }
      """
    )
    expect GrammarError:
      discard compileGrammar(raw)

  test "invalid begin regex raises GrammarError at compileGrammar":
    let raw = parseRawGrammar(
      """
      { "scopeName": "source.test",
        "patterns": [ { "begin": "(", "end": "\"", "name": "x" } ] }
      """
    )
    expect GrammarError:
      discard compileGrammar(raw)

  test "invalid end regex raises GrammarError at compileGrammar":
    let raw = parseRawGrammar(
      """
      { "scopeName": "source.test",
        "patterns": [ { "begin": "\"", "end": "(", "name": "x" } ] }
      """
    )
    expect GrammarError:
      discard compileGrammar(raw)

  test "empty include target raises GrammarError at parseRawGrammar":
    expect GrammarError:
      discard parseRawGrammar(
        """
        { "scopeName": "source.test",
          "patterns": [ { "include": "" } ] }
        """
      )

  test "lone '#' include target raises GrammarError at compileGrammar":
    let raw = parseRawGrammar(
      """
      { "scopeName": "source.test",
        "patterns": [ { "include": "#" } ] }
      """
    )
    expect GrammarError:
      discard compileGrammar(raw)

  test "match and include together raises GrammarError":
    let raw = parseRawGrammar(
      """
      { "scopeName": "source.test",
        "patterns": [ { "match": "foo", "include": "$self" } ] }
      """
    )
    expect GrammarError:
      discard compileGrammar(raw)

  test "include and begin together raises GrammarError":
    let raw = parseRawGrammar(
      """
      { "scopeName": "source.test",
        "patterns": [ { "include": "$self", "begin": "\"", "end": "\"" } ] }
      """
    )
    expect GrammarError:
      discard compileGrammar(raw)

  test "match and begin together raises GrammarError":
    let raw = parseRawGrammar(
      """
      { "scopeName": "source.test",
        "patterns": [ { "match": "foo", "begin": "\"", "end": "\"" } ] }
      """
    )
    expect GrammarError:
      discard compileGrammar(raw)

  test "invalid include error carries the JSON path":
    # The offending pattern is nested two levels deep inside a begin/end
    # block. The raised message must point at that exact location so the
    # user can find it.
    let raw = parseRawGrammar(
      """
      { "scopeName": "source.test",
        "patterns": [
          { "begin": "\"", "end": "\"",
            "patterns": [ { "include": "#" } ] }
        ] }
      """
    )
    try:
      discard compileGrammar(raw)
      check false
    except GrammarError as e:
      check "patterns[0].patterns[0]" in e.msg

  test "invalid include error from repository entry carries the repository key":
    let raw = parseRawGrammar(
      """
      { "scopeName": "source.test",
        "patterns": [],
        "repository": {
          "broken": { "include": "#" }
        } }
      """
    )
    try:
      discard compileGrammar(raw)
      check false
    except GrammarError as e:
      check "repository.broken" in e.msg

  test "valid begin/end rule with sub-patterns compiles without error":
    # Sub-patterns inside a begin/end rule compile but are not yet matched
    # by the tokenizer (Phase 4). Full begin/end tokenization behaviour is
    # covered in `tbeginend.nim`.
    let raw = parseRawGrammar(
      """
      { "scopeName": "source.test",
        "patterns": [
          { "begin": "\"", "end": "\"",
            "name": "string.quoted",
            "contentName": "meta.string.body",
            "patterns": [ { "match": "\\\\.", "name": "constant.escape" } ] }
        ] }
      """
    )
    discard compileGrammar(raw)
