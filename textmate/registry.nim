import std/tables

import pkg/reni

import ./[types, rule]

proc newRegistry*(): Registry =
  ## Create an empty `Registry` of compiled grammars keyed by `scopeName`.
  Registry(grammars: initOrderedTable[ScopeName, Grammar]())

proc tryResolveInclude(reg: Registry, r: Rule): bool =
  ## Attempt to cross-link one `rkInclude` rule against the registry.
  ## Returns true when the rule is either fully linked or does not need
  ## a cross-grammar lookup (`$self`, `$base`, `#name`). Returns false
  ## only when the include points to a scope that is not yet registered.
  case r.includeKind
  of ikSelf, ikBase, ikRepo, ikInvalid:
    true
  of ikGrammar:
    if r.resolvedGrammar != nil:
      true
    elif reg.grammars.hasKey(r.includeScope):
      r.resolvedGrammar = reg.grammars[r.includeScope]
      true
    else:
      false
  of ikGrammarRepo:
    if r.resolvedGrammar != nil:
      true
    elif reg.grammars.hasKey(r.includeScope):
      let target = reg.grammars[r.includeScope]
      r.resolvedGrammar = target
      if target.repository.hasKey(r.includeRepoName):
        r.resolvedRule = target.repository[r.includeRepoName]
      # Missing repo key is a soft failure: the expansion pass treats a
      # nil resolvedRule as a no-op. The scope itself is resolved, so
      # the grammar exits the pending queue.
      true
    else:
      false

proc linkCrossGrammar(reg: Registry, g: Grammar): bool =
  ## Resolve every cross-grammar include owned by `g`. Returns true when
  ## all such includes link cleanly; false when at least one points to a
  ## scope still absent from the registry.
  result = true
  for r in g.includeRules:
    if not tryResolveInclude(reg, r):
      result = false

proc addGrammar*(reg: Registry, raw: RawGrammar): Grammar {.discardable.} =
  ## Compile `raw` and register it under its `scopeName`. If a grammar
  ## with the same `scopeName` already exists it is overwritten. Returns
  ## the compiled grammar (often discarded; retrieve later via
  ## `grammarForScope`). Raises `GrammarError` if compilation fails.
  ##
  ## Also runs the cross-grammar link pass: every `source.xxx` include
  ## in `raw` is bound to its target grammar, and any previously added
  ## grammar whose includes were waiting for `raw.scopeName` is retried.
  result = compileGrammar(raw)
  reg.grammars[result.scopeName] = result

  let previouslyPending = reg.pendingLinks
  reg.pendingLinks = @[]
  for candidate in previouslyPending:
    if not linkCrossGrammar(reg, candidate):
      reg.pendingLinks.add candidate
    else:
      # `candidate` was pending: at least one cross-grammar include was
      # unresolved while earlier tokenisation may have populated caches
      # whose expansion treated that include as a no-op. Now that the
      # include is bound, every cache built before this point is
      # potentially stale.
      #
      # We over-approximate: clear the root cache and every begin/end
      # rule's pattern cache. Tracking which rules transitively reach a
      # newly-resolved include would be more precise, but this only fires
      # on `addGrammar` calls (not per tokenised line) and the empty-cache
      # check below skips rules that were never touched.
      candidate.expansionCache.clear()
      for _, r in candidate.ruleById.pairs:
        if r.kind == rkBeginEnd and r.patternExpansionCache.len > 0:
          r.patternExpansionCache.clear()
  if not linkCrossGrammar(reg, result):
    reg.pendingLinks.add result

proc grammarForScope*(reg: Registry, scope: ScopeName): Grammar =
  ## Look up a registered grammar by `scopeName`. Raises `GrammarError`
  ## if no grammar with that scope has been added.
  if not reg.grammars.hasKey(scope):
    raise newException(GrammarError, "grammar not registered: " & scope)
  reg.grammars[scope]

proc matchesFirstLine*(g: Grammar, line: string): bool =
  ## True when `g` has a `firstLineMatch` regex and it matches `line`.
  if g == nil or not g.hasFirstLineMatch:
    return false
  search(line, g.firstLineMatch, start = 0).found

proc detectGrammar*(reg: Registry, firstLine: string): Grammar =
  ## Return the first registered grammar whose `firstLineMatch` hits
  ## `firstLine`, or nil when none match. Iteration follows registration
  ## order (the registry is backed by `OrderedTable`), so the earliest
  ## added grammar among the matches wins.
  for _, g in reg.grammars.pairs:
    if matchesFirstLine(g, firstLine):
      return g
  nil
