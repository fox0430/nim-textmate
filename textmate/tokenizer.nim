import std/[algorithm, hashes, options, sets, tables]

import pkg/reni

import ./[types, selector]

type CaptureEntry = object
  span: Span
  groupIdx: int
  name: ScopeName
  patterns: seq[Rule]

proc hash(r: Rule): Hash {.inline.} =
  hash(cast[pointer](r))

# Thread-local scratch shared across every `tokenizeLine` / `tokenizeRange`
# invocation on this thread. `MatchContext` is reni's reusable scratch
# buffer; reusing it eliminates the per-line allocation/destroy that the
# previous `newMatchContext()` per LineScanner pattern incurred. Each
# thread holds its own reni scratch buffer via `{.threadvar.}`; combined
# with thread-confined `Grammar`, no cross-thread state remains.
var sharedMatchCtx {.threadvar.}: MatchContext

proc getMatchContext(): MatchContext {.inline.} =
  if sharedMatchCtx.isNil:
    sharedMatchCtx = newMatchContext()
  sharedMatchCtx

proc clearTokenizerScratch*() =
  ## Drop this thread's reusable `MatchContext`. Useful before a
  ## short-lived worker terminates: Nim's ORC does not run destructors
  ## for `{.threadvar.}` refs at thread exit, so the few-KB scratch
  ## buffer that `tokenizeLine` lazily allocated would otherwise be
  ## leaked until process exit. Long-lived workers do not need to call
  ## this — a subsequent `tokenizeLine` on the same thread will
  ## allocate a fresh ctx if needed.
  sharedMatchCtx = nil

