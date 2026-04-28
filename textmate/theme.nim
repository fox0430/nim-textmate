## Phase 7: TextMate / VSCode theme parser + resolver.
##
## `parseRawTheme` decodes a theme JSON into a `RawTheme` (no selector
## parsing yet), `compileTheme` produces a runtime `Theme` with each rule's
## scope selector pre-compiled, and `resolveTheme` matches a scope stack
## against the compiled rules to produce a `ThemeStyle`.
##
## The resolver follows vscode-textmate's semantics for field-level
## inheritance: each of `foreground`, `background`, and `fontStyle` is
## picked independently from the most-specific matching rule that sets
## that field; ties are broken by the rule declared later. Specificity
## here is a v1 approximation — the atom count of the longest matched
## selector path — which diverges from vscode-textmate's byte-length
## ordering for selectors whose components are long multi-atom strings,
## but behaves identically on the common case of simple dotted atoms
## (`keyword.operator.arithmetic`).

import std/[json, sets, strutils, tables]

import ./[types, selector]

proc firstSegment(atom: string): string {.inline.} =
  ## First dot-segment of `atom` (or the whole string when there is
  ## no dot). The scope-bucket key is always a first segment, because
  ## `selector.atomMatches` requires a prefix match at a dot boundary:
  ## if `atom == "keyword.operator"` and `scope == "keyword.operator.x"`,
  ## both share the first segment `keyword`.
  let dot = atom.find('.')
  if dot < 0:
    atom
  else:
    atom[0 ..< dot]

proc expectStr(node: JsonNode, field: string): string =
  if node.kind != JString:
    raise newException(
      ThemeError, "field '" & field & "' must be a string, got " & $node.kind
    )
  node.getStr()

proc expectArray(node: JsonNode, field: string): seq[JsonNode] =
  if node.kind != JArray:
    raise newException(
      ThemeError, "field '" & field & "' must be an array, got " & $node.kind
    )
  node.elems

proc expectObject(node: JsonNode, field: string) =
  if node.kind != JObject:
    raise newException(
      ThemeError, "field '" & field & "' must be an object, got " & $node.kind
    )

proc newColorMap*(): ColorMap =
  ## Construct an empty color intern table. `byId[0]` is the reserved
  ## empty-string sentinel so `ColorId(0)` always looks up to `""`.
  ColorMap(byColor: initTable[string, ColorId](), byId: @[""])

proc internColor*(m: ColorMap, color: string): ColorId =
  ## Return the stable id for `color`, assigning a fresh one on first
  ## sight. The empty string is normalised to `NoColor` and is not
  ## inserted into the map.
  if color.len == 0:
    return NoColor
  if m.byColor.hasKey(color):
    return m.byColor[color]
  let id = ColorId(m.byId.len)
  m.byId.add(color)
  m.byColor[color] = id
  id

proc lookupColor*(m: ColorMap, id: ColorId): string =
  ## Reverse lookup. Returns `""` for `NoColor` or any id not yet
  ## interned.
  if id.int >= m.byId.len:
    return ""
  m.byId[id.int]

proc applyFontStyleToken(token: string, acc: var FontStyle, sawNone: var bool) =
  case token
  of "":
    discard
  of "italic":
    acc = acc or fsItalic
  of "bold":
    acc = acc or fsBold
  of "underline":
    acc = acc or fsUnderline
  of "strikethrough":
    acc = acc or fsStrikethrough
  of "none":
    sawNone = true
  else:
    # Unknown token: silently ignored, matching vscode-textmate's
    # tolerant behaviour.
    discard

proc parseFontStyle*(s: string): FontStyle =
  ## Parse a whitespace-delimited font-style string. Recognised tokens:
  ## `italic`, `bold`, `underline`, `strikethrough`, and the exclusive
  ## `none` (which yields `fsNone` regardless of position — any other
  ## flags in the same string are discarded). Empty input yields
  ## `fsNotSet`. Unknown tokens are silently ignored.
  if s.len == 0:
    return fsNotSet
  result = fsNotSet
  var sawNone = false
  var token = ""
  for c in s:
    if c == ' ' or c == '\t' or c == ',':
      applyFontStyleToken(token, result, sawNone)
      token.setLen(0)
    else:
      token.add c
  applyFontStyleToken(token, result, sawNone)
  if sawNone:
    return fsNone

proc decodeScope(node: JsonNode, field: string): string =
  ## Accept `scope` as either a single string (tmTheme) or an array of
  ## strings (VSCode). Arrays are comma-joined so the downstream
  ## `parseSelector` treats them as OR groups.
  case node.kind
  of JString:
    node.getStr()
  of JArray:
    var parts: seq[string] = @[]
    for i, item in node.elems:
      parts.add expectStr(item, field & "[" & $i & "]")
    parts.join(", ")
  else:
    raise newException(
      ThemeError,
      "field '" & field & "' must be a string or array of strings, got " & $node.kind,
    )

