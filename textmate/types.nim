import std/tables

import pkg/reni

type
  ScopeName* = string

  SelectorPriority* = enum
    spDefault
    spL
    spR

  ScopePath* = seq[string]
    ## A descendant path of scope atoms (dot-separated identifiers).

  ScopeGroup* = object
    includes*: seq[ScopePath]
    excludes*: seq[ScopePath]

  SelectorExpr* = object
    ## Parsed TextMate scope selector. `groups` is OR; an empty
    ## selector matches nothing. `priority` controls tie-breaking for
    ## injection rules.
    groups*: seq[ScopeGroup]
    priority*: SelectorPriority

  RawCapture* = object
    name*: ScopeName
    patterns*: seq[RawPattern]

  RawPattern* = object
    name*: ScopeName
    contentName*: ScopeName
    match*: string
    begin*: string
    `end`*: string
    `while`*: string
    `include`*: string
    patterns*: seq[RawPattern]
    captures*: OrderedTable[string, RawCapture]
    beginCaptures*: OrderedTable[string, RawCapture]
    endCaptures*: OrderedTable[string, RawCapture]
    whileCaptures*: OrderedTable[string, RawCapture]

  RawGrammar* = object
    name*: string
    scopeName*: ScopeName
    patterns*: seq[RawPattern]
    repository*: OrderedTable[string, RawPattern]
    injections*: OrderedTable[string, RawPattern]
      ## Grammar-level injections. Each key is a scope selector; each
      ## value is a pattern wrapper whose `patterns` field is merged
      ## into the effective rule list when the selector matches.
    injectionSelector*: string
      ## When non-empty, this grammar's `patterns` are injected into
      ## any grammar whose active scope stack matches the selector.
    firstLineMatch*: string
      ## Regex hint for grammar auto-detection — consulted only by the
      ## registry (`matchesFirstLine` / `detectGrammar`).

  RuleId* = int

  RuleKind* = enum
    rkMatch
    rkInclude
    rkBeginEnd
    rkBeginWhile

  IncludeKind* = enum
    ikSelf
    ikBase
    ikRepo
    ikGrammar
    ikGrammarRepo
    ikInvalid

  Capture* = object
    ## A compiled capture-group entry. Phase 4: captures may carry their
    ## own sub-`patterns` for recursive tokenisation over the captured
    ## span (`rkMatch` / `rkInclude`-to-`rkMatch` only — nested
    ## `begin`/`end` inside a capture is deferred to Phase 5).
    name*: ScopeName
    patterns*: seq[Rule]

  Rule* = ref object
    id*: RuleId
    name*: ScopeName
    case kind*: RuleKind
    of rkMatch:
      matchRegex*: Regex
      captures*: Table[int, Capture]
    of rkInclude:
      includeTarget*: string
      includeKind*: IncludeKind
      includeRepoName*: string
      includeScope*: ScopeName
      resolvedGrammar*: Grammar
      resolvedRule*: Rule
    of rkBeginEnd, rkBeginWhile:
      beginRegex*: Regex
      terminatorPattern*: string
        ## Source text of the block terminator. For `rkBeginEnd` this is
        ## the `end` pattern; for `rkBeginWhile` the `while` pattern.
      terminatorRegex*: Regex
        ## Compiled form of `terminatorPattern` when no begin→terminator
        ## backreferences are present; otherwise unset and the tokenizer
        ## compiles a resolved regex at push time.
      terminatorHasBackrefs*: bool
      beginCaptures*: Table[int, Capture]
      terminatorCaptures*: Table[int, Capture]
        ## `endCaptures` for `rkBeginEnd`, `whileCaptures` for `rkBeginWhile`.
      contentName*: ScopeName
      patterns*: seq[Rule]
      patternExpansionCache*: Table[ScopeName, seq[ResolvedRule]]
        ## Memoised expansion of `patterns` keyed by the base grammar's
        ## `scopeName` (empty string when no base is in scope). Cleared
        ## by `registry.addGrammar` whenever a cross-grammar link is
        ## newly satisfied so stale entries never outlive a link change.
      resolvedTerminatorCache*: Table[string, Regex]
        ## Phase 6: memoised compilation of terminator patterns after
        ## begin→terminator backreference substitution. Key is the final
        ## substituted pattern string; hit avoids a fresh `re(...)` call
        ## on every begin push. Only populated when
        ## `terminatorHasBackrefs`. Never stores failed compilations.

  ResolvedRule* = tuple[rule: Rule, grammar: Grammar]

  PrioritizedRule* = tuple[rule: Rule, grammar: Grammar, priority: int]
    ## Effective rule entry for match arbitration. Encoding:
    ## - `+1`: L-priority injection (beats base rules)
    ## - ` 0`: non-injection (base) rule
    ## - `-1`: default-priority injection (loses to base, beats R)
    ## - `-2`: R-priority injection (loses to base and default injections)
    ## Within the same priority level, earlier entries win.

  CompiledInjection* = object
    selector*: SelectorExpr
    rules*: seq[Rule]
    priority*: SelectorPriority

  Grammar* = ref object
    scopeName*: ScopeName
    rootRules*: seq[Rule]
    repository*: Table[string, Rule]
    ruleById*: Table[RuleId, Rule]
    nextRuleId*: RuleId
    includeRules*: seq[Rule]
      ## Every `rkInclude` rule owned by this grammar (including those
      ## nested inside `begin`/`end` `patterns` sub-lists). Populated
      ## at compile time; consumed by the cross-grammar link pass.
    expansionCache*: Table[ScopeName, seq[ResolvedRule]]
      ## Memoised root-rule expansions keyed by the base grammar's
      ## `scopeName` (empty string when no base is in scope). Value is
      ## the flattened `(rule, owning grammar)` sequence with every
      ## `rkInclude` entry already resolved. Populated by
      ## `expandRootRules` and cleared when a cross-grammar link is
      ## newly satisfied.
    injections*: seq[CompiledInjection]
      ## Grammar-level injections compiled from `RawGrammar.injections`.
    injectionSelector*: SelectorExpr
      ## When `hasInjectionSelector`, this selector is tested against
      ## other grammars' scope stacks to decide cross-grammar injection.
    hasInjectionSelector*: bool
    firstLineMatch*: Regex
      ## Compiled `firstLineMatch` regex. Only consult when
      ## `hasFirstLineMatch` is true — `Regex` is a value type and has
      ## no meaningful zero value.
    hasFirstLineMatch*: bool

  Registry* = ref object
    grammars*: OrderedTable[ScopeName, Grammar]
    pendingLinks*: seq[Grammar]
      ## Grammars whose `includeRules` contain unresolved cross-grammar
      ## references. Retried each time a new grammar is added.

  Token* = object
    ## A single tokenised slice of the input line.
    ##
    ## `startIndex` and `endIndex` are **byte offsets** into the line
    ## passed to `tokenizeLine`, forming the half-open range
    ## ``[startIndex, endIndex)``. `scopes` is the active scope stack at
    ## that range, ordered from outermost (the grammar's `scopeName`) to
    ## innermost (the matched rule's `name`, optionally followed by
    ## capture-group scopes).
    startIndex*: int
    endIndex*: int
    scopes*: seq[ScopeName]

  StackElement* = ref object
    ## A node in the tokenizer rule stack. The full scope chain is
    ## reconstructed by walking `parent` from root to leaf via
    ## `fullScopes`. The root element has `rule == nil` and uses
    ## `contentName` to carry the grammar's own `scopeName`. Pushed
    ## elements have `rule` set to the active `rkBeginEnd` or
    ## `rkBeginWhile` rule — its `name` and `contentName` determine the
    ## element's contributions — and `terminatorRegex` is the compiled
    ## terminator (end or while) pattern, with any begin→terminator
    ## backreferences already substituted.
    parent*: StackElement
    grammar*: Grammar
    contentName*: ScopeName
    rule*: Rule
    terminatorRegex*: Regex
    terminatorSource*: string
      ## Source text of the resolved terminator (after any
      ## begin→terminator backreference substitution). Empty on the root
      ## element. Used by `stackEquals` to compare stack state
      ## structurally: two `rkBeginEnd` pushes with the same `rule` can
      ## have different resolved terminators (e.g. heredoc delimiters),
      ## and the compiled `terminatorRegex` has no structural equality,
      ## so the source string is the load-bearing identity.
    registry*: Registry
      ## Only populated on the root element. Carries the registry into
      ## tokenisation so cross-grammar injections can be discovered.
    cachedScopes*: seq[ScopeName]
      ## Memoised result of `fullScopes(this)`. Populated lazily on first
      ## call; reused thereafter. Stack elements are immutable once
      ## constructed, so the cache never needs invalidation.
    scopesComputed*: bool
      ## Discriminates "cache unpopulated" from "cache populated with
      ## an empty chain" (the latter is a legitimate value for a nil
      ## stack passthrough).
    ruleScopeCache*: Table[Rule, seq[ScopeName]]
      ## Memoised `fullScopes(this) & rule.name` per `Rule` that matches
      ## from this stack frame. Avoids rebuilding (and COW-reallocating)
      ## the combined scope sequence every time the same rule fires from
      ## the same push state. Populated lazily by `scopesWithRuleName`.
      ## Only populated for rules with a non-empty `name`.

  LineTokens* = object
    ## Result of `tokenizeLine`. `tokens` is the sequence of token slices
    ## covering the line (left to right, contiguous, no overlaps).
    ## `ruleStack` is the stack state at end-of-line; pass it as the
    ## `stack` argument for the next line to tokenise a multi-line
    ## document, which carries open `begin`/`end` constructs across
    ## newlines.
    tokens*: seq[Token]
    ruleStack*: StackElement

  ScannerEntry* = object
    ## Phase 6: memoised `search` result for one rule on one line. The
    ## tokenizer advances `pos` monotonically within a single
    ## `tokenizeLine` call, so a cached leftmost match starting at
    ## `match.boundaries[0].a >= pos` stays valid. `isMiss` records the
    ## dual case: if `search(line, regex, start=queryPos)` returned no
    ## match, then searching from any later `pos >= queryPos` likewise
    ## returns no match.
    match*: Match
    queryPos*: int
    isMiss*: bool

  LineScanner* = object
    ## Internal cache keyed by `Rule` identity that memoises `search`
    ## results across a single line tokenisation. See `ScannerEntry`.
    ## Scoped to one `tokenizeLine` invocation; never reused across
    ## lines. The key is the `Rule` object itself (pointer identity via
    ## `tokenizer.hash`) because `RuleId` is only unique per grammar —
    ## cross-grammar includes can collide on numeric ids.
    ##
    ## `ctx` is a reusable reni scratch buffer shared by every
    ## `searchIntoCtx` invocation within a single `tokenizeLine` call
    ## (and within a single `tokenizeRange` call). After reni's first
    ## `searchIntoCtx` for a given rule, subsequent calls reuse
    ## `ctx`'s `captures` / `groupRecursionDepth` / `captureStacks`
    ## seqs — no fresh heap alloc per regex dispatch. Populated at
    ## `LineScanner` construction time.
    entries*: Table[Rule, ScannerEntry]
    lineLen*: int
    ctx*: MatchContext

  GrammarError* = object of CatchableError
    ## Raised by `parseRawGrammar`, `compileGrammar`, and
    ## `grammarForScope` when the grammar input is malformed, contains
    ## an invalid regex, is structurally inconsistent, or refers to an
    ## unregistered scope.

  ScopeId* = uint32
    ## Phase 7: interned numeric identifier for a `ScopeName`. `0` is
    ## the "no scope" sentinel: `internScope` returns it only when the
    ## input is the empty string, and `lookupScope` returns `""` for it.

  ScopeIdMap* = ref object
    ## Phase 7: bidirectional intern table mapping `ScopeName <->
    ## ScopeId`. Ids are stable across the lifetime of a map and are
    ## assigned in insertion order starting at 1. Pass the same map
    ## through every call in a document/editor session to keep ids
    ## consistent.
    byName*: Table[ScopeName, ScopeId]
    byId*: seq[ScopeName] ## `byId[0]` is the reserved sentinel (empty string).

  TokenMetadata* = distinct uint32
    ## Phase 7: packed per-token metadata. The concrete bit layout is
    ## intentionally unspecified today and will be pinned down when the
    ## theme resolver lands (expected to carry fontStyle, foreground,
    ## background, tokenType and languageId fields, following
    ## vscode-textmate's `StackElementMetadata`). Tokens currently read
    ## `DefaultMetadata` (all zeros); do not rely on any particular bit
    ## assignment yet.

  MetadataToken* = object
    ## Phase 7: numeric-scope counterpart to `Token`. `scopeIds` is the
    ## parallel interning of `Token.scopes` through a shared
    ## `ScopeIdMap`.
    startIndex*: int
    endIndex*: int
    scopeIds*: seq[ScopeId]
    metadata*: TokenMetadata

  MetadataLineTokens* = object ## Phase 7: numeric-scope counterpart to `LineTokens`.
    tokens*: seq[MetadataToken]
    ruleStack*: StackElement

