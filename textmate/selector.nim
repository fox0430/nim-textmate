import std/[strutils]

import ./types
export types.SelectorPriority, types.ScopePath, types.ScopeGroup, types.SelectorExpr

proc isEmpty*(sel: SelectorExpr): bool {.inline.} =
  sel.groups.len == 0

proc priority*(sel: SelectorExpr): SelectorPriority {.inline.} =
  sel.priority

proc atomMatches(atom, scope: string): bool {.inline.} =
  ## Prefix match on dot boundaries. `string.quoted` matches
  ## `string.quoted` and `string.quoted.double`, but not `string.quotedfoo`.
  if scope == atom:
    return true
  if scope.len > atom.len and scope.startsWith(atom) and scope[atom.len] == '.':
    return true
  false

proc pathMatches(path: ScopePath, scopes: openArray[string]): bool =
  ## Left-to-right greedy walk. Each atom of `path` must match a scope
  ## in `scopes` at or after the previous match's position.
  if path.len == 0:
    return true
  var i = 0
  for atom in path:
    var hit = false
    while i < scopes.len:
      if atomMatches(atom, scopes[i]):
        hit = true
        inc i
        break
      inc i
    if not hit:
      return false
  true

proc matchesGroup(g: ScopeGroup, scopes: openArray[string]): bool =
  for p in g.includes:
    if not pathMatches(p, scopes):
      return false
  for p in g.excludes:
    if pathMatches(p, scopes):
      return false
  true

proc matches*(sel: SelectorExpr, scopes: openArray[string]): bool =
  ## True when at least one group matches. An empty selector (no groups)
  ## never matches.
  for g in sel.groups:
    if matchesGroup(g, scopes):
      return true
  false

proc skipSpaces(s: string, i: var int) {.inline.} =
  while i < s.len and s[i] in {' ', '\t'}:
    inc i

proc readAtom(s: string, i: var int): string =
  ## Read a dot-separated identifier. Stops at whitespace, ',', '-', or EOF.
  let start = i
  while i < s.len and s[i] notin {' ', '\t', ',', '-'}:
    inc i
  s[start ..< i]

proc parsePath(s: string, i: var int): ScopePath =
  ## Read a sequence of atoms until a group boundary ('-', ',', or EOF).
  skipSpaces(s, i)
  while i < s.len and s[i] notin {',', '-'}:
    let atom = readAtom(s, i)
    if atom.len > 0:
      result.add atom
    skipSpaces(s, i)

proc parseGroup(s: string, i: var int): ScopeGroup =
  ## Parse one group: `<path>(-<path>)*`.
  result.includes.add parsePath(s, i)
  while i < s.len and s[i] == '-':
    inc i
    skipSpaces(s, i)
    let p = parsePath(s, i)
    if p.len > 0:
      result.excludes.add p

proc parsePriority(s: string, i: var int): SelectorPriority =
  ## Consume an optional `L:` / `R:` prefix at the current position.
  skipSpaces(s, i)
  if i + 1 < s.len and s[i + 1] == ':':
    case s[i]
    of 'L':
      i += 2
      return spL
    of 'R':
      i += 2
      return spR
    else:
      discard
  spDefault

proc parseSelector*(s: string): SelectorExpr =
  ## Parse a TextMate scope selector. Raises `GrammarError` on truly
  ## malformed input (e.g. trailing `-` with no following atom). Tolerant
  ## of whitespace and empty groups (an empty group is dropped).
  ##
  ## `L:` / `R:` priority prefixes are recognised only once at the very
  ## start of the selector — per-group prefixes like `foo, L:bar` are
  ## not supported and the `L:` there would be consumed as part of an
  ## atom.
  var i = 0
  result.priority = parsePriority(s, i)
  while i < s.len:
    skipSpaces(s, i)
    if i >= s.len:
      break
    let g = parseGroup(s, i)
    # Drop groups whose include list is empty — a selector like `, foo`
    # or a trailing comma is tolerated.
    var keep = false
    for p in g.includes:
      if p.len > 0:
        keep = true
        break
    if keep:
      result.groups.add g
    skipSpaces(s, i)
    if i < s.len and s[i] == ',':
      inc i

proc includePaths*(g: ScopeGroup): seq[ScopePath] {.inline.} =
  g.includes

proc excludePaths*(g: ScopeGroup): seq[ScopePath] {.inline.} =
  g.excludes
