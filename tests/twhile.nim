import std/unittest

import textmate

suite "while rule":
  test "blockquote-like block: while matches -> line stays in block":
    let jsonStr = """
    {
      "scopeName": "source.test",
      "patterns": [ {
        "begin": "^>",
        "while": "^>",
        "name": "markup.quote"
      } ]
    }
    """
    let g = compileGrammar(parseRawGrammar(jsonStr))

    # Line 1 fires `begin`.
    let lt1 = tokenizeLine("> foo", initialStack(g))
    check lt1.tokens.len > 0
    # All tokens from line 1 carry the block scope.
    for tok in lt1.tokens:
      check "markup.quote" in tok.scopes

    # Line 2 starts with `>` too; while should succeed.
    let lt2 = tokenizeLine("> bar", lt1.ruleStack)
    for tok in lt2.tokens:
      check "markup.quote" in tok.scopes

    # Line 3 no longer matches while: should tokenise under the parent scope
    # with no `markup.quote` on any token, and the stack pops.
    let lt3 = tokenizeLine("baz", lt2.ruleStack)
    for tok in lt3.tokens:
      check "markup.quote" notin tok.scopes

  test "while failure pops the frame, no token is emitted for the failed check":
    let jsonStr = """
    {
      "scopeName": "source.test",
      "patterns": [ { "begin": "^>", "while": "^>", "name": "markup.quote" } ]
    }
    """
    let g = compileGrammar(parseRawGrammar(jsonStr))
    let lt1 = tokenizeLine(">a", initialStack(g))
    let lt2 = tokenizeLine("b", lt1.ruleStack)

    # Exactly one token on line 2: "b" with just source.test.
    check lt2.tokens.len == 1
    check lt2.tokens[0].startIndex == 0
    check lt2.tokens[0].endIndex == 1
    check lt2.tokens[0].scopes == @["source.test"]

  test "nested patterns fire inside the while block":
    let jsonStr = """
    {
      "scopeName": "source.test",
      "patterns": [ {
        "begin": "^>",
        "while": "^>",
        "name": "markup.quote",
        "patterns": [ { "match": "\\bfoo\\b", "name": "keyword.foo" } ]
      } ]
    }
    """
    let g = compileGrammar(parseRawGrammar(jsonStr))
    let lt1 = tokenizeLine("> foo bar", initialStack(g))
    var sawKeyword = false
    for tok in lt1.tokens:
      if "keyword.foo" in tok.scopes:
        sawKeyword = true
        check "markup.quote" in tok.scopes
    check sawKeyword

    let lt2 = tokenizeLine("> foo", lt1.ruleStack)
    sawKeyword = false
    for tok in lt2.tokens:
      if "keyword.foo" in tok.scopes:
        sawKeyword = true
    check sawKeyword

  test "while with backrefs binds to begin captures":
    let jsonStr = """
    {
      "scopeName": "source.test",
      "patterns": [ {
        "begin": "^(\\w+):",
        "while": "^\\1:",
        "name": "meta.tagged"
      } ]
    }
    """
    let g = compileGrammar(parseRawGrammar(jsonStr))
    let lt1 = tokenizeLine("tag:one", initialStack(g))
    check lt1.tokens.len > 0
    check "meta.tagged" in lt1.tokens[0].scopes

    # Same tag: while succeeds.
    let lt2 = tokenizeLine("tag:two", lt1.ruleStack)
    for tok in lt2.tokens:
      check "meta.tagged" in tok.scopes

    # Different first token: while fails, frame pops silently.
    # (Plain text that does not match `begin` either, so no re-push.)
    let lt3 = tokenizeLine("plain three", lt2.ruleStack)
    for tok in lt3.tokens:
      check "meta.tagged" notin tok.scopes

  test "begin-firing line does not trigger the while check":
    # Even though the begin line does not match the while pattern anywhere,
    # the line itself must still be tokenised under the block (the while
    # check only kicks in on subsequent lines).
    let jsonStr = """
    {
      "scopeName": "source.test",
      "patterns": [ {
        "begin": "^BEGIN",
        "while": "^CONT",
        "name": "meta.block"
      } ]
    }
    """
    let g = compileGrammar(parseRawGrammar(jsonStr))
    let lt1 = tokenizeLine("BEGIN stuff", initialStack(g))
    check lt1.tokens.len > 0
    # All tokens on the begin line carry the block scope.
    for tok in lt1.tokens:
      check "meta.block" in tok.scopes

  test "zero-width while (lookahead) does not loop forever":
    let jsonStr = """
    {
      "scopeName": "source.test",
      "patterns": [ {
        "begin": "^>",
        "while": "(?=>)",
        "name": "markup.lookahead"
      } ]
    }
    """
    let g = compileGrammar(parseRawGrammar(jsonStr))
    let lt1 = tokenizeLine(">a", initialStack(g))
    # Terminates without hang.
    let lt2 = tokenizeLine(">b", lt1.ruleStack)
    check lt2.tokens.len > 0
    for tok in lt2.tokens:
      check tok.endIndex > tok.startIndex
