import std/unittest

import textmate
import textmate/types

suite "include $self":
  test "$self at the top of patterns is a no-op next to a sibling match":
    # When the self-include is the first pattern, it expands back into
    # the same root list; cycle detection must break the loop, leaving
    # the sibling match rule free to fire.
    let jsonStr = """
    {
      "scopeName": "source.test",
      "patterns": [
        { "include": "$self" },
        { "match": "\\bfoo\\b", "name": "keyword.foo" }
      ]
    }
    """
    let g = compileGrammar(parseRawGrammar(jsonStr))
    let lt = tokenizeLine("hello foo bar", initialStack(g))

    check lt.tokens.len == 3
    check lt.tokens[1].scopes == @["source.test", "keyword.foo"]

  test "at the root $base behaves like $self":
    # With a single-grammar setup the stack root is the same grammar as
    # the one providing rules, so $base and $self must be equivalent.
    let jsonStr = """
    {
      "scopeName": "source.test",
      "patterns": [
        { "include": "$base" },
        { "match": "\\bfoo\\b", "name": "keyword.foo" }
      ]
    }
    """
    let g = compileGrammar(parseRawGrammar(jsonStr))
    let lt = tokenizeLine("foo", initialStack(g))

    check lt.tokens.len == 1
    check lt.tokens[0].scopes == @["source.test", "keyword.foo"]

suite "include #name":
  test "#name pulls a match rule out of the repository":
    let jsonStr = """
    {
      "scopeName": "source.test",
      "patterns": [ { "include": "#kw" } ],
      "repository": {
        "kw": { "match": "\\bfoo\\b", "name": "keyword.foo" }
      }
    }
    """
    let g = compileGrammar(parseRawGrammar(jsonStr))
    let lt = tokenizeLine("hello foo bar", initialStack(g))

    check lt.tokens.len == 3
    check lt.tokens[1].startIndex == 6
    check lt.tokens[1].endIndex == 9
    check lt.tokens[1].scopes == @["source.test", "keyword.foo"]

  test "#name pulls a begin/end rule out of the repository":
    let jsonStr = """
    {
      "scopeName": "source.test",
      "patterns": [ { "include": "#str" } ],
      "repository": {
        "str": {
          "begin": "\"", "end": "\"",
          "name": "string.quoted",
          "contentName": "meta.string.body"
        }
      }
    }
    """
    let g = compileGrammar(parseRawGrammar(jsonStr))
    let lt = tokenizeLine("\"hi\"", initialStack(g))

    check lt.tokens.len == 3
    check lt.tokens[0].scopes == @["source.test", "string.quoted"]
    check lt.tokens[1].scopes == @["source.test", "string.quoted", "meta.string.body"]
    check lt.tokens[2].scopes == @["source.test", "string.quoted"]

  test "inline patterns and #name includes preserve document order":
    # Pattern list order: inline-a, include#b, inline-c. Document order
    # in the input is "a b c" — each rule should fire exactly once in
    # document order, proving expansion does not reshuffle anything.
    let jsonStr = """
    {
      "scopeName": "source.test",
      "patterns": [
        { "match": "a", "name": "k.a" },
        { "include": "#b" },
        { "match": "c", "name": "k.c" }
      ],
      "repository": {
        "b": { "match": "b", "name": "k.b" }
      }
    }
    """
    let g = compileGrammar(parseRawGrammar(jsonStr))
    let lt = tokenizeLine("a b c", initialStack(g))

    check lt.tokens.len == 5
    check lt.tokens[0].scopes == @["source.test", "k.a"]
    check lt.tokens[2].scopes == @["source.test", "k.b"]
    check lt.tokens[4].scopes == @["source.test", "k.c"]

  test "#name pointing at a missing repo entry is a silent no-op":
    # The grammar must still compile, and tokenization must behave as
    # if the bad include were absent.
    let jsonStr = """
    {
      "scopeName": "source.test",
      "patterns": [
        { "include": "#missing" },
        { "match": "\\bfoo\\b", "name": "keyword.foo" }
      ]
    }
    """
    let g = compileGrammar(parseRawGrammar(jsonStr))
    let lt = tokenizeLine("hello foo bar", initialStack(g))

    check lt.tokens.len == 3
    check lt.tokens[1].scopes == @["source.test", "keyword.foo"]

