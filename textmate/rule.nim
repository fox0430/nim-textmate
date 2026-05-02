import std/[strutils, tables]

import pkg/reni

import ./[types, selector]

type ParsedInclude = object
  kind: IncludeKind
  scope: string
  repo: string

proc parseIncludeTarget*(raw: string): ParsedInclude =
  ## Parse an `include` target string into its structured form.
  ##
  ## Recognised forms:
  ## - `$self`                 -> `ikSelf`
  ## - `$base`                 -> `ikBase`
  ## - `#<name>`               -> `ikRepo(name)`
  ## - `<scope>`               -> `ikGrammar(scope)`
  ## - `<scope>#<name>`        -> `ikGrammarRepo(scope, name)`
  ##
  ## Empty strings, lone `#`, trailing-separator forms such as `scope#`,
  ## and unknown `$directive` values are reported as `ikInvalid` so the
  ## caller can surface them as a compile-time grammar error.
  if raw.len == 0:
    return ParsedInclude(kind: ikInvalid)
  if raw == "$self":
    return ParsedInclude(kind: ikSelf)
  if raw == "$base":
    return ParsedInclude(kind: ikBase)
  if raw[0] == '$':
    return ParsedInclude(kind: ikInvalid)
  if raw[0] == '#':
    let name = raw[1 .. ^1]
    if name.len == 0:
      return ParsedInclude(kind: ikInvalid)
    return ParsedInclude(kind: ikRepo, repo: name)
  let hashIdx = raw.find('#')
  if hashIdx < 0:
    return ParsedInclude(kind: ikGrammar, scope: raw)
  let scope = raw[0 ..< hashIdx]
  let name = raw[hashIdx + 1 .. ^1]
  if scope.len == 0 or name.len == 0:
    return ParsedInclude(kind: ikInvalid)
  ParsedInclude(kind: ikGrammarRepo, scope: scope, repo: name)

proc nextId(g: Grammar): RuleId {.inline.} =
  inc g.nextRuleId
  g.nextRuleId

proc compileRegex(pattern: string, role: string, field: string): Regex =
  try:
    re(pattern)
  except CatchableError as e:
    raise newException(
      GrammarError,
      "failed to compile " & role & " pattern '" & pattern & "' at " & field & ": " &
        e.msg,
    )

proc patternHasBackrefs*(pattern: string): bool =
  ## True when `pattern` contains a numeric (`\1`..`\99`) or named
  ## (`\k<name>`) backreference form. End patterns that contain these refer
  ## to captures from the matching `begin`, so they cannot be compiled until
  ## those captures are known.
  var i = 0
  while i < pattern.len:
    let c = pattern[i]
    if c == '\\' and i + 1 < pattern.len:
      let nxt = pattern[i + 1]
      if nxt in {'1' .. '9'}:
        return true
      if nxt == 'k' and i + 2 < pattern.len and pattern[i + 2] == '<':
        return true
      i += 2
    else:
      inc i
  false

proc compilePattern(raw: RawPattern, g: Grammar, field: string): Rule
proc compilePatternList(raws: seq[RawPattern], g: Grammar, field: string): seq[Rule]
proc compileCaptures(
  raw: OrderedTable[string, RawCapture], g: Grammar, field: string
): Table[int, Capture]

