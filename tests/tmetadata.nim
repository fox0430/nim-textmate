import std/[unittest, tables]

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

proc decodeScopes(ids: seq[ScopeId], m: ScopeIdMap): seq[ScopeName] =
  for id in ids:
    result.add lookupScope(m, id)

suite "ScopeIdMap":
  test "zero sentinel: byId[0] == empty, lookupScope(m, 0) == empty":
    let m = newScopeIdMap()
    check m.byId.len == 1
    check m.byId[0] == ""
    check lookupScope(m, ScopeId(0)) == ""

  test "monotonic ids starting at 1":
    let m = newScopeIdMap()
    check internScope(m, "a") == ScopeId(1)
    check internScope(m, "b") == ScopeId(2)
    check internScope(m, "c") == ScopeId(3)

  test "repeat intern returns the same id":
    let m = newScopeIdMap()
    check internScope(m, "a") == ScopeId(1)
    check internScope(m, "b") == ScopeId(2)
    check internScope(m, "a") == ScopeId(1)
    check internScope(m, "c") == ScopeId(3)
    check internScope(m, "a") == ScopeId(1)

  test "round-trip: lookupScope(m, internScope(m, n)) == n":
    let m = newScopeIdMap()
    for n in ["source.test", "keyword.foo", "string.quoted", "meta.string.body"]:
      check lookupScope(m, internScope(m, n)) == n

  test "lookupScope for an unknown id returns empty string":
    let m = newScopeIdMap()
    discard internScope(m, "a")
    check lookupScope(m, ScopeId(99)) == ""

  test "empty string normalises to the sentinel without growing the map":
    let m = newScopeIdMap()
    check internScope(m, "") == ScopeId(0)
    check m.byId.len == 1
    check not m.byName.hasKey("")
    # A real scope interned afterwards still gets id 1, not 2.
    check internScope(m, "a") == ScopeId(1)
    check internScope(m, "") == ScopeId(0)

suite "tokenizeLineMetadata":
  test "scopeIds decode back to plain-tokenize scopes":
    let g = compileGrammar(parseRawGrammar(KeywordGrammar))
    let m = newScopeIdMap()
    let plain = tokenizeLine("hello foo bar", initialStack(g))
    let meta = tokenizeLineMetadata("hello foo bar", initialStack(g), m)
    check plain.tokens.len == meta.tokens.len
    for i in 0 ..< plain.tokens.len:
      check meta.tokens[i].startIndex == plain.tokens[i].startIndex
      check meta.tokens[i].endIndex == plain.tokens[i].endIndex
      check decodeScopes(meta.tokens[i].scopeIds, m) == plain.tokens[i].scopes

  test "metadata is DefaultMetadata (all zero) on every token":
    let g = compileGrammar(parseRawGrammar(KeywordGrammar))
    let m = newScopeIdMap()
    let meta = tokenizeLineMetadata("hello foo bar", initialStack(g), m)
    check uint32(DefaultMetadata) == 0'u32
    for t in meta.tokens:
      check uint32(t.metadata) == 0'u32

  test "ids are stable across repeated tokenize calls on same map":
    let g = compileGrammar(parseRawGrammar(KeywordGrammar))
    let m = newScopeIdMap()
    let first = tokenizeLineMetadata("hello foo bar", initialStack(g), m)
    let second = tokenizeLineMetadata("hello foo bar", initialStack(g), m)
    check first.tokens.len == second.tokens.len
    for i in 0 ..< first.tokens.len:
      check first.tokens[i].scopeIds == second.tokens[i].scopeIds