const DefaultMetadata*: TokenMetadata = TokenMetadata(0)

proc `==`*(a, b: TokenMetadata): bool {.borrow.}
proc `and`*(a, b: TokenMetadata): TokenMetadata {.borrow.}
proc `or`*(a, b: TokenMetadata): TokenMetadata {.borrow.}
proc `shr`*(a: TokenMetadata, b: int): TokenMetadata {.borrow.}
proc `shl`*(a: TokenMetadata, b: int): TokenMetadata {.borrow.}
proc `$`*(a: TokenMetadata): string {.borrow.}

type
  ThemeError* = object of CatchableError
    ## Raised by `parseRawTheme` and `compileTheme` when the theme input
    ## is malformed or contains an invalid scope selector.

  FontStyle* = distinct uint8
    ## Phase 7: bit-flag font style. `fsNotSet` (0) is the "inherit from a
    ## less-specific rule" sentinel — distinct from `fsNone` (1), which
    ## actively clears inherited styling. The remaining constants are
    ## single-bit flags combined via `or`.

  ColorId* = uint32
    ## Phase 7: interned color identifier within a `ColorMap`. `0` is the
    ## "no color" sentinel returned by `internColor` on the empty string
    ## and by `lookupColor` on out-of-range ids.

  ColorMap* = ref object
    ## Phase 7: bidirectional intern table mapping color strings (e.g.
    ## "#ff0000") to stable `ColorId`s. Ids are assigned in insertion
    ## order starting at 1; `byId[0]` is the reserved empty-string
    ## sentinel. Case-sensitive (CSS hex colors are conventionally
    ## lowercase in themes, but this map preserves whatever the theme
    ## supplied).
    byColor*: Table[string, ColorId]
    byId*: seq[string]

  ThemeStyle* = object
    ## Phase 7: resolved style for one scope stack. `ColorId(0)` means
    ## "unset" (either the theme never defined the field or no rule
    ## matched). `fontStyle == fsNotSet` likewise means "unset".
    foreground*: ColorId
    background*: ColorId
    fontStyle*: FontStyle

  RawThemeRule* = object
    ## Phase 7: unparsed theme rule, mirrors one tmTheme `settings` entry
    ## (or one VSCode `tokenColors` entry). Empty string fields are the
    ## "not set" marker.
    name*: string
    scope*: string
      ## Raw scope selector, already comma-joined if the source was a
      ## JSON array.
    foreground*: string
    background*: string
    fontStyle*: string

  RawTheme* = object
    ## Phase 7: decoded theme JSON. `defaults` corresponds to the first
    ## entry in the `settings` / `tokenColors` array that has no `scope`
    ## field and acts as the fallback when no scope-specific rule
    ## matches. VSCode's root-level `foreground` / `background` /
    ## `colors` keys are not currently read.
    name*: string
    defaults*: RawThemeRule
    rules*: seq[RawThemeRule]

  ThemeRule* = object
    ## Phase 7: compiled theme rule. `specificity` is the character
    ## length of the longest atom across any include path of
    ## `selector.groups` — a v1 approximation of vscode-textmate's
    ## selector-length ordering (see `specificityOf`). `order` is the
    ## 0-based position of this rule in the input `RawTheme.rules` so
    ## `resolveTheme` can apply "later rule wins" ties.
    selector*: SelectorExpr
    style*: ThemeStyle
    specificity*: int
    order*: int

  Theme* = ref object
    ## Phase 7: compiled theme ready for `resolveTheme`. `rules` preserves
    ## input order; `colorMap` interns every non-empty color string
    ## referenced by `rules` and `defaultStyle`.
    ##
    ## `indexBySegment` buckets rule indices by the first dot-segment of
    ## the **last atom** of each include path — a rule's last atom must
    ## match somewhere in the query scope stack (per `pathMatches`'s
    ## left-to-right greedy walk), so any scope whose first segment is
    ## not a key of this table provably disqualifies all the rules
    ## bucketed there. `resolveTheme` unions the candidates for every
    ## scope segment instead of scanning all rules. Populated by
    ## `compileTheme` and never mutated afterwards.
    name*: string
    defaultStyle*: ThemeStyle
    rules*: seq[ThemeRule]
    colorMap*: ColorMap
    indexBySegment*: Table[string, seq[int]]
    seenEpoch*: uint32
      ## Monotonically-incrementing counter used by `resolveTheme` to
      ## dedup candidate rules across scope buckets without allocating
      ## a fresh `seen` array per call. A rule at index `i` is
      ## considered already-visited when `seenMarks[i] == seenEpoch`.
    seenMarks*: seq[uint32]
      ## Per-rule "last seen at" tag, length == `rules.len`. Sized by
      ## `compileTheme`; mutated by `resolveTheme` (which means a
      ## single `Theme` cannot be resolved concurrently from multiple
      ## threads — Theme was already stateful via `ColorMap`'s intern
      ## tables during compile, so this extends the same contract).

const
  NoColor*: ColorId = ColorId(0) ## Phase 7: "color not set" sentinel.
  fsNotSet*: FontStyle = FontStyle(0)
    ## Phase 7: "inherit from a less-specific rule". Distinct from
    ## `fsNone` so theme inheritance can distinguish "unspecified" from
    ## "explicitly no style".
  fsNone*: FontStyle = FontStyle(1)
  fsItalic*: FontStyle = FontStyle(2)
  fsBold*: FontStyle = FontStyle(4)
  fsUnderline*: FontStyle = FontStyle(8)
  fsStrikethrough*: FontStyle = FontStyle(16)

proc `==`*(a, b: FontStyle): bool {.borrow.}
proc `and`*(a, b: FontStyle): FontStyle {.borrow.}
proc `or`*(a, b: FontStyle): FontStyle {.borrow.}
proc `$`*(a: FontStyle): string {.borrow.}