proc compilePattern(raw: RawPattern, g: Grammar, field: string): Rule =
  ## Compile one RawPattern into a Rule, or return nil if the pattern is
  ## empty / purely a grouping shell we do not support yet. `field` is
  ## the JSON path (e.g. `patterns[0].patterns[2]`) used in error
  ## messages so users can locate the offending pattern.
  let kinds =
    int(raw.match.len > 0) + int(raw.`include`.len > 0) + int(raw.begin.len > 0)
  if kinds > 1:
    raise newException(
      GrammarError,
      "pattern at '" & field & "' has more than one of 'match', 'include', 'begin' set",
    )

  if raw.match.len > 0:
    let regex = compileRegex(raw.match, "match", field & ".match")
    result = Rule(
      id: nextId(g),
      name: raw.name,
      kind: rkMatch,
      matchRegex: regex,
      captures: compileCaptures(raw.captures, g, field & ".captures"),
    )
  elif raw.`include`.len > 0:
    let parsed = parseIncludeTarget(raw.`include`)
    if parsed.kind == ikInvalid:
      raise newException(
        GrammarError, "invalid include target '" & raw.`include` & "' at " & field
      )
    result = Rule(
      id: nextId(g),
      name: raw.name,
      kind: rkInclude,
      includeTarget: raw.`include`,
      includeKind: parsed.kind,
      includeRepoName: parsed.repo,
      includeScope: parsed.scope,
    )
  elif raw.begin.len > 0:
    if raw.`end`.len > 0 and raw.`while`.len > 0:
      raise newException(
        GrammarError,
        "begin rule at '" & field & "' has both 'end' and 'while' set (pick one)",
      )
    if raw.`end`.len == 0 and raw.`while`.len == 0:
      raise newException(
        GrammarError,
        "begin rule at '" & field & "' is missing 'end' or 'while' pattern (begin='" &
          raw.begin & "')",
      )
    let beginRegex = compileRegex(raw.begin, "begin", field & ".begin")
    let isWhile = raw.`while`.len > 0
    let terminatorPattern = if isWhile: raw.`while` else: raw.`end`
    let terminatorRole = if isWhile: "while" else: "end"
    let terminatorField = field & "." & terminatorRole
    let hasBackrefs = patternHasBackrefs(terminatorPattern)
    var terminatorRegex: Regex
    if not hasBackrefs:
      # Safe to compile up front so grammar errors surface at compile time.
      # Patterns with backrefs depend on each begin match and are compiled
      # lazily by the tokenizer when the begin fires.
      terminatorRegex = compileRegex(terminatorPattern, terminatorRole, terminatorField)
    let terminatorCaptures =
      if isWhile:
        compileCaptures(raw.whileCaptures, g, field & ".whileCaptures")
      else:
        compileCaptures(raw.endCaptures, g, field & ".endCaptures")
    let beginCaptures = compileCaptures(raw.beginCaptures, g, field & ".beginCaptures")
    let nestedPatterns = compilePatternList(raw.patterns, g, field & ".patterns")
    if isWhile:
      result = Rule(
        id: nextId(g),
        name: raw.name,
        kind: rkBeginWhile,
        beginRegex: beginRegex,
        terminatorPattern: terminatorPattern,
        terminatorRegex: terminatorRegex,
        terminatorHasBackrefs: hasBackrefs,
        beginCaptures: beginCaptures,
        terminatorCaptures: terminatorCaptures,
        contentName: raw.contentName,
        patterns: nestedPatterns,
      )
    else:
      result = Rule(
        id: nextId(g),
        name: raw.name,
        kind: rkBeginEnd,
        beginRegex: beginRegex,
        terminatorPattern: terminatorPattern,
        terminatorRegex: terminatorRegex,
        terminatorHasBackrefs: hasBackrefs,
        beginCaptures: beginCaptures,
        terminatorCaptures: terminatorCaptures,
        contentName: raw.contentName,
        patterns: nestedPatterns,
      )
  elif raw.`while`.len > 0:
    raise newException(
      GrammarError, "pattern at '" & field & "' has 'while' without 'begin'"
    )
  else:
    result = nil

proc compilePatternList(raws: seq[RawPattern], g: Grammar, field: string): seq[Rule] =
  for i, raw in raws:
    let r = compilePattern(raw, g, field & "[" & $i & "]")
    if r != nil:
      result.add r

proc compileCaptures(
    raw: OrderedTable[string, RawCapture], g: Grammar, field: string
): Table[int, Capture] =
  for key, value in raw.pairs:
    var idx: int
    try:
      idx = parseInt(key)
    except ValueError:
      continue
    if idx < 0:
      continue
    let pats = compilePatternList(value.patterns, g, field & "." & key & ".patterns")
    if value.name.len == 0 and pats.len == 0:
      continue
    result[idx] = Capture(name: value.name, patterns: pats)

proc registerRule(g: Grammar, r: Rule) {.inline.} =
  g.ruleById[r.id] = r