suite "tokenizeDocumentMetadata":
  test "stack threading matches tokenizeDocument":
    let g = compileGrammar(parseRawGrammar(StringGrammar))
    let m = newScopeIdMap()
    let lines = @["\"hello", "middle", "world\""]
    let plainDoc = tokenizeDocument(lines, initialStack(g))
    let metaDoc = tokenizeDocumentMetadata(lines, initialStack(g), m)
    check plainDoc.len == metaDoc.len
    for i in 0 ..< plainDoc.len:
      check plainDoc[i].tokens.len == metaDoc[i].tokens.len
      for j in 0 ..< plainDoc[i].tokens.len:
        check decodeScopes(metaDoc[i].tokens[j].scopeIds, m) ==
          plainDoc[i].tokens[j].scopes
    check fullScopes(plainDoc[^1].ruleStack) == fullScopes(metaDoc[^1].ruleStack)

  test "iterator yields the same sequence as the batch proc":
    let g = compileGrammar(parseRawGrammar(StringGrammar))
    let m = newScopeIdMap()
    let lines = @["\"abc", "def\""]
    let batch = tokenizeDocumentMetadata(lines, initialStack(g), m)
    var collected: seq[MetadataLineTokens]
    let m2 = newScopeIdMap()
    for mlt in tokenizeDocumentMetadataIter(lines, initialStack(g), m2):
      collected.add(mlt)
    check collected.len == batch.len
    # The two maps were populated independently but should yield the same
    # decoded scope sequences (ids may differ because insertion order can
    # differ; here lines are identical, so insertion order matches and ids
    # should agree).
    for i in 0 ..< batch.len:
      for j in 0 ..< batch[i].tokens.len:
        check decodeScopes(batch[i].tokens[j].scopeIds, m) ==
          decodeScopes(collected[i].tokens[j].scopeIds, m2)

  test "shared map across separate documents keeps ids stable":
    let g = compileGrammar(parseRawGrammar(KeywordGrammar))
    let m = newScopeIdMap()
    let d1 = tokenizeDocumentMetadata(@["hello foo"], initialStack(g), m)
    let fooIdInDoc1 = d1[0].tokens[1].scopeIds[^1] # inner scope == keyword.foo
    let d2 = tokenizeDocumentMetadata(@["another foo here"], initialStack(g), m)
    let fooIdInDoc2 = d2[0].tokens[1].scopeIds[^1]
    check fooIdInDoc1 == fooIdInDoc2
    check lookupScope(m, fooIdInDoc1) == "keyword.foo"

  test "depth-3 nested begin/end parity with plain tokenizer":
    # Exercises fullScopes / fullScopeIds under push depth > 2. When a
    # capture-free begin/end is pushed, the base-scope cache on each
    # stack frame must agree with the plain tokenizer's reconstructed
    # scope chain.
    const NestedGrammar = """
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
    let g = compileGrammar(parseRawGrammar(NestedGrammar))
    let m = newScopeIdMap()
    let lines = @["([{x}])"]
    let plainDoc = tokenizeDocument(lines, initialStack(g))
    let metaDoc = tokenizeDocumentMetadata(lines, initialStack(g), m)
    check plainDoc.len == metaDoc.len
    for i in 0 ..< plainDoc.len:
      check plainDoc[i].tokens.len == metaDoc[i].tokens.len
      for j in 0 ..< plainDoc[i].tokens.len:
        check decodeScopes(metaDoc[i].tokens[j].scopeIds, m) ==
          plainDoc[i].tokens[j].scopes

  test "captures path parity: capture-group scopes decode identically":
    # Captures are layered in after the rule's base scope, and the
    # direct-metadata path must intern the same sequence as the plain
    # path produces via `emitSpanWithCaptures`.
    const CaptureGrammar = """
    {
      "scopeName": "source.test",
      "patterns": [ {
        "match": "(foo)=(\\d+)",
        "name": "assignment",
        "captures": {
          "1": { "name": "variable.name" },
          "2": { "name": "constant.numeric" }
        }
      } ]
    }
    """
    let g = compileGrammar(parseRawGrammar(CaptureGrammar))
    let m = newScopeIdMap()
    let line = "foo=42"
    let plain = tokenizeLine(line, initialStack(g))
    let meta = tokenizeLineMetadata(line, initialStack(g), m)
    check plain.tokens.len == meta.tokens.len
    for i in 0 ..< plain.tokens.len:
      check meta.tokens[i].startIndex == plain.tokens[i].startIndex
      check meta.tokens[i].endIndex == plain.tokens[i].endIndex
      check decodeScopes(meta.tokens[i].scopeIds, m) == plain.tokens[i].scopes

  test "empty line inside multi-line metadata document keeps parity":
    # An empty line inside an open begin/end block emits no tokens but
    # must still thread the stack (and its cached-scope state) to the
    # next line identically on both paths.
    let g = compileGrammar(parseRawGrammar(StringGrammar))
    let m = newScopeIdMap()
    let lines = @["\"abc", "", "def\""]
    let plainDoc = tokenizeDocument(lines, initialStack(g))
    let metaDoc = tokenizeDocumentMetadata(lines, initialStack(g), m)
    check plainDoc.len == metaDoc.len
    for i in 0 ..< plainDoc.len:
      check plainDoc[i].tokens.len == metaDoc[i].tokens.len
      for j in 0 ..< plainDoc[i].tokens.len:
        check decodeScopes(metaDoc[i].tokens[j].scopeIds, m) ==
          plainDoc[i].tokens[j].scopes

suite "TokenMetadata bit ops":
  test "borrowed and/or/shr/shl work on distinct type":
    let a = TokenMetadata(0xF0'u32)
    let b = TokenMetadata(0x0F'u32)
    check uint32(a or b) == 0xFF'u32
    check uint32(a and b) == 0'u32
    check uint32(TokenMetadata(1'u32) shl 3) == 8'u32
    check uint32(TokenMetadata(16'u32) shr 2) == 4'u32
