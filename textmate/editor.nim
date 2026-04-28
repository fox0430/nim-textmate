## Incremental editor integration.
##
## `DocumentTokens` is a stateful wrapper over `tokenizeLine` that
## caches per-line tokens and end-of-line rule stacks, so edits only
## re-tokenize the affected region. When the freshly computed
## end-of-line stack matches the previously stored one for a line past
## the edit region, re-tokenization stops early — subsequent lines are
## then provably unchanged.
##
## Intended consumer: text editors and language-server hosts that keep
## a document in memory and want highlight refreshes proportional to
## the edit size, not the document size.

import ./[types, tokenizer]

type DocumentTokens* = ref object
  ## Editor-facing incremental tokenization session. Owns the line
  ## buffer and the parallel token / end-of-line-stack caches. Use
  ## `setLines` to seed, `applyEdit` to splice edits in, and
  ## `getLine` to read current tokens.
  grammar: Grammar
  registry: Registry
  lines: seq[string]
  lineTokens: seq[seq[Token]] ## `lineTokens[i]` is the tokens for `lines[i]`.
  endStacks: seq[StackElement]
    ## `endStacks[i]` is the rule stack at the end of `lines[i]`.
  initStack: StackElement
    ## Cached `initialStack(grammar, registry)`; the input stack for
    ## line 0.

proc newDocumentTokens*(grammar: Grammar, registry: Registry = nil): DocumentTokens =
  ## Start a new empty document session for `grammar`. Pass the same
  ## `registry` used with `addGrammar` if cross-grammar injections
  ## should resolve.
  DocumentTokens(
    grammar: grammar, registry: registry, initStack: initialStack(grammar, registry)
  )

proc numLines*(doc: DocumentTokens): int {.inline.} =
  doc.lines.len

proc getLine*(doc: DocumentTokens, i: int): LineTokens =
  ## Return the cached `LineTokens` for line `i`. Raises `IndexDefect`
  ## when `i` is out of range.
  LineTokens(tokens: doc.lineTokens[i], ruleStack: doc.endStacks[i])

proc tokenizeAllFrom(doc: DocumentTokens, startLine: int) =
  ## Tokenize `startLine ..< numLines`, overwriting cache entries. Used
  ## by `setLines`.
  var cur =
    if startLine == 0:
      doc.initStack
    else:
      doc.endStacks[startLine - 1]
  for i in startLine ..< doc.lines.len:
    let lt = tokenizeLine(doc.lines[i], cur)
    doc.lineTokens[i] = lt.tokens
    doc.endStacks[i] = lt.ruleStack
    cur = lt.ruleStack

proc setLines*(doc: DocumentTokens, lines: openArray[string]) =
  ## Replace the entire document with `lines` and tokenize every line
  ## from the initial stack. Equivalent in output to
  ## `tokenizeDocument(lines, initialStack(grammar, registry))`.
  doc.lines.setLen(lines.len)
  for i in 0 ..< lines.len:
    doc.lines[i] = lines[i]
  doc.lineTokens.setLen(lines.len)
  doc.endStacks.setLen(lines.len)
  tokenizeAllFrom(doc, 0)

proc spliceSeq[T](s: var seq[T], startLine, deleteCount, insertLen: int) =
  ## Splice `s` in place: replace `[startLine, startLine+deleteCount)`
  ## with `insertLen` default-initialised slots. Callers fill the
  ## inserted slots themselves.
  let delta = insertLen - deleteCount
  if delta > 0:
    s.setLen(s.len + delta)
    for i in countdown(s.len - 1, startLine + insertLen):
      s[i] = s[i - delta]
  elif delta < 0:
    for i in startLine + insertLen ..< s.len + delta:
      s[i] = s[i - delta]
    s.setLen(s.len + delta)

proc spliceSeqs(doc: DocumentTokens, startLine, deleteCount, insertLen: int) =
  ## Splice `lines`, `lineTokens`, `endStacks` in parallel. Leaves the
  ## inserted slot range uninitialised (the caller rewrites it); tail
  ## entries past the edit region are shifted into their final place.
  spliceSeq(doc.lines, startLine, deleteCount, insertLen)
  spliceSeq(doc.lineTokens, startLine, deleteCount, insertLen)
  spliceSeq(doc.endStacks, startLine, deleteCount, insertLen)

proc applyEdit*(
    doc: DocumentTokens,
    startLine: int,
    deleteCount: int,
    insertedLines: openArray[string],
): Slice[int] =
  ## Splice-style edit: replace
  ## `lines[startLine ..< startLine+deleteCount]` with `insertedLines`,
  ## then re-tokenize from `startLine`. Re-tokenization stops when the
  ## freshly computed end-of-line stack matches the previously stored
  ## one for a line past the edit region, leaving tail lines untouched.
  ##
  ## Returns the half-open range of line indices that were rewritten —
  ## callers iterate this to refresh highlights. An empty range (e.g.
  ## `10..<10`) means no line needed re-tokenization.
  if startLine < 0 or startLine > doc.lines.len:
    raise newException(
      RangeDefect,
      "applyEdit: startLine " & $startLine & " out of bounds (0.." & $doc.lines.len & ")",
    )
  if deleteCount < 0 or startLine + deleteCount > doc.lines.len:
    raise newException(
      RangeDefect,
      "applyEdit: deleteCount " & $deleteCount & " out of bounds at startLine " &
        $startLine,
    )

  spliceSeqs(doc, startLine, deleteCount, insertedLines.len)
  for k in 0 ..< insertedLines.len:
    doc.lines[startLine + k] = insertedLines[k]

  let firstDirty = startLine
  let editEnd = startLine + insertedLines.len
  var cur =
    if startLine == 0:
      doc.initStack
    else:
      doc.endStacks[startLine - 1]
  var i = firstDirty
  while i < doc.lines.len:
    let lt = tokenizeLine(doc.lines[i], cur)
    if i >= editEnd and stackEquals(lt.ruleStack, doc.endStacks[i]):
      # Output stack matches the stored one, so line i+1 onward receives
      # an equivalent input stack and is provably unchanged. But line i
      # itself may have new tokens if its own input stack changed
      # (`cur` can differ from what produced the stored tokens even when
      # the two paths converge to the same output). Compare tokens and
      # include line i in the dirty range iff they actually differ.
      if doc.lineTokens[i] != lt.tokens:
        doc.lineTokens[i] = lt.tokens
        inc i
      break
    doc.lineTokens[i] = lt.tokens
    doc.endStacks[i] = lt.ruleStack
    cur = lt.ruleStack
    inc i

  firstDirty ..< i