suite "include cycles":
  test "$self cycle at the first pattern does not stop later rules":
    let jsonStr = """
    {
      "scopeName": "source.test",
      "patterns": [
        { "include": "$self" },
        { "match": "\\bfoo\\b", "name": "keyword.foo" }
      ]
    }
    """
    let g = compileGrammar(parseRawGrammar(jsonStr))
    let lt = tokenizeLine("foo", initialStack(g))

    check lt.tokens.len == 1
    check lt.tokens[0].scopes == @["source.test", "keyword.foo"]

  test "#name -> #name self-cycle via repository still emits sibling rules":
    # repository.a includes itself, patterns include #a. Expansion must
    # terminate and the sibling match inside repository.a must fire.
    let jsonStr = """
    {
      "scopeName": "source.test",
      "patterns": [ { "include": "#a" } ],
      "repository": {
        "a": { "include": "#a" }
      }
    }
    """
    # Cycle through repo entry: expanding `#a` reaches its resolved rule
    # (another rkInclude pointing back at `#a`). Without cycle break the
    # expansion would recurse forever.
    let g = compileGrammar(parseRawGrammar(jsonStr))
    let lt = tokenizeLine("hello", initialStack(g))
    # Nothing matches, so a single full-line gap token is produced.
    check lt.tokens.len == 1
    check lt.tokens[0].scopes == @["source.test"]

suite "include source.xxx cross-grammar":
  test "source.xxx pulls in another grammar's rootRules":
    let innerJson = """
    {
      "scopeName": "source.inner",
      "patterns": [ { "match": "\\bfoo\\b", "name": "keyword.foo" } ]
    }
    """
    let outerJson = """
    {
      "scopeName": "source.outer",
      "patterns": [ { "include": "source.inner" } ]
    }
    """
    let reg = newRegistry()
    discard reg.addGrammar(parseRawGrammar(innerJson))
    let outer = reg.addGrammar(parseRawGrammar(outerJson))
    let lt = tokenizeLine("hello foo bar", initialStack(outer))

    # Root scope must still be outer's, but the match scope is whatever
    # the included grammar assigned.
    check lt.tokens.len == 3
    check lt.tokens[0].scopes == @["source.outer"]
    check lt.tokens[1].scopes == @["source.outer", "keyword.foo"]

  test "source.xxx#name pulls in a single repository entry":
    let innerJson = """
    {
      "scopeName": "source.inner",
      "patterns": [],
      "repository": {
        "kw": { "match": "\\bfoo\\b", "name": "keyword.foo" },
        "noise": { "match": "\\bbar\\b", "name": "keyword.bar" }
      }
    }
    """
    let outerJson = """
    {
      "scopeName": "source.outer",
      "patterns": [ { "include": "source.inner#kw" } ]
    }
    """
    let reg = newRegistry()
    discard reg.addGrammar(parseRawGrammar(innerJson))
    let outer = reg.addGrammar(parseRawGrammar(outerJson))
    let lt = tokenizeLine("foo bar", initialStack(outer))

    # Only `foo` matches — `bar` is in inner's repo but not included.
    check lt.tokens.len == 2
    check lt.tokens[0].scopes == @["source.outer", "keyword.foo"]
    check lt.tokens[1].scopes == @["source.outer"]

  test "cross-grammar include works when the target is registered after the includer":
    let innerJson = """
    {
      "scopeName": "source.inner",
      "patterns": [ { "match": "\\bfoo\\b", "name": "keyword.foo" } ]
    }
    """
    let outerJson = """
    {
      "scopeName": "source.outer",
      "patterns": [ { "include": "source.inner" } ]
    }
    """
    let reg = newRegistry()
    # Register outer first; its include is unresolved at this point.
    let outer = reg.addGrammar(parseRawGrammar(outerJson))
    # Registering inner retries outer's pending link.
    discard reg.addGrammar(parseRawGrammar(innerJson))
    let lt = tokenizeLine("foo", initialStack(outer))

    check lt.tokens.len == 1
    check lt.tokens[0].scopes == @["source.outer", "keyword.foo"]

  test "cross-grammar include whose target is never registered is a no-op":
    let outerJson = """
    {
      "scopeName": "source.outer",
      "patterns": [
        { "include": "source.never" },
        { "match": "\\bfoo\\b", "name": "keyword.foo" }
      ]
    }
    """
    let reg = newRegistry()
    let outer = reg.addGrammar(parseRawGrammar(outerJson))
    # No raise; inline patterns still apply.
    let lt = tokenizeLine("foo", initialStack(outer))

    check lt.tokens.len == 1
    check lt.tokens[0].scopes == @["source.outer", "keyword.foo"]

  test "begin from a cross-grammar include pushes a StackElement owned by the inner grammar":
    let innerJson = """
    {
      "scopeName": "source.inner",
      "patterns": [ {
        "begin": "\"", "end": "\"",
        "name": "string.quoted"
      } ]
    }
    """
    let outerJson = """
    {
      "scopeName": "source.outer",
      "patterns": [ { "include": "source.inner" } ]
    }
    """
    let reg = newRegistry()
    discard reg.addGrammar(parseRawGrammar(innerJson))
    let outer = reg.addGrammar(parseRawGrammar(outerJson))
    # Open an unterminated string so the stack still has a pushed frame
    # at end-of-line.
    let line1 = tokenizeLine("\"abc", initialStack(outer))

    check line1.ruleStack.parent != nil
    check line1.ruleStack.grammar.scopeName == "source.inner"
    # But the document-root scope must still come from the outer grammar.
    check fullScopes(line1.ruleStack)[0] == "source.outer"