proc safeAdvance*(line: string, pos: int): int {.inline.} =
  ## UTF-8 safe forward step. Guarantees `result > pos`. Falls back to
  ## manual continuation-byte skipping when `nextRunePos` cannot advance
  ## (malformed UTF-8 or a lone continuation byte at `pos`).
  if pos >= line.len:
    return pos + 1
  let np = nextRunePos(line, pos)
  if np > pos:
    return np
  var p = pos + 1
  while p < line.len and (line[p].uint8 and 0xC0'u8) == 0x80'u8:
    inc p
  p

proc addToken(
    tokens: var seq[Token], startIndex, endIndex: int, scopes: sink seq[ScopeName]
) {.inline.} =
  ## Append a token, dropping zero-width spans. Zero-width matches
  ## (lookarounds, `b*` matching nothing) would otherwise produce
  ## `startIndex == endIndex` tokens that consumers must filter out.
  ##
  ## `scopes` is taken as `sink` so a caller that has built a fresh
  ## `var scopes = baseScopes; scopes.add rule.name` can have its
  ## local seq moved into `Token.scopes` instead of copied. Callers
  ## that still want to reuse their `scopes` afterwards should pass
  ## a copy explicitly.
  if startIndex < endIndex:
    tokens.add Token(startIndex: startIndex, endIndex: endIndex, scopes: scopes)

proc initialStack*(g: Grammar, reg: Registry = nil): StackElement =
  ## Build the initial stack for tokenizing a document using grammar `g`.
  ## The root element contributes `g.scopeName` as the document-wide scope.
  ## Passing `reg` enables cross-grammar injection discovery during
  ## tokenisation (grammars registered there with an `injectionSelector`
  ## matching the active scopes contribute rules into the search).
  StackElement(parent: nil, grammar: g, contentName: g.scopeName, registry: reg)

proc fullScopes*(s: StackElement): seq[ScopeName] =
  ## Materialise the full scope chain of a stack, ordered root to leaf.
  ## The root element contributes `contentName` (the grammar's own
  ## `scopeName`). Pushed elements contribute `rule.name` followed by
  ## `rule.contentName`. Empty entries are skipped.
  ##
  ## Result is memoised on the stack element. Stack elements are
  ## immutable once constructed (the tokenizer only ever builds a new
  ## element on push, never mutates an existing one), so a populated
  ## cache is valid for the element's lifetime.
  if s == nil:
    return @[]
  if s.scopesComputed:
    return s.cachedScopes
  var acc = fullScopes(s.parent)
  if s.rule != nil:
    if s.rule.name.len > 0:
      acc.add s.rule.name
    if s.rule.contentName.len > 0:
      acc.add s.rule.contentName
  elif s.contentName.len > 0:
    acc.add s.contentName
  s.cachedScopes = acc
  s.scopesComputed = true
  acc

proc scopesWithRuleName(s: StackElement, rule: Rule): seq[ScopeName] =
  ## Return `fullScopes(s) & rule.name`, cached per `(s, rule)` pair.
  ## Rules that match repeatedly from the same stack frame (e.g. a
  ## keyword fired 20 times on a single line) thus build the combined
  ## scope seq once — subsequent emits reuse the cached seq by
  ## refcount bump, avoiding the `var scopes = baseScopes; scopes.add
  ## rule.name` COW that otherwise allocates per match.
  if rule.name.len == 0:
    return fullScopes(s)
  if s.ruleScopeCache.hasKey(rule):
    return s.ruleScopeCache[rule]
  result = fullScopes(s)
  result.add rule.name
  s.ruleScopeCache[rule] = result

proc stackEquals*(a, b: StackElement): bool =
  ## Structural equality of two rule stacks. Returns true when `a` and
  ## `b` represent the same open-block state, regardless of whether they
  ## are the same `ref` instance. Walks parent chains and compares, at
  ## each node: `grammar` ref identity, `rule` ref identity,
  ## `contentName` (root-only), and `terminatorSource` (pushed-only —
  ## distinguishes pushes of the same rule with different backref
  ## terminators). `registry` is document-global and not compared.
  ## Mutable caches on `Rule` (`resolvedTerminatorCache`,
  ## `patternExpansionCache`) are never touched.
  ##
  ## This is the primitive that drives incremental re-tokenization: an
  ## editor can stop re-tokenizing once a freshly computed end-of-line
  ## stack equals the previously stored one, because subsequent lines
  ## are then provably unchanged.
  if a == b:
    return true
  if a.isNil or b.isNil:
    return false
  if a.grammar != b.grammar:
    return false
  if a.rule != b.rule:
    return false
  if a.rule == nil:
    if a.contentName != b.contentName:
      return false
  else:
    if a.terminatorSource != b.terminatorSource:
      return false
  stackEquals(a.parent, b.parent)

proc tokenizeRange(
  line: string,
  startPos, endPos: int,
  rules: seq[Rule],
  selfG, baseG: Grammar,
  baseScopes: seq[ScopeName],
  tokens: var seq[Token],
  visitedRules: openArray[Rule],
)

proc scopesAt(
    entries: seq[CaptureEntry], activeStack: seq[int], baseScopes: seq[ScopeName]
): tuple[scopes: seq[ScopeName], innermost: int] =
  ## Materialise the scope stack for a run in `emitSpanWithCaptures`.
  ## `activeStack` holds indices into `entries`, ordered outer→inner.
  ## `innermost` is the deepest entry that carries its own `patterns`
  ## (or -1 when none does) — callers use it to decide whether to
  ## recurse into `tokenizeRange`.
  result.scopes = baseScopes
  result.innermost = -1
  for idx in activeStack:
    if entries[idx].name.len > 0:
      result.scopes.add entries[idx].name
    if entries[idx].patterns.len > 0:
      result.innermost = idx

proc emitSpanWithCaptures(
    tokens: var seq[Token],
    captures: Table[int, Capture],
    match: Match,
    baseScopes: seq[ScopeName],
    line: string,
    selfG, baseG: Grammar,
    visitedRules: openArray[Rule],
) =
  ## Emit tokens for one regex match, honouring capture-group scopes.
  ##
  ## A capture whose span contains another capture's span contributes its
  ## scope to the inner one (vscode-textmate nested-capture inheritance).
  ## Captures that carry their own `patterns` recursively tokenise their
  ## span via `tokenizeRange` — the capture's own `name` (if any) is
  ## layered under whatever the nested patterns emit.
  ##
  ## `visitedRules` lists rule ids whose captures are already being
  ## processed further up the call chain. `tokenizeRange` filters these
  ## out of its candidate set so a capture's `$self`/`$base` include
  ## cannot re-enter the enclosing rule and loop forever. The typical
  ## depth is 1–3, so an `openArray` + linear scan beats a `HashSet`
  ## (the latter allocated a fresh Table per emission).
  let fullSpan = match.boundaries[0]

  var entries: seq[CaptureEntry] = @[]
  for groupIdx, cap in captures.pairs:
    if groupIdx < 0 or groupIdx >= match.boundaries.len:
      continue
    let s =
      if groupIdx == 0:
        fullSpan
      else:
        match.boundaries[groupIdx]
    if s.a < 0 or s.a == s.b:
      continue
    entries.add CaptureEntry(
      span: s, groupIdx: groupIdx, name: cap.name, patterns: cap.patterns
    )

  # Deterministic order: outer spans first (earlier start, later end),
  # then smaller group index as a stable tiebreak.
  entries.sort do(a, b: CaptureEntry) -> int:
    result = cmp(a.span.a, b.span.a)
    if result != 0:
      return
    result = cmp(b.span.b, a.span.b)
    if result != 0:
      return
    result = cmp(a.groupIdx, b.groupIdx)

  # Segment sweep: at each position, the active scope stack is the
  # captures whose spans cover it, ordered outer→inner. Emit a token per
  # maximal run of identical scope stacks. Within a run where the
  # innermost capture has `patterns`, delegate to `tokenizeRange` so
  # nested rules can further refine the scopes.
  var stack: seq[int] = @[] # indexes into `entries`, sorted outer→inner
  var cursor = fullSpan.a
  var nextEntry = 0

  while cursor < fullSpan.b:
    # Pop entries whose span has ended.
    while stack.len > 0 and entries[stack[^1]].span.b <= cursor:
      stack.setLen(stack.len - 1)
    # Push entries starting at or before cursor (outer ones may have been
    # skipped earlier because they started at the very same position).
    while nextEntry < entries.len and entries[nextEntry].span.a <= cursor:
      let e = entries[nextEntry]
      if e.span.b > cursor:
        stack.add nextEntry
      inc nextEntry
    # Determine the run's end: the nearest of (next-start, top-of-stack end, fullSpan.b).
    var runEnd = fullSpan.b
    if stack.len > 0:
      for idx in stack:
        if entries[idx].span.b < runEnd:
          runEnd = entries[idx].span.b
    if nextEntry < entries.len and entries[nextEntry].span.a < runEnd:
      runEnd = entries[nextEntry].span.a
    # Invariant: stack entries have `span.b > cursor` (pop loop) and any
    # unpushed entry has `span.a > cursor` (push loop). Hence runEnd
    # strictly exceeds cursor, so every iteration consumes at least one
    # byte of `[fullSpan.a, fullSpan.b)`.
    doAssert runEnd > cursor, "emitSpanWithCaptures: runEnd invariant violated"
    let info = scopesAt(entries, stack, baseScopes)
    if info.innermost >= 0:
      let cap = entries[info.innermost]
      var capScopes = baseScopes
      for idx in stack:
        if entries[idx].name.len > 0:
          capScopes.add entries[idx].name
      tokenizeRange(
        line, cursor, runEnd, cap.patterns, selfG, baseG, capScopes, tokens,
        visitedRules,
      )
    else:
      addToken(tokens, cursor, runEnd, info.scopes)
    cursor = runEnd

proc regexEscape(s: string): string =
  # Allowlist approach: escape anything that is not a bare word character.
  # This is safe in any regex context (including inside `[...]`, where
  # `-` and `^` have meaning) at the cost of extra `\` before harmless
  # punctuation.
  result = newStringOfCap(s.len)
  for c in s:
    if c notin {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '_'}:
      result.add '\\'
    result.add c

proc substituteBackrefs(
    pattern: string, beginMatch: Match, line: string, beginRegex: Regex
): string =
  ## Replace `\1`..`\99` and `\k<name>` in `pattern` with the regex-escaped
  ## text of the corresponding begin capture. Unknown / non-participating
  ## groups expand to the empty string. Other escapes (`\\.`, `\\w`, …) are
  ## preserved verbatim.
  result = newStringOfCap(pattern.len)
  var i = 0
  while i < pattern.len:
    let c = pattern[i]
    if c == '\\' and i + 1 < pattern.len:
      let nxt = pattern[i + 1]
      if nxt in {'1' .. '9'}:
        var n = ord(nxt) - ord('0')
        var j = i + 2
        if j < pattern.len and pattern[j] in {'0' .. '9'}:
          let cand = n * 10 + (ord(pattern[j]) - ord('0'))
          if cand < beginMatch.boundaries.len:
            n = cand
            inc j
        let cap = captureText(beginMatch, n, line)
        if cap.isSome:
          result.add regexEscape(cap.get)
        i = j
        continue
      elif nxt == 'k' and i + 2 < pattern.len and pattern[i + 2] == '<':
        var j = i + 3
        var name = ""
        while j < pattern.len and pattern[j] != '>':
          name.add pattern[j]
          inc j
        if j < pattern.len and pattern[j] == '>':
          let idx = captureIndex(beginRegex, name)
          if idx >= 1:
            let cap = captureText(beginMatch, idx, line)
            if cap.isSome:
              result.add regexEscape(cap.get)
          i = j + 1
          continue
        result.add c
        result.add nxt
        i += 2
        continue
      else:
        result.add c
        result.add nxt
        i += 2
        continue
    result.add c
    inc i

proc resolveTerminatorRegex(
    rule: Rule, beginMatch: Match, line: string
): tuple[regex: Regex, source: string] =
  if not rule.terminatorHasBackrefs:
    return (rule.terminatorRegex, rule.terminatorPattern)
  let resolved =
    substituteBackrefs(rule.terminatorPattern, beginMatch, line, rule.beginRegex)
  # Phase 6: memoise the compiled regex per final substituted pattern.
  # Common heredoc-like grammars re-use the same delimiter across many
  # begin matches on one line (and across lines); caching saves a fresh
  # `re(...)` parse/compile on each push. Failures are never cached so a
  # later retry still surfaces the error.
  if not rule.resolvedTerminatorCache.hasKey(resolved):
    let compiled =
      try:
        re(resolved)
      except CatchableError as e:
        raise newException(
          GrammarError,
          "failed to compile resolved terminator pattern '" & resolved & "': " & e.msg,
        )
    rule.resolvedTerminatorCache[resolved] = compiled
  (rule.resolvedTerminatorCache[resolved], resolved)

proc baseGrammar(s: StackElement): Grammar =
  ## Return the grammar at the bottom of the stack. This is the "root"
  ## grammar in the sense of `$base` include expansion: the grammar the
  ## top-level `tokenizeLine` call started with, regardless of any
  ## cross-grammar includes lower down.
  var cur = s
  while cur.parent != nil:
    cur = cur.parent
  cur.grammar

proc rootRegistry(s: StackElement): Registry =
  ## Retrieve the registry stashed on the root stack element (if any).
  ## Root-only: intermediate elements do not carry a registry.
  var cur = s
  while cur.parent != nil:
    cur = cur.parent
  cur.registry

proc hasAnyInjectionSource(selfG: Grammar, reg: Registry): bool {.inline.} =
  ## Fast-path check: returns true when either the active grammar has
  ## its own injections or the registry has any grammar with a
  ## cross-grammar `injectionSelector`. Lets the happy path skip the
  ## scope-selector evaluation for grammars without injections.
  if selfG != nil and selfG.injections.len > 0:
    return true
  if reg != nil:
    for _, og in reg.grammars.pairs:
      if og == selfG:
        continue
      if og.hasInjectionSelector:
        return true
  false

proc expandRulesImpl(
  rules: seq[Rule],
  selfG: Grammar,
  baseG: Grammar,
  visited: var HashSet[RuleId],
  acc: var seq[ResolvedRule],
)

proc expandInclude(
    r: Rule,
    selfG: Grammar,
    baseG: Grammar,
    visited: var HashSet[RuleId],
    acc: var seq[ResolvedRule],
) =
  ## Dispatch one `rkInclude` rule to its target(s). Unresolved targets
  ## (missing scope, missing repo key, nil `$base`) contribute nothing.
  case r.includeKind
  of ikSelf:
    let target = r.resolvedGrammar
    if target != nil:
      expandRulesImpl(target.rootRules, target, baseG, visited, acc)
  of ikBase:
    if baseG != nil:
      expandRulesImpl(baseG.rootRules, baseG, baseG, visited, acc)
  of ikRepo:
    if r.resolvedRule != nil:
      case r.resolvedRule.kind
      of rkMatch, rkBeginEnd, rkBeginWhile:
        acc.add (rule: r.resolvedRule, grammar: selfG)
      of rkInclude:
        expandRulesImpl(@[r.resolvedRule], selfG, baseG, visited, acc)
  of ikGrammar:
    let target = r.resolvedGrammar
    if target != nil:
      expandRulesImpl(target.rootRules, target, baseG, visited, acc)
  of ikGrammarRepo:
    if r.resolvedRule != nil:
      # Invariant: `tryResolveInclude` only sets `resolvedRule` after
      # first binding `resolvedGrammar`, so the latter is non-nil here.
      let target = r.resolvedGrammar
      case r.resolvedRule.kind
      of rkMatch, rkBeginEnd, rkBeginWhile:
        acc.add (rule: r.resolvedRule, grammar: target)
      of rkInclude:
        expandRulesImpl(@[r.resolvedRule], target, baseG, visited, acc)
  of ikInvalid:
    discard

proc expandRulesImpl(
    rules: seq[Rule],
    selfG: Grammar,
    baseG: Grammar,
    visited: var HashSet[RuleId],
    acc: var seq[ResolvedRule],
) =
  for r in rules:
    case r.kind
    of rkMatch, rkBeginEnd, rkBeginWhile:
      acc.add (rule: r, grammar: selfG)
    of rkInclude:
      # Path-scoped cycle guard. We `excl` after descending so the same
      # `rkInclude` appearing at multiple sibling positions each gets its
      # own expansion — TextMate treats include graphs as DAGs, and the
      # guard only breaks true cycles, not DAG fan-in.
      if r.id in visited:
        continue
      visited.incl r.id
      expandInclude(r, selfG, baseG, visited, acc)
      visited.excl r.id

proc expandRules(rules: seq[Rule], selfG: Grammar, baseG: Grammar): seq[ResolvedRule] =
  ## Flatten a rule list, replacing every `rkInclude` with the rules it
  ## targets (recursively, with path-scoped cycle detection). Pure — not
  ## memoised. Repeated top-level scans of `selfG.rootRules` should use
  ## `expandRootRules`; sub-list expansion (Phase 4) will reuse this
  ## uncached entry point.
  if rules.len == 0:
    return @[]
  var visited = initHashSet[RuleId]()
  expandRulesImpl(rules, selfG, baseG, visited, result)

proc expandRootRules(selfG: Grammar, baseG: Grammar): seq[ResolvedRule] =
  ## Cached wrapper around `expandRules` specialised for
  ## `selfG.rootRules`. Memoises on `selfG.expansionCache[baseScope]`;
  ## the cache is cleared by `addGrammar` when a cross-grammar link
  ## newly resolves, so stale entries never outlive a link change.
  ##
  ## Always returns a fresh read from the cache so the cache value
  ## (not a moved-from local) is what flows out — `Table.[]=` `sink`s
  ## its argument under ARC/ORC, which would otherwise leave the local
  ## empty.
  if selfG == nil or selfG.rootRules.len == 0:
    return @[]
  let baseScope = if baseG != nil: baseG.scopeName else: ""
  if not selfG.expansionCache.hasKey(baseScope):
    selfG.expansionCache[baseScope] = expandRules(selfG.rootRules, selfG, baseG)
  selfG.expansionCache[baseScope]

proc scannerSearchRule(
    scanner: var LineScanner, line: string, pos: int, rule: Rule
): Match =
  ## Memoised per-line `search` dispatch. For a given line, each
  ## `rule` is searched at most once per monotonically-advancing
  ## `pos`: when the cached leftmost match still starts at or after
  ## `pos`, it is reused; when a prior search already determined the
  ## rule has no match in the line (relative to a prior `pos`), the
  ## miss is reused. Only `rkMatch` / `rkBeginEnd` / `rkBeginWhile`
  ## contribute a scanner; other kinds return an empty `Match()`.
  doAssert scanner.lineLen == line.len,
    "LineScanner reused across different line instances"
  case rule.kind
  of rkMatch, rkBeginEnd, rkBeginWhile:
    discard
  else:
    return Match()
  if scanner.entries.hasKey(rule):
    let e = scanner.entries[rule]
    if e.isMiss and e.queryPos <= pos:
      return Match()
    if e.match.found and e.match.boundaries[0].a >= pos:
      return e.match
  let regex = if rule.kind == rkMatch: rule.matchRegex else: rule.beginRegex
  var m: Match
  discard searchIntoCtx(scanner.ctx, line, regex, m, start = pos)
  scanner.entries[rule] = ScannerEntry(match: m, queryPos: pos, isMiss: not m.found)
  m

proc findNextMatchIn(
    line: string, pos: int, expanded: seq[ResolvedRule], scanner: var LineScanner
): tuple[rule: Rule, match: Match, grammar: Grammar] =
  ## Leftmost-wins search across an already-expanded rule list,
  ## considering only rule kinds that contribute a scanner (rkMatch,
  ## rkBeginEnd). Ties (same start position) go to the earlier rule by
  ## list order. The matched rule's owning grammar is returned so
  ## begin/end pushes carry the right grammar for later `$self`
  ## expansion.
  for entry in expanded:
    let rule = entry.rule
    if rule.kind notin {rkMatch, rkBeginEnd, rkBeginWhile}:
      continue
    let m = scannerSearchRule(scanner, line, pos, rule)
    if not m.found:
      continue
    if result.rule.isNil or m.boundaries[0].a < result.match.boundaries[0].a:
      result.rule = rule
      result.match = m
      result.grammar = entry.grammar

proc injectionPriority(sp: SelectorPriority): int {.inline.} =
  case sp
  of spL: 1
  of spDefault: -1
  of spR: -2

proc collectInjections(
    scopes: openArray[ScopeName], selfG: Grammar, reg: Registry
): seq[PrioritizedRule] =
  ## Gather every injection rule whose selector matches `scopes`. Covers
  ## the active grammar's own `injections` table plus any registered
  ## grammar whose `injectionSelector` matches (cross-grammar).
  if selfG != nil:
    for inj in selfG.injections:
      if matches(inj.selector, scopes):
        let pr = injectionPriority(inj.priority)
        for r in inj.rules:
          result.add (rule: r, grammar: selfG, priority: pr)
  if reg != nil:
    for _, og in reg.grammars.pairs:
      if og == selfG:
        continue
      if not og.hasInjectionSelector:
        continue
      if matches(og.injectionSelector, scopes):
        let pr = injectionPriority(og.injectionSelector.priority)
        for r in og.rootRules:
          if r.kind in {rkMatch, rkBeginEnd, rkBeginWhile}:
            result.add (rule: r, grammar: og, priority: pr)

proc findNextMatchEffective(
    line: string,
    pos: int,
    base: seq[ResolvedRule],
    injections: seq[PrioritizedRule],
    scanner: var LineScanner,
): tuple[rule: Rule, match: Match, grammar: Grammar] =
  ## Leftmost-wins with priority-aware tie-breaking. Base rules have
  ## priority 0; injection rules carry `+1` (L-priority), `-1`
  ## (default-priority), or `-2` (R-priority). Within the same
  ## priority, earlier entries win.
  var bestStart = high(int)
  var bestPriority = low(int)
  for entry in base:
    let rule = entry.rule
    if rule.kind notin {rkMatch, rkBeginEnd, rkBeginWhile}:
      continue
    let m = scannerSearchRule(scanner, line, pos, rule)
    if not m.found:
      continue
    let startIdx = m.boundaries[0].a
    const pr = 0
    if startIdx < bestStart or (startIdx == bestStart and pr > bestPriority):
      bestStart = startIdx
      bestPriority = pr
      result.rule = rule
      result.match = m
      result.grammar = entry.grammar
  for entry in injections:
    let rule = entry.rule
    if rule.kind notin {rkMatch, rkBeginEnd, rkBeginWhile}:
      continue
    let m = scannerSearchRule(scanner, line, pos, rule)
    if not m.found:
      continue
    let startIdx = m.boundaries[0].a
    let pr = entry.priority
    if startIdx < bestStart or (startIdx == bestStart and pr > bestPriority):
      bestStart = startIdx
      bestPriority = pr
      result.rule = rule
      result.match = m
      result.grammar = entry.grammar

proc expandRulePatterns(rule: Rule, selfG, baseG: Grammar): seq[ResolvedRule] =
  ## Cached wrapper around `expandRules` for an `rkBeginEnd` rule's
  ## `patterns` sub-list. Keyed by the base grammar's `scopeName` so a
  ## rule reused with different `$base` contexts does not collide. The
  ## cache is cleared by `registry.addGrammar` when a cross-grammar link
  ## is newly satisfied. See `expandRootRules` for the `Table.[]=` sink
  ## pitfall that motivates returning the cache value rather than the
  ## just-computed local.
  if rule.patterns.len == 0:
    return @[]
  let baseScope = if baseG != nil: baseG.scopeName else: ""
  if not rule.patternExpansionCache.hasKey(baseScope):
    rule.patternExpansionCache[baseScope] = expandRules(rule.patterns, selfG, baseG)
  rule.patternExpansionCache[baseScope]

proc tokenizeRange(
    line: string,
    startPos, endPos: int,
    rules: seq[Rule],
    selfG, baseG: Grammar,
    baseScopes: seq[ScopeName],
    tokens: var seq[Token],
    visitedRules: openArray[Rule],
) =
  ## Bounded match-only tokenisation over `[startPos, endPos)`. Used for
  ## capture groups that carry their own `patterns`. Phase 4 only fires
  ## `rkMatch` rules here — `rkBeginEnd` inside a capture's patterns is
  ## silently skipped (deferred to Phase 5); any matched span extending
  ## past `endPos` is also skipped so tokens never leak out of the
  ## bounded range. Emits at least one token covering the whole range
  ## so callers can rely on `[startPos, endPos)` being fully covered.
  ##
  ## `visitedRules` carries the ids of rules whose captures are already
  ## being processed further up the call chain; matching against them is
  ## suppressed so a capture's `$self` / `$base` include cannot re-enter
  ## the enclosing rule and loop forever.
  if startPos >= endPos:
    return
  if rules.len == 0:
    addToken(tokens, startPos, endPos, baseScopes)
    return
  var expanded = expandRules(rules, selfG, baseG)
  var matchOnly: seq[ResolvedRule] = @[]
  for entry in expanded:
    # TODO(phase5): rkBeginEnd inside a capture's `patterns` is silently
    # dropped here. Supporting it requires deciding how the capture's
    # bounded `[startPos, endPos)` interacts with a begin/end push that
    # could span past the capture (and possibly past the line). Pinned
    # by `tcapture_patterns.nim`'s "rkBeginEnd inside capture patterns
    # is skipped" test so the change-point is forced.
    if entry.rule.kind == rkMatch and entry.rule notin visitedRules:
      matchOnly.add entry
  if matchOnly.len == 0:
    addToken(tokens, startPos, endPos, baseScopes)
    return
  # `tokenizeRange` uses its own scanner instead of sharing one with the
  # caller: its `pos` advances monotonically only *within* this call,
  # `visitedRules` differs at each recursion depth, and capture-bounded
  # matches are filtered (e.g. `span.b > endPos`). A shared scanner
  # would risk returning a cached match that is outside this range or
  # that came from a prior visitedRules snapshot.
  #
  # The `ctx` itself is shared with the caller via `getMatchContext()`
  # — safe because reni's `Match` is `object { found: bool, boundaries:
  # seq[Span] }` and owns its `boundaries` seq. Each `searchIntoCtx`
  # writes a fresh result into its `var Match` output; the ctx only
  # holds resettable scratch (`captures` / `groupRecursionDepth` /
  # `captureStacks`). So a nested `searchIntoCtx` here does not
  # invalidate any `Match` value the caller is still holding.
  var localScanner = LineScanner(lineLen: line.len, ctx: getMatchContext())
  var pos = startPos
  while pos < endPos:
    let next = findNextMatchIn(line, pos, matchOnly, localScanner)
    if next.rule.isNil:
      addToken(tokens, pos, endPos, baseScopes)
      return
    let span = next.match.boundaries[0]
    if span.a >= endPos:
      # Leftmost in-range candidate starts beyond the bounded region.
      # Nothing inside `[pos, endPos)` will match anymore.
      addToken(tokens, pos, endPos, baseScopes)
      return
    if span.b > endPos:
      # Match starts inside the region but spills past it. Step just past
      # its start (UTF-8 safe) so the next search can still find later
      # in-range candidates. Everything we pass over in the meantime is
      # emitted as one gap token carrying `baseScopes`.
      let stepTo = safeAdvance(line, span.a)
      if stepTo >= endPos:
        addToken(tokens, pos, endPos, baseScopes)
        return
      addToken(tokens, pos, stepTo, baseScopes)
      pos = stepTo
      continue
    if span.a > pos:
      addToken(tokens, pos, span.a, baseScopes)
    var scopes = baseScopes
    if next.rule.name.len > 0:
      scopes.add next.rule.name
    if next.rule.captures.len == 0:
      addToken(tokens, span.a, span.b, scopes)
    else:
      var subVisited = newSeqOfCap[Rule](visitedRules.len + 1)
      for r in visitedRules:
        subVisited.add r
      subVisited.add next.rule
      emitSpanWithCaptures(
        tokens, next.rule.captures, next.match, scopes, line, next.grammar, baseG,
        subVisited,
      )
    pos =
      if span.b > pos:
        span.b
      else:
        safeAdvance(line, pos)
    if pos > endPos:
      pos = endPos

proc tokenizeLine*(line: string, stack: StackElement): LineTokens =
  ## Tokenise a single line of text using the current stack state.
  ##
  ## Returns a `LineTokens` whose `tokens` cover `line` left-to-right
  ## with no overlap, and whose `ruleStack` should be threaded into the
  ## next call when tokenising a multi-line document. Open `begin`/`end`
  ## constructs carry across newlines via `ruleStack`.
  ##
  var curStack = stack
  var pos = 0
  # `baseGrammar` walks the stack to its root. The root never changes
  # within a single `tokenizeLine` call (begin/end pushes/pops only
  # touch the top), so compute it once.
  let baseG = baseGrammar(curStack)
  let reg = rootRegistry(curStack)

  # Phase 6: per-line match-position cache. `pos` advances monotonically
  # through the main loop (including across begin/end push/pop), so a
  # cached leftmost-match starting at `pos_cached >= pos_current` is
  # always correct to reuse. The scanner covers `findNextMatch*` calls;
  # while-preamble and begin/end terminator searches bypass it because
  # their regexes live on the stack element, not the rule.
  var scanner = LineScanner(lineLen: line.len, ctx: getMatchContext())

  # Cached `expandRootRules(curStack.grammar, baseG)`. The cache is
  # consulted only when `curStack.rule == nil` (root frame) — the
  # begin/end branch uses `expandRulePatterns` instead. While push/pop
  # transitions never enter the root branch with a different grammar
  # within one `tokenizeLine` call (every push lands on `rkBeginEnd` /
  # `rkBeginWhile` and the begin/end branch handles those frames), the
  # ref-equality guard makes the invariant local: the cache stays
  # valid as long as the grammar at the top of the stack is unchanged,
  # and any future relaxation of the "root frame only" property will
  # invalidate correctly. Eliminates the per-iteration
  # `expansionCache.hasKey(baseScope)` string-hash lookup that used to
  # dominate the perf profile.
  var rootRulesGrammar: Grammar = nil
  var rootRulesCached: seq[ResolvedRule]
  template ensureRootRules() =
    if rootRulesGrammar != curStack.grammar:
      rootRulesCached = expandRootRules(curStack.grammar, baseG)
      rootRulesGrammar = curStack.grammar

  # Cached `expandRulePatterns(curStack.rule, curStack.grammar, baseG)`.
  # Within one begin/end frame, `curStack.rule` and `curStack.grammar`
  # are immutable (push/pop replaces the whole frame), so the cache
  # stays valid as long as `curStack.rule` is unchanged. Avoids
  # re-walking the `expandRulePatterns` cache lookup on every iteration
  # of the begin/end branch's main loop.
  var nestedRulesRule: Rule = nil
  var nestedRulesCached: seq[ResolvedRule]
  template ensureNestedRules() =
    if nestedRulesRule != curStack.rule:
      if curStack.rule != nil and curStack.rule.patterns.len > 0:
        nestedRulesCached = expandRulePatterns(curStack.rule, curStack.grammar, baseG)
      else:
        nestedRulesCached.setLen(0)
      nestedRulesRule = curStack.rule

  # Injection evaluation caches. `hasInj` and `cachedInjections` depend
  # only on `curStack.grammar` and `fullScopes(curStack)`, both of which
  # change only on push/pop. `injSourcesValid` is flipped to false at
  # every such transition; the helper recomputes lazily on next use.
  var injSourcesValid = false
  var hasInj = false
  var cachedInjections: seq[PrioritizedRule]
  template ensureInjectionCache() =
    if not injSourcesValid:
      hasInj = hasAnyInjectionSource(curStack.grammar, reg)
      if hasInj:
        cachedInjections =
          collectInjections(fullScopes(curStack), curStack.grammar, reg)
      else:
        cachedInjections.setLen(0)
      injSourcesValid = true

  # While-rule preamble: pop every `rkBeginWhile` frame on top of the
  # stack whose `while` pattern does not match at column 0. Runs once
  # per `tokenizeLine` call — on the line where `begin` fired the push
  # happens later in this call and is never seen here. When a while
  # succeeds, emit the match's span with the block's `name` scope and
  # advance `pos` past it so the main loop continues under the block.
  while curStack.rule != nil and curStack.rule.kind == rkBeginWhile:
    let rule = curStack.rule
    let wre = curStack.terminatorRegex
    var m: Match
    discard searchIntoCtx(scanner.ctx, line, wre, m, start = 0)
    if (not m.found) or m.boundaries[0].a != 0:
      curStack = curStack.parent
      injSourcesValid = false
      continue
    let span = m.boundaries[0]
    let whileBaseScopes = scopesWithRuleName(curStack.parent, rule)
    if rule.terminatorCaptures.len == 0:
      addToken(result.tokens, 0, span.b, whileBaseScopes)
    else:
      emitSpanWithCaptures(
        result.tokens,
        rule.terminatorCaptures,
        m,
        whileBaseScopes,
        line,
        curStack.grammar,
        baseG,
        [rule],
      )
    # Zero-width `while` (e.g. a lookahead like `(?=>)`) leaves `span.b`
    # at 0. Advance one rune pragmatically so the main loop is not stuck
    # re-running the same lookahead forever.
    pos =
      if span.b > 0:
        span.b
      else:
        safeAdvance(line, 0)
    break

  while pos < line.len:
    # `baseScopes` is the full scope chain for `curStack` at the start of
    # this iteration. Every emit within one iteration uses it (either
    # directly for gap tokens, or as the base that rule/capture scopes
    # are layered on top of). `curStack` only changes on push/pop at the
    # very end of an iteration, so re-reading baseScopes here after
    # `continue` is both correct and cheap (cached on `StackElement`).
    let baseScopes = fullScopes(curStack)

    if curStack.rule != nil and curStack.rule.kind in {rkBeginEnd, rkBeginWhile}:
      let rule = curStack.rule
      let hasTerminator = rule.kind == rkBeginEnd
      var endMatch: Match
      if hasTerminator:
        discard searchIntoCtx(
          scanner.ctx, line, curStack.terminatorRegex, endMatch, start = pos
        )
      let endStart =
        if hasTerminator and endMatch.found:
          endMatch.boundaries[0].a
        else:
          high(int)
      # Look for a nested pattern match that beats the end pattern.
      # Tie at the same start position goes to end (Phase 5 will honour
      # `applyEndPatternLast` to optionally flip this).
      var nested: tuple[rule: Rule, match: Match, grammar: Grammar]
      ensureNestedRules()
      ensureInjectionCache()
      if hasInj:
        if nestedRulesCached.len > 0 or cachedInjections.len > 0:
          nested = findNextMatchEffective(
            line, pos, nestedRulesCached, cachedInjections, scanner
          )
      elif nestedRulesCached.len > 0:
        nested = findNextMatchIn(line, pos, nestedRulesCached, scanner)
      let nestedFound = not nested.rule.isNil
      let nestedStart =
        if nestedFound:
          nested.match.boundaries[0].a
        else:
          high(int)

      if nestedFound and nestedStart < endStart:
        let nspan = nested.match.boundaries[0]
        addToken(result.tokens, pos, nspan.a, baseScopes)
        case nested.rule.kind
        of rkMatch:
          let scopes = scopesWithRuleName(curStack, nested.rule)
          if nested.rule.captures.len == 0:
            addToken(result.tokens, nspan.a, nspan.b, scopes)
          else:
            emitSpanWithCaptures(
              result.tokens,
              nested.rule.captures,
              nested.match,
              scopes,
              line,
              nested.grammar,
              baseG,
              [nested.rule],
            )
        of rkBeginEnd, rkBeginWhile:
          let beginBaseScopes = scopesWithRuleName(curStack, nested.rule)
          if nested.rule.beginCaptures.len == 0:
            addToken(result.tokens, nspan.a, nspan.b, beginBaseScopes)
          else:
            emitSpanWithCaptures(
              result.tokens,
              nested.rule.beginCaptures,
              nested.match,
              beginBaseScopes,
              line,
              nested.grammar,
              baseG,
              [nested.rule],
            )
          let term = resolveTerminatorRegex(nested.rule, nested.match, line)
          curStack = StackElement(
            parent: curStack,
            grammar: nested.grammar,
            rule: nested.rule,
            terminatorRegex: term.regex,
            terminatorSource: term.source,
          )
          injSourcesValid = false
        of rkInclude:
          # expandRules strips rkInclude entries; unreachable.
          discard
        pos =
          if nspan.b > pos:
            nspan.b
          else:
            safeAdvance(line, pos)
        continue

      if hasTerminator and endMatch.found:
        let span = endMatch.boundaries[0]
        addToken(result.tokens, pos, span.a, baseScopes)
        let endBaseScopes = scopesWithRuleName(curStack.parent, rule)
        if rule.terminatorCaptures.len == 0:
          addToken(result.tokens, span.a, span.b, endBaseScopes)
        else:
          emitSpanWithCaptures(
            result.tokens,
            rule.terminatorCaptures,
            endMatch,
            endBaseScopes,
            line,
            curStack.grammar,
            baseG,
            [rule],
          )
        curStack = curStack.parent
        injSourcesValid = false
        pos =
          if span.b > pos:
            span.b
          else:
            safeAdvance(line, pos)
      else:
        # No nested match and either no end pattern (rkBeginWhile) or
        # the end pattern did not hit: tokenise the rest of the line
        # under the block's scopes and carry the frame to the next line.
        addToken(result.tokens, pos, line.len, baseScopes)
        pos = line.len
      continue

    var next: tuple[rule: Rule, match: Match, grammar: Grammar]
    ensureInjectionCache()
    ensureRootRules()
    if hasInj:
      next =
        findNextMatchEffective(line, pos, rootRulesCached, cachedInjections, scanner)
    else:
      next = findNextMatchIn(line, pos, rootRulesCached, scanner)
    if next.rule.isNil:
      addToken(result.tokens, pos, line.len, baseScopes)
      break

    let span = next.match.boundaries[0]
    addToken(result.tokens, pos, span.a, baseScopes)

    case next.rule.kind
    of rkMatch:
      let scopes = scopesWithRuleName(curStack, next.rule)
      if next.rule.captures.len == 0:
        addToken(result.tokens, span.a, span.b, scopes)
      else:
        emitSpanWithCaptures(
          result.tokens,
          next.rule.captures,
          next.match,
          scopes,
          line,
          next.grammar,
          baseG,
          [next.rule],
        )
    of rkBeginEnd, rkBeginWhile:
      let beginBaseScopes = scopesWithRuleName(curStack, next.rule)
      if next.rule.beginCaptures.len == 0:
        addToken(result.tokens, span.a, span.b, beginBaseScopes)
      else:
        emitSpanWithCaptures(
          result.tokens,
          next.rule.beginCaptures,
          next.match,
          beginBaseScopes,
          line,
          next.grammar,
          baseG,
          [next.rule],
        )
      let term = resolveTerminatorRegex(next.rule, next.match, line)
      curStack = StackElement(
        parent: curStack,
        grammar: next.grammar,
        rule: next.rule,
        terminatorRegex: term.regex,
        terminatorSource: term.source,
      )
      injSourcesValid = false
    of rkInclude:
      # expandRules strips rkInclude entries; this branch is unreachable.
      discard

    pos =
      if span.b > pos:
        span.b
      else:
        safeAdvance(line, pos)

  result.ruleStack = curStack

proc newScopeIdMap*(): ScopeIdMap =
  ## Phase 7: construct an empty intern table. `byId[0]` is pre-populated
  ## with the empty-string sentinel so `ScopeId(0)` always lookups to "".
  ScopeIdMap(byName: initTable[ScopeName, ScopeId](), byId: @[ScopeName("")])

proc internScope*(m: ScopeIdMap, name: ScopeName): ScopeId =
  ## Return the stable id for `name`, assigning a fresh one on first
  ## sight. Ids start at 1 and increase monotonically; the map never
  ## forgets an id. The empty string is normalised to the `ScopeId(0)`
  ## sentinel and is not inserted into the map — real scope names from
  ## `Token.scopes` are never empty, so this guard only protects the
  ## sentinel from aliasing with a user-supplied "".
  if name.len == 0:
    return ScopeId(0)
  if m.byName.hasKey(name):
    return m.byName[name]
  let id = ScopeId(m.byId.len)
  m.byId.add(name)
  m.byName[name] = id
  id

proc lookupScope*(m: ScopeIdMap, id: ScopeId): ScopeName =
  ## Reverse lookup. Returns "" for the 0 sentinel or for ids not yet
  ## interned on this map.
  if id.int >= m.byId.len:
    return ""
  m.byId[id.int]

iterator tokenizeDocumentIter*(
    lines: openArray[string], stack: StackElement
): LineTokens =
  ## Phase 7: streaming form of `tokenizeDocument`. Each yielded
  ## `LineTokens` carries the updated stack in `ruleStack`; the final
  ## yielded element's `ruleStack` is the end-of-document stack. If
  ## `lines` is empty, nothing is yielded — callers that need to observe
  ## the stack in that case must fall back to the initial `stack`.
  var cur = stack
  for line in lines:
    let lt = tokenizeLine(line, cur)
    yield lt
    cur = lt.ruleStack

proc tokenizeDocument*(lines: openArray[string], stack: StackElement): seq[LineTokens] =
  ## Phase 7: tokenise every line in `lines`, threading `ruleStack`
  ## between calls. Equivalent to calling `tokenizeLine` in a loop and
  ## collecting results. The end-of-document stack is available as
  ## `result[^1].ruleStack`; if `lines` is empty, returns an empty seq
  ## and the caller's `stack` remains valid.
  result = newSeqOfCap[LineTokens](lines.len)
  for lt in tokenizeDocumentIter(lines, stack):
    result.add(lt)

proc toMetadataToken(t: Token, m: ScopeIdMap): MetadataToken {.inline.} =
  result.startIndex = t.startIndex
  result.endIndex = t.endIndex
  result.scopeIds = newSeqOfCap[ScopeId](t.scopes.len)
  for s in t.scopes:
    result.scopeIds.add internScope(m, s)
  result.metadata = DefaultMetadata

proc tokenizeLineMetadata*(
    line: string, stack: StackElement, map: ScopeIdMap
): MetadataLineTokens =
  ## Phase 7: numeric-scope variant of `tokenizeLine`. Internally calls
  ## `tokenizeLine` and projects each `Token.scopes` through `map`.
  ## `metadata` is `DefaultMetadata` today; reserved for future theme
  ## integration.
  let lt = tokenizeLine(line, stack)
  result.tokens = newSeqOfCap[MetadataToken](lt.tokens.len)
  for t in lt.tokens:
    result.tokens.add toMetadataToken(t, map)
  result.ruleStack = lt.ruleStack

iterator tokenizeDocumentMetadataIter*(
    lines: openArray[string], stack: StackElement, map: ScopeIdMap
): MetadataLineTokens =
  ## Phase 7: streaming metadata variant. See `tokenizeDocumentIter` for
  ## empty-input semantics.
  var cur = stack
  for line in lines:
    let mlt = tokenizeLineMetadata(line, cur, map)
    yield mlt
    cur = mlt.ruleStack

proc tokenizeDocumentMetadata*(
    lines: openArray[string], stack: StackElement, map: ScopeIdMap
): seq[MetadataLineTokens] =
  ## Phase 7: batch variant of `tokenizeLineMetadata`. Threads
  ## `ruleStack` across lines and reuses the same `map` for stable ids.
  result = newSeqOfCap[MetadataLineTokens](lines.len)
  for mlt in tokenizeDocumentMetadataIter(lines, stack, map):
    result.add(mlt)
