# textmate

A TextMate grammar parser in Nim.

## Status

### Supported features

- `match`, `begin`/`end`, and `begin`/`while` rules — including
  multi-line state, `beginCaptures` / `endCaptures` / `whileCaptures`,
  `contentName`, and begin→terminator backreferences.
- `include` directives (`$self`, `$base`, `#name`, `source.xxx`,
  `source.xxx#name`), resolved at tokenization time with cycle
  detection and memoisation.
- Nested patterns inside a `begin`/`end` block (with `end` winning
  position ties), capture groups inheriting outer-capture scopes
  correctly, and captures carrying their own `patterns` for recursive
  tokenization of the captured span.
- Grammar-level `injections` and registry-level `injectionSelector`
  (with `L:` / `R:` priority and scope selectors).
- `firstLineMatch` for grammar auto-detection.
- Theme primitives (`parseRawTheme` / `compileTheme` / `resolveTheme`)
  for both tmTheme and VSCode `tokenColors` forms.
- Numeric scope ids via `ScopeIdMap` and `MetadataToken` (with packed
  `TokenMetadata` reserved for a future theme pass).
- `DocumentTokens` + `applyEdit` for incremental re-tokenization in
  editor integrations, short-circuiting past the edit region on stack
  equality.

### Limitations

- `begin`/`end` inside a capture's `patterns` is deferred —
  capture-level recursion is `match`-only today.
- `TokenMetadata` bits are reserved but unset; tokens read
  `DefaultMetadata` (all zeros) until a concrete editor consumer drives
  the theme→metadata packing.
- PLIST grammars are not supported; only JSON tmLanguage input is
  parsed.

### Performance notes

- Per-rule regex objects and backreference-terminator regexes are
  compiled once and reused across lines.
- A per-line scanner cache memoises each rule's leftmost match position
  within a `tokenizeLine` call.
- Incremental re-tokenization stops as soon as a freshly computed
  end-of-line stack equals the previously stored one, leaving the tail
  untouched.
- A benchmark fixture is provided under `bench/` (`nimble bench`).

## Usage

### Single-line tokenisation

```nim
import pkg/textmate

let jsonStr = """
{
  "scopeName": "source.test",
  "patterns": [ { "match": "\\bfoo\\b", "name": "keyword.foo" } ]
}
"""

let g = compileGrammar(parseRawGrammar(jsonStr))
let lt = tokenizeLine("hello foo bar", initialStack(g))
for tok in lt.tokens:
  echo tok.startIndex, "..", tok.endIndex, " ", tok.scopes
```

### Tokenising a document

`tokenizeDocument` threads the rule stack across lines for you. Open
`begin`/`end` and `begin`/`while` constructs carry across newlines
automatically.

```nim
import pkg/textmate

let g = compileGrammar(parseRawGrammar(jsonStr))
let source = """
"hello
world"
"""
let doc = tokenizeDocument(source.splitLines, initialStack(g))
for lt in doc:
  for tok in lt.tokens:
    echo tok.startIndex, "..", tok.endIndex, " ", tok.scopes
```

### Streaming form

For large inputs, `tokenizeDocumentIter` yields one `LineTokens` at a
time so the caller can process or discard each line before the next is
produced. The last yielded element's `ruleStack` is the end-of-document
state (empty input yields nothing, and the caller keeps its initial
stack).

```nim
var totalTokens = 0
for lt in tokenizeDocumentIter(lines, initialStack(g)):
  totalTokens += lt.tokens.len
  # ...forward lt.tokens downstream and drop it before the next line
```

### Incremental editor integration

For interactive editors, re-tokenizing the entire document on every
keystroke is wasteful. `DocumentTokens` is a stateful session that
caches per-line tokens and end-of-line rule stacks; `applyEdit`
re-tokenizes only from the edit region, stopping as soon as the
freshly computed end-of-line stack matches the previously stored one
(subsequent lines are then provably unchanged).

```nim
import pkg/textmate

let g = compileGrammar(parseRawGrammar(jsonStr))
let doc = newDocumentTokens(g)
doc.setLines(@["line one", "line two", "line three", "line four"])

# User edits line 1 — replace it with two new lines.
let dirty = doc.applyEdit(1, 1, ["replaced two", "replaced two and a half"])
for i in dirty:
  let lt = doc.getLine(i)
  # ...push lt.tokens into the editor's highlight buffer
  echo "line ", i, ": ", lt.tokens.len, " tokens"
```

`dirty` is a `Slice[int]` (half-open) describing exactly which line
indices were rewritten — iterate it to refresh highlights.

