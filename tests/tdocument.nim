import std/unittest

import textmate

const StringGrammar = """
  {
    "scopeName": "source.test",
    "patterns": [ {
      "begin": "\"", "end": "\"",
      "name": "string.quoted",
      "contentName": "meta.string.body"
    } ]
  }
"""

const QuoteGrammar = """
  {
    "scopeName": "source.test",
    "patterns": [ {
      "begin": "^>", "while": "^>", "name": "markup.quote"
    } ]
  }
"""

const KeywordGrammar = """
  {
    "scopeName": "source.test",
    "patterns": [ { "match": "\\bfoo\\b", "name": "keyword.foo" } ]
  }
"""

proc manualLoop(g: Grammar, lines: seq[string]): seq[LineTokens] =
  var stack = initialStack(g)
  for line in lines:
    let lt = tokenizeLine(line, stack)
    result.add(lt)
    stack = lt.ruleStack

proc sameTokens(a, b: seq[Token]): bool =
  if a.len != b.len:
    return false
  for i in 0 ..< a.len:
    if a[i].startIndex != b[i].startIndex or a[i].endIndex != b[i].endIndex:
      return false
    if a[i].scopes != b[i].scopes:
      return false
  true

suite "tokenizeDocument":
  test "empty input returns empty seq":
    let g = compileGrammar(parseRawGrammar(KeywordGrammar))
    let res = tokenizeDocument(@[], initialStack(g))
    check res.len == 0

  test "single line equals tokenizeLine":
    let g = compileGrammar(parseRawGrammar(KeywordGrammar))
    let single = tokenizeLine("hello foo bar", initialStack(g))
    let doc = tokenizeDocument(@["hello foo bar"], initialStack(g))
    check doc.len == 1
    check sameTokens(doc[0].tokens, single.tokens)
    check fullScopes(doc[0].ruleStack) == fullScopes(single.ruleStack)

  test "multi-line equivalence with hand-rolled loop":
    let g = compileGrammar(parseRawGrammar(KeywordGrammar))
    let lines = @["foo one", "two foo", "foo foo", "nothing"]
    let manual = manualLoop(g, lines)
    let doc = tokenizeDocument(lines, initialStack(g))
    check doc.len == manual.len
    for i in 0 ..< doc.len:
      check sameTokens(doc[i].tokens, manual[i].tokens)
    check fullScopes(doc[^1].ruleStack) == fullScopes(manual[^1].ruleStack)

  test "begin/end carries across lines":
    let g = compileGrammar(parseRawGrammar(StringGrammar))
    # Line 1 opens the string, line 2 is entirely inside it, line 3 closes.
    let lines = @["\"hello", "middle", "world\""]
    let doc = tokenizeDocument(lines, initialStack(g))
    check doc.len == 3
    # Line 2 tokens must all be inside the string block.
    for tok in doc[1].tokens:
      check "string.quoted" in tok.scopes
      check "meta.string.body" in tok.scopes
    # Line 3 final token closes the block (no contentName).
    let last = doc[2].tokens[^1]
    check last.scopes == @["source.test", "string.quoted"]

  test "while-rule block spans multiple lines":
    let g = compileGrammar(parseRawGrammar(QuoteGrammar))
    let lines = @["> foo", "> bar", "baz"]
    let doc = tokenizeDocument(lines, initialStack(g))
    check doc.len == 3
    for tok in doc[0].tokens:
      check "markup.quote" in tok.scopes
    for tok in doc[1].tokens:
      check "markup.quote" in tok.scopes
    for tok in doc[2].tokens:
      check "markup.quote" notin tok.scopes

  test "iterator yields the same sequence as the batch proc":
    let g = compileGrammar(parseRawGrammar(StringGrammar))
    let lines = @["\"hello", "middle", "world\"", "after"]
    let batch = tokenizeDocument(lines, initialStack(g))
    var collected: seq[LineTokens]
    for lt in tokenizeDocumentIter(lines, initialStack(g)):
      collected.add(lt)
    check collected.len == batch.len
    for i in 0 ..< collected.len:
      check sameTokens(collected[i].tokens, batch[i].tokens)
    check fullScopes(collected[^1].ruleStack) == fullScopes(batch[^1].ruleStack)

  test "iterator with empty input yields nothing":
    let g = compileGrammar(parseRawGrammar(KeywordGrammar))
    var count = 0
    for lt in tokenizeDocumentIter(@[], initialStack(g)):
      inc count
    check count == 0

  test "batch ruleStack matches manual loop end-of-document state":
    let g = compileGrammar(parseRawGrammar(StringGrammar))
    # Unterminated: the last line still has the string open, so the
    # ruleStack at the end should have the string rule on it.
    let lines = @["\"unterminated", "still inside"]
    let doc = tokenizeDocument(lines, initialStack(g))
    let manual = manualLoop(g, lines)
    check fullScopes(doc[^1].ruleStack) == fullScopes(manual[^1].ruleStack)
    # Sanity: string.quoted is still on the stack.
    check "string.quoted" in fullScopes(doc[^1].ruleStack)
