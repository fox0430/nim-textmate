import std/unittest

import textmate

const KeywordGrammar = """
  {
    "scopeName": "source.test",
    "patterns": [ { "match": "\\bfoo\\b", "name": "keyword.foo" } ]
  }
"""

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

const HeredocGrammar = """
  {
    "scopeName": "source.sh",
    "patterns": [ {
      "begin": "<<(\\w+)",
      "end": "^\\1$",
      "name": "heredoc"
    } ]
  }
"""

proc sameTokens(a, b: seq[Token]): bool =
  if a.len != b.len:
    return false
  for i in 0 ..< a.len:
    if a[i].startIndex != b[i].startIndex or a[i].endIndex != b[i].endIndex:
      return false
    if a[i].scopes != b[i].scopes:
      return false
  true

proc sameDoc(doc: DocumentTokens, refLines: seq[LineTokens]): bool =
  if doc.numLines != refLines.len:
    return false
  for i in 0 ..< refLines.len:
    let lt = doc.getLine(i)
    if not sameTokens(lt.tokens, refLines[i].tokens):
      return false
    if not stackEquals(lt.ruleStack, refLines[i].ruleStack):
      return false
  true

suite "stackEquals":
  test "initialStack from same grammar is equal to itself":
    let g = compileGrammar(parseRawGrammar(KeywordGrammar))
    check stackEquals(initialStack(g), initialStack(g))

  test "initialStacks from different grammars are unequal":
    let g1 = compileGrammar(parseRawGrammar(KeywordGrammar))
    let g2 = compileGrammar(parseRawGrammar(StringGrammar))
    check not stackEquals(initialStack(g1), initialStack(g2))

  test "end-of-line stacks from tokenizing identical input converge":
    let g = compileGrammar(parseRawGrammar(StringGrammar))
    let lines = @["\"hello", "middle", "world\""]
    let a = tokenizeDocument(lines, initialStack(g))
    let b = tokenizeDocument(lines, initialStack(g))
    for i in 0 ..< lines.len:
      check stackEquals(a[i].ruleStack, b[i].ruleStack)

  test "inside and outside an open begin/end differ":
    let g = compileGrammar(parseRawGrammar(StringGrammar))
    let openStack = tokenizeLine("\"hello", initialStack(g))
    let closed = tokenizeLine("hello", initialStack(g))
    check not stackEquals(openStack.ruleStack, closed.ruleStack)

  test "same rule with different heredoc terminators are unequal":
    let g = compileGrammar(parseRawGrammar(HeredocGrammar))
    let a = tokenizeLine("cat <<EOF", initialStack(g))
    let b = tokenizeLine("cat <<DONE", initialStack(g))
    # Same rule pushed, same parent — but different resolved terminator
    # sources (\\1 substituted to EOF vs DONE). Must NOT be equal.
    check a.ruleStack.rule == b.ruleStack.rule
    check not stackEquals(a.ruleStack, b.ruleStack)

  test "nil handling":
    let g = compileGrammar(parseRawGrammar(KeywordGrammar))
    check stackEquals(nil, nil)
    check not stackEquals(nil, initialStack(g))
    check not stackEquals(initialStack(g), nil)