proc decodeRuleEntry(node: JsonNode, field: string): RawThemeRule =
  ## Decode one theme rule. Supports tmTheme shape
  ## (`{ "scope": "...", "settings": { "foreground": ..., ... } }`) and
  ## the VSCode `tokenColors` shape (identical structure).
  expectObject(node, field)
  if node.hasKey("name"):
    result.name = expectStr(node["name"], field & ".name")
  if node.hasKey("scope"):
    result.scope = decodeScope(node["scope"], field & ".scope")
  if node.hasKey("settings"):
    let s = node["settings"]
    expectObject(s, field & ".settings")
    if s.hasKey("foreground"):
      result.foreground = expectStr(s["foreground"], field & ".settings.foreground")
    if s.hasKey("background"):
      result.background = expectStr(s["background"], field & ".settings.background")
    if s.hasKey("fontStyle"):
      result.fontStyle = expectStr(s["fontStyle"], field & ".settings.fontStyle")

proc parseRawTheme*(jsonStr: string): RawTheme =
  ## Decode a TextMate (`.tmTheme` JSON) or VSCode (`.json` with
  ## `tokenColors`) theme. The root may carry `name`, `settings` (tmTheme),
  ## or `tokenColors` (VSCode); `settings` and `tokenColors` are both
  ## accepted and, when present, their first entry without a `scope` field
  ## populates `result.defaults`. VSCode root-level `foreground` /
  ## `background` / `colors` keys are not read today — callers that need
  ## those fallbacks should rely on the `scope`-less `tokenColors` entry
  ## that most VSCode themes also include.
  ##
  ## Raises `ThemeError` on invalid JSON, non-object root, wrong field
  ## types, or a `scope` array containing non-string items.
  let root =
    try:
      parseJson(jsonStr)
    except JsonParsingError as e:
      raise newException(ThemeError, "invalid JSON: " & e.msg)
  if root.kind != JObject:
    raise newException(ThemeError, "theme root must be an object")
  if root.hasKey("name"):
    result.name = expectStr(root["name"], "name")
  let entriesField =
    if root.hasKey("settings"):
      "settings"
    elif root.hasKey("tokenColors"):
      "tokenColors"
    else:
      ""
  if entriesField.len == 0:
    return
  let entries = expectArray(root[entriesField], entriesField)
  var defaultsAssigned = false
  for i, item in entries:
    let childField = entriesField & "[" & $i & "]"
    let rule = decodeRuleEntry(item, childField)
    if rule.scope.len == 0 and not defaultsAssigned:
      # tmTheme convention: the first `scope`-less entry holds the
      # fallback foreground/background/fontStyle.
      result.defaults = rule
      defaultsAssigned = true
      continue
    result.rules.add rule

proc specificityOf(sel: SelectorExpr): int =
  ## Specificity score for a theme rule's selector. Computed as the
  ## length (in characters) of the longest dotted atom across any
  ## include path of any OR group. `selector.parseSelector` treats
  ## `keyword.operator` as a single atom, so atom count alone would
  ## mis-rank dotted selectors — character length preserves the
  ## "deeper path wins" ordering used by vscode-textmate on the common
  ## case. Exclusion paths (`-foo`) do not contribute — they only gate
  ## whether the rule matches.
  for g in sel.groups:
    for p in g.includes:
      for atom in p:
        if atom.len > result:
          result = atom.len

proc styleFromRule(rule: RawThemeRule, colors: ColorMap): ThemeStyle =
  result.foreground = internColor(colors, rule.foreground)
  result.background = internColor(colors, rule.background)
  result.fontStyle = parseFontStyle(rule.fontStyle)

proc indexRule(result: Theme, ruleIdx: int, sel: SelectorExpr) =
  ## Populate `indexBySegment` for one rule. The rule is bucketed under
  ## the first dot-segment of the **last atom** of each include path in
  ## each OR group — a path matches only if its last atom hits some
  ## scope, and such a hit means the first segments must agree.
  ##
  ## Multi-path groups (`a b c`) contribute only their rightmost atom.
  ## Rules with multi-group selectors land in every relevant bucket
  ## (dedup via `HashSet`), and the resolver will still filter by
  ## `matches()` — buckets widen the candidate pool, they do not
  ## change semantics.
  var keys = initHashSet[string]()
  for g in sel.groups:
    for p in g.includes:
      if p.len > 0:
        keys.incl firstSegment(p[^1])
  for k in keys:
    if k.len > 0:
      discard result.indexBySegment.hasKeyOrPut(k, @[])
      result.indexBySegment[k].add ruleIdx