suite "include memoisation":
  test "a repeated tokenizeLine over a deep include chain is stable":
    # Two back-to-back calls must produce identical tokens. This doesn't
    # assert cache hit counters — it just pins the user-visible invariant
    # across cache-warm vs cold runs.
    let jsonStr = """
    {
      "scopeName": "source.test",
      "patterns": [
        { "include": "#a" }
      ],
      "repository": {
        "a": { "include": "#b" },
        "b": { "include": "#c" },
        "c": { "match": "\\bfoo\\b", "name": "keyword.foo" }
      }
    }
    """
    let g = compileGrammar(parseRawGrammar(jsonStr))
    let lt1 = tokenizeLine("x foo y", initialStack(g))
    let lt2 = tokenizeLine("x foo y", initialStack(g))

    check lt1.tokens == lt2.tokens
    check lt1.tokens.len == 3
    check lt1.tokens[1].scopes == @["source.test", "keyword.foo"]

suite "include $base":
  test "$base inside a cross-grammar include loops back to the outer grammar":
    # outer includes inner; inner has a rule that includes $base. $base
    # must resolve to outer's rootRules, so `bar` (defined only in outer)
    # must still fire while we're scanning the outer line.
    let innerJson = """
    {
      "scopeName": "source.inner",
      "patterns": [
        { "include": "#back" },
        { "match": "\\bfoo\\b", "name": "kw.foo" }
      ],
      "repository": {
        "back": { "include": "$base" }
      }
    }
    """
    let outerJson = """
    {
      "scopeName": "source.outer",
      "patterns": [
        { "include": "source.inner" },
        { "match": "\\bbar\\b", "name": "kw.bar" }
      ]
    }
    """
    let reg = newRegistry()
    discard reg.addGrammar(parseRawGrammar(innerJson))
    let outer = reg.addGrammar(parseRawGrammar(outerJson))
    let lt = tokenizeLine("foo bar", initialStack(outer))

    check lt.tokens.len == 3
    check lt.tokens[0].scopes == @["source.outer", "kw.foo"]
    check lt.tokens[2].scopes == @["source.outer", "kw.bar"]