proc collectIncludes(r: Rule, target: var seq[Rule]) =
  ## Walk a rule sub-tree, recording every `rkInclude` node encountered.
  ## Sub-patterns nested inside a `begin`/`end` rule and patterns attached
  ## to capture groups (`captures`, `beginCaptures`, `endCaptures`) are
  ## both walked so cross-grammar include linking reaches every rkInclude
  ## the tokenizer might later expand.
  case r.kind
  of rkMatch:
    for _, cap in r.captures.pairs:
      for sub in cap.patterns:
        collectIncludes(sub, target)
  of rkInclude:
    target.add r
  of rkBeginEnd, rkBeginWhile:
    for sub in r.patterns:
      collectIncludes(sub, target)
    for _, cap in r.beginCaptures.pairs:
      for sub in cap.patterns:
        collectIncludes(sub, target)
    for _, cap in r.terminatorCaptures.pairs:
      for sub in cap.patterns:
        collectIncludes(sub, target)

proc linkLocalIncludes(g: Grammar) =
  ## Resolve the two include kinds that need only the enclosing grammar:
  ## `$self` (to `g`) and `#name` (to `g.repository[name]`). Unknown repo
  ## names are a silent no-op so partial grammars still load; the
  ## expansion pass at tokenize time contributes nothing for such rules.
  ## Cross-grammar (`ikGrammar`, `ikGrammarRepo`) and `ikBase` are left
  ## for `addGrammar` / the tokenizer respectively.
  for r in g.includeRules:
    case r.includeKind
    of ikSelf:
      r.resolvedGrammar = g
    of ikRepo:
      r.resolvedGrammar = g
      if g.repository.hasKey(r.includeRepoName):
        r.resolvedRule = g.repository[r.includeRepoName]
    of ikBase, ikGrammar, ikGrammarRepo, ikInvalid:
      discard

proc compileGrammar*(raw: RawGrammar): Grammar =
  ## Compile a RawGrammar into the runtime Grammar used by the tokenizer.
  ## Match, begin/end, and include rules are all represented in the tree;
  ## `$self` and `#name` include targets are linked to their resolved
  ## rule here, while cross-grammar targets (`source.xxx`) are resolved
  ## later by `addGrammar`.
  ##
  ## Raises ``GrammarError`` if any pattern's regex fails to compile or
  ## if an `include` target is malformed (empty, lone `#`, unknown
  ## `$directive`, etc.).
  ##
  ## Each `Grammar` returned by `compileGrammar` is **thread-confined**:
  ## tokenise it from one thread only. For parallel tokenisation, call
  ## `compileGrammar` once per worker thread — `RawGrammar` is plain
  ## data and may be shared. The same restriction applies to a
  ## `Registry` and the grammars it owns.
  result = Grammar(scopeName: raw.scopeName)
  result.rootRules = compilePatternList(raw.patterns, result, "patterns")
  for key, value in raw.repository.pairs:
    let r = compilePattern(value, result, "repository." & key)
    if r != nil:
      result.repository[key] = r
  for key, value in raw.injections.pairs:
    let selectorExpr =
      try:
        parseSelector(key)
      except CatchableError as e:
        raise newException(
          GrammarError, "failed to parse injection selector '" & key & "': " & e.msg
        )
    let rules =
      compilePatternList(value.patterns, result, "injections[\"" & key & "\"].patterns")
    if rules.len > 0:
      result.injections.add CompiledInjection(
        selector: selectorExpr, rules: rules, priority: selectorExpr.priority
      )
  if raw.injectionSelector.len > 0:
    result.injectionSelector =
      try:
        parseSelector(raw.injectionSelector)
      except CatchableError as e:
        raise newException(
          GrammarError,
          "failed to parse injectionSelector '" & raw.injectionSelector & "': " & e.msg,
        )
    result.hasInjectionSelector = not result.injectionSelector.isEmpty
  if raw.firstLineMatch.len > 0:
    result.firstLineMatch =
      compileRegex(raw.firstLineMatch, "firstLineMatch", "firstLineMatch")
    result.hasFirstLineMatch = true
  for r in result.rootRules:
    registerRule(result, r)
  for _, r in result.repository.pairs:
    registerRule(result, r)
  for inj in result.injections:
    for r in inj.rules:
      registerRule(result, r)
  for r in result.rootRules:
    collectIncludes(r, result.includeRules)
  for _, r in result.repository.pairs:
    collectIncludes(r, result.includeRules)
  for inj in result.injections:
    for r in inj.rules:
      collectIncludes(r, result.includeRules)
  linkLocalIncludes(result)