proc compileTheme*(raw: RawTheme): Theme =
  ## Compile a `RawTheme` into a runtime `Theme`. Each rule's `scope`
  ## string is parsed via `parseSelector`; rules whose selector has no
  ## include group are dropped. Color strings are interned into a shared
  ## `ColorMap` so repeated references collapse to the same `ColorId`.
  ##
  ## Raises `ThemeError` if any rule's scope string is structurally
  ## malformed (propagated from `parseSelector`).
  result = Theme(
    name: raw.name,
    colorMap: newColorMap(),
    rules: @[],
    indexBySegment: initTable[string, seq[int]](),
  )
  result.defaultStyle = styleFromRule(raw.defaults, result.colorMap)
  for i, r in raw.rules:
    var sel: SelectorExpr
    try:
      sel = parseSelector(r.scope)
    except CatchableError as e:
      raise newException(
        ThemeError,
        "failed to parse scope selector '" & r.scope & "' at rule[" & $i & "]: " & e.msg,
      )
    if sel.isEmpty:
      continue
    let ruleIdx = result.rules.len
    result.rules.add ThemeRule(
      selector: sel,
      style: styleFromRule(r, result.colorMap),
      specificity: specificityOf(sel),
      order: i,
    )
    indexRule(result, ruleIdx, sel)
  result.seenMarks = newSeq[uint32](result.rules.len)

proc considerRule(
    rule: ThemeRule,
    result: var ThemeStyle,
    fgSpec, fgOrder, bgSpec, bgOrder, fsSpec, fsOrder: var int,
) {.inline.} =
  ## Merge one matching rule's fields into `result`, respecting the
  ## per-field specificity-then-order winner-selection invariant.
  if rule.style.foreground != NoColor:
    if rule.specificity > fgSpec or
        (rule.specificity == fgSpec and rule.order >= fgOrder):
      result.foreground = rule.style.foreground
      fgSpec = rule.specificity
      fgOrder = rule.order
  if rule.style.background != NoColor:
    if rule.specificity > bgSpec or
        (rule.specificity == bgSpec and rule.order >= bgOrder):
      result.background = rule.style.background
      bgSpec = rule.specificity
      bgOrder = rule.order
  if rule.style.fontStyle != fsNotSet:
    if rule.specificity > fsSpec or
        (rule.specificity == fsSpec and rule.order >= fsOrder):
      result.fontStyle = rule.style.fontStyle
      fsSpec = rule.specificity
      fsOrder = rule.order

proc resolveTheme*(theme: Theme, scopes: openArray[ScopeName]): ThemeStyle =
  ## Resolve the `ThemeStyle` for a scope stack. Each style field is
  ## picked from the most-specific matching rule that *sets* that field;
  ## a field left unset (`ColorId(0)` or `fsNotSet`) by every matching
  ## rule inherits from `theme.defaultStyle`. Ties on specificity are
  ## broken by the rule declared later in the theme input (vscode-textmate
  ## "later-wins" convention).
  ##
  ## Specificity is the character length of the rule's longest matched
  ## atom (see `specificityOf`). This produces the expected ordering on
  ## the common case (`keyword.operator` beats `keyword`) but diverges
  ## from vscode-textmate's exact selector-length ordering for rare
  ## multi-atom rule selectors. Stabilising to upstream's exact order is
  ## a future item.
  ##
  ## Rules are filtered through `theme.indexBySegment` first: only
  ## rules whose last-atom first-segment appears somewhere in `scopes`
  ## are candidates for `matches()`. This keeps the per-call cost at
  ## O(scopes + candidates) instead of O(total rules), which matters
  ## once editor consumers call this per token.
  result = theme.defaultStyle
  if theme.rules.len == 0:
    return
  var fgSpec = low(int)
  var fgOrder = low(int)
  var bgSpec = low(int)
  var bgOrder = low(int)
  var fsSpec = low(int)
  var fsOrder = low(int)
  # Candidate rules from the index. Dedup via an epoch-counter stored
  # on the `Theme` itself: each `resolveTheme` call bumps the epoch
  # once, then marks each visited rule with the new value. No
  # per-call allocation.
  inc theme.seenEpoch
  if theme.seenEpoch == 0'u32:
    # Wrap-around: zero out the marks so the comparison stays correct
    # after the counter rolls over. Will take ~4 billion calls on a
    # single Theme before this fires, so cheap in practice.
    for i in 0 ..< theme.seenMarks.len:
      theme.seenMarks[i] = 0
    theme.seenEpoch = 1
  let epoch = theme.seenEpoch
  for scope in scopes:
    let seg = firstSegment(scope)
    if seg.len == 0:
      continue
    theme.indexBySegment.withValue(seg, entries):
      for i in entries[]:
        if theme.seenMarks[i] == epoch:
          continue
        theme.seenMarks[i] = epoch
        let rule = theme.rules[i]
        if not matches(rule.selector, scopes):
          continue
        considerRule(rule, result, fgSpec, fgOrder, bgSpec, bgOrder, fsSpec, fsOrder)