suite "DocumentTokens":
  test "setLines matches tokenizeDocument":
    let g = compileGrammar(parseRawGrammar(StringGrammar))
    let lines = @["\"hello", "middle", "world\"", "after"]
    let doc = newDocumentTokens(g)
    doc.setLines(lines)
    let refDoc = tokenizeDocument(lines, initialStack(g))
    check sameDoc(doc, refDoc)

  test "no-op applyEdit returns empty range and leaves doc unchanged":
    let g = compileGrammar(parseRawGrammar(KeywordGrammar))
    let lines = @["foo one", "two foo", "bar"]
    let doc = newDocumentTokens(g)
    doc.setLines(lines)
    let rng = doc.applyEdit(1, 0, [])
    check rng.len == 0
    let refDoc = tokenizeDocument(lines, initialStack(g))
    check sameDoc(doc, refDoc)

  test "edit in match-only grammar affects only the edited line":
    let g = compileGrammar(parseRawGrammar(KeywordGrammar))
    let lines = @["foo one", "two bar", "three foo"]
    let doc = newDocumentTokens(g)
    doc.setLines(lines)
    # Stash line 0 and line 2 tokens to confirm they survive unchanged.
    let line0Before = doc.getLine(0).tokens
    let line2Before = doc.getLine(2).tokens
    let rng = doc.applyEdit(1, 1, ["foo replaced"])
    # Only line 1 dirty.
    check rng == 1 ..< 2
    let finalLines = @["foo one", "foo replaced", "three foo"]
    let refDoc = tokenizeDocument(finalLines, initialStack(g))
    check sameDoc(doc, refDoc)
    check sameTokens(doc.getLine(0).tokens, line0Before)
    check sameTokens(doc.getLine(2).tokens, line2Before)

  test "opening a begin without closing cascades through the tail":
    let g = compileGrammar(parseRawGrammar(StringGrammar))
    let lines = @["plain one", "plain two", "plain three"]
    let doc = newDocumentTokens(g)
    doc.setLines(lines)
    # Insert an unterminated string at line 0 — all subsequent lines
    # become part of the string and must be re-tokenized.
    let rng = doc.applyEdit(0, 1, ["\"opened"])
    check rng == 0 ..< 3
    let finalLines = @["\"opened", "plain two", "plain three"]
    let refDoc = tokenizeDocument(finalLines, initialStack(g))
    check sameDoc(doc, refDoc)
    # Sanity: line 2 is now inside the string.
    check "string.quoted" in doc.getLine(2).tokens[0].scopes

  test "closing a previously open block converges at the close line":
    let g = compileGrammar(parseRawGrammar(StringGrammar))
    # Start with an open string spanning 3 lines.
    let initialLines = @["\"open", "mid one", "mid two", "after"]
    let doc = newDocumentTokens(g)
    doc.setLines(initialLines)
    # Close the string by editing line 1 to terminate the quote.
    let rng = doc.applyEdit(1, 1, ["mid one\""])
    # Lines 0 unchanged (didn't need rewrite); line 1 rewritten;
    # line 2 rewritten (now outside string); line 3 converges (it was
    # already outside the string).
    # Convergence stops before the last rewrite, so range is 1..<3.
    check rng.a == 1
    check rng.b <= 3
    let finalLines = @["\"open", "mid one\"", "mid two", "after"]
    let refDoc = tokenizeDocument(finalLines, initialStack(g))
    check sameDoc(doc, refDoc)

  test "insert at line 0 uses initial stack":
    let g = compileGrammar(parseRawGrammar(KeywordGrammar))
    let doc = newDocumentTokens(g)
    doc.setLines(@["foo one", "two"])
    let rng = doc.applyEdit(0, 0, ["prefix foo"])
    check rng == 0 ..< 1
    check doc.numLines == 3
    let refDoc = tokenizeDocument(@["prefix foo", "foo one", "two"], initialStack(g))
    check sameDoc(doc, refDoc)

  test "pure delete at tail shrinks line count":
    let g = compileGrammar(parseRawGrammar(KeywordGrammar))
    let doc = newDocumentTokens(g)
    doc.setLines(@["foo one", "two", "three foo"])
    let rng = doc.applyEdit(2, 1, [])
    check rng.len == 0
    check doc.numLines == 2
    let refDoc = tokenizeDocument(@["foo one", "two"], initialStack(g))
    check sameDoc(doc, refDoc)

  test "append past end via startLine == numLines":
    let g = compileGrammar(parseRawGrammar(KeywordGrammar))
    let doc = newDocumentTokens(g)
    doc.setLines(@["foo one"])
    let rng = doc.applyEdit(1, 0, ["foo two", "three"])
    check rng == 1 ..< 3
    check doc.numLines == 3
    let refDoc = tokenizeDocument(@["foo one", "foo two", "three"], initialStack(g))
    check sameDoc(doc, refDoc)

  test "full-document replacement is equivalent to tokenizeDocument":
    let g = compileGrammar(parseRawGrammar(StringGrammar))
    let doc = newDocumentTokens(g)
    doc.setLines(@["a", "b", "c"])
    discard doc.applyEdit(0, 3, ["\"x", "y", "z\""])
    let refDoc = tokenizeDocument(@["\"x", "y", "z\""], initialStack(g))
    check sameDoc(doc, refDoc)

  test "multiple sequential edits stay consistent with full re-tokenization":
    let g = compileGrammar(parseRawGrammar(StringGrammar))
    let doc = newDocumentTokens(g)
    doc.setLines(@["one", "two", "three"])

    discard doc.applyEdit(1, 1, ["\"open"])
    discard doc.applyEdit(3, 0, ["more", "close\""])
    discard doc.applyEdit(0, 1, ["first"])

    let expected = @["first", "\"open", "three", "more", "close\""]
    let refDoc = tokenizeDocument(expected, initialStack(g))
    check sameDoc(doc, refDoc)
