## textmate - A TextMate grammar parser in Nim.
##
## Minimal scope (match rules only): parse a tmLanguage grammar (JSON), register
## it with a `Registry`, and tokenize lines via `tokenizeLine`.
##
## Basic usage
## ===========
##
## .. code-block:: nim
##   import textmate
##
##   let g = compileGrammar(parseRawGrammar(jsonStr))
##   var stack = initialStack(g)
##   let lt = tokenizeLine("hello foo bar", stack)
##   for tok in lt.tokens:
##     echo tok

import textmate/[types, grammar, rule, registry, tokenizer, selector, theme, editor]

# Types
export
  ScopeName, RawGrammar, Grammar, Registry, Token, StackElement, LineTokens,
  GrammarError, SelectorPriority, ScopePath, ScopeGroup, SelectorExpr, ScopeId,
  ScopeIdMap, TokenMetadata, MetadataToken, MetadataLineTokens, DefaultMetadata,
  ThemeError, FontStyle, ColorId, ColorMap, ThemeStyle, RawThemeRule, RawTheme,
  ThemeRule, Theme, DocumentTokens

# Constants
export NoColor, fsNotSet, fsNone, fsItalic, fsBold, fsUnderline, fsStrikethrough

# Borrowed operators on `TokenMetadata` and `FontStyle`. `export` by type
# name does not carry these along, so the operator-qualified form is
# required.
export `==`, `and`, `or`, `shr`, `shl`, `$`

export
  # Procs
  parseRawGrammar,
  compileGrammar,
  newRegistry,
  addGrammar,
  grammarForScope,
  matchesFirstLine,
  detectGrammar,
  initialStack,
  tokenizeLine,
  tokenizeDocument,
  tokenizeDocumentIter,
  newScopeIdMap,
  internScope,
  lookupScope,
  tokenizeLineMetadata,
  tokenizeDocumentMetadata,
  tokenizeDocumentMetadataIter,
  fullScopes,
  stackEquals,
  newDocumentTokens,
  numLines,
  getLine,
  setLines,
  applyEdit,
  parseRawTheme,
  compileTheme,
  resolveTheme,
  newColorMap,
  internColor,
  lookupColor,
  parseFontStyle,
  selector.parseSelector,
  selector.matches,
  selector.isEmpty