The underlying primitive is `stackEquals(a, b)`, which compares two
`StackElement` values structurally (walking parent chains and
comparing grammar/rule/terminator identity). Advanced callers can
drive incremental tokenization manually with `tokenizeLine` +
`stackEquals` and their own per-line storage.

### Numeric scope IDs (metadata-ready tokens)

`tokenizeLineMetadata` / `tokenizeDocumentMetadata` project each token's
`scopes` through a shared `ScopeIdMap`, yielding `MetadataToken` values
with a numeric `scopeIds: seq[ScopeId]` and a packed
`metadata: TokenMetadata` (a `distinct uint32`). The metadata bit layout
is reserved for future theme integration and reads `DefaultMetadata`
(all zeros) today.

```nim
let scopes = newScopeIdMap()
let mlt = tokenizeLineMetadata("hello foo bar", initialStack(g), scopes)
for tok in mlt.tokens:
  for id in tok.scopeIds:
    echo id, " -> ", lookupScope(scopes, id)
```

The same `ScopeIdMap` can be reused across lines and documents so ids
for repeated scope names stay stable. The document-level form threads
the rule stack across lines for you and keeps id assignments shared:

```nim
let lines = ["hello foo bar", "foo again"]
let mdoc = tokenizeDocumentMetadata(lines, initialStack(g), scopes)
for mlt in mdoc:
  for tok in mlt.tokens:
    echo tok.startIndex, "..", tok.endIndex, " ", tok.scopeIds
```

A streaming variant (`tokenizeDocumentMetadataIter`) is also available
with the same line-at-a-time semantics as `tokenizeDocumentIter`.

### Theme resolution

`parseRawTheme` accepts a TextMate-style theme (top-level `settings`
array) or a VSCode-style theme (top-level `tokenColors` array), and
`compileTheme` produces a runtime `Theme`. `resolveTheme` picks the
best-matching `ThemeStyle` for a scope stack, with field-level
inheritance across rules (the most-specific matching rule wins each of
`foreground` / `background` / `fontStyle` independently; ties are
broken by the rule declared later).

```nim
import pkg/textmate

const ThemeJson = """
  { "settings": [
    { "settings": { "foreground": "#cccccc", "background": "#1e1e1e" } },
    { "scope": "keyword", "settings": { "foreground": "#ff5555",
                                         "fontStyle": "italic" } },
    { "scope": "keyword.operator", "settings": { "foreground": "#66ccff" } }
  ] }
"""

let theme = compileTheme(parseRawTheme(ThemeJson))
let style = resolveTheme(theme, @["source.x", "keyword.operator"])
echo lookupColor(theme.colorMap, style.foreground) # "#66ccff"
echo style.fontStyle == fsItalic                   # true (inherited from "keyword")
```

Colors are interned into the `Theme.colorMap` so repeated references
share one numeric id; `fontStyle` is a bit-flag `distinct uint8`
combining `fsItalic` / `fsBold` / `fsUnderline` / `fsStrikethrough`
(with `fsNone` and the `fsNotSet` sentinel for "inherit"). Packing a
resolved style into `TokenMetadata` bits is deferred pending a concrete
editor consumer; today `resolveTheme` is a standalone API that callers
invoke per token.

## Roadmap

- [ ] `begin`/`end` inside a capture's `patterns` (today: `match`-only
      capture-level recursion).
- [ ] Pack a resolved `ThemeStyle` into `TokenMetadata` bits so
      `MetadataToken.metadata` carries fg/bg/fontStyle directly. Gated
      on a concrete editor consumer surfacing the format it needs;
      until then `resolveTheme` is invoked per token by the caller.
- [ ] Theme resolver refinements:
      (a) specificity should account for parent-scope path length, not
      just the longest single atom, so selectors like
      `source.ruby keyword.operator` outrank bare `keyword.operator`;
      (b) `resolveTheme` performs a linear scan of every rule per
      call — bucketing rules by their leading atom (or building a trie
      keyed on the rightmost scope) would cut this to O(matching) and
      matters once editor consumers call it per token; (c) the three
      near-identical fg/bg/fontStyle update blocks inside `resolveTheme`
      can collapse to a single templated helper. All three are gated on
      a concrete consumer surfacing a correctness or perf gap — the
      current shape is intentionally simple.

## References

- [TextMate grammar reference](https://macromates.com/manual/en/language_grammars)
- [vscode-textmate](https://github.com/microsoft/vscode-textmate) — the
  de facto reference implementation; this library follows its semantics
  for `begin`/`end`/`while` state, capture inheritance, and injection
  priority.
- [VSCode color theme guide](https://code.visualstudio.com/api/extension-guides/color-theme)
  — covers both the tmTheme `settings` form and the VSCode
  `tokenColors` form accepted by `parseRawTheme`.

## License

MIT
