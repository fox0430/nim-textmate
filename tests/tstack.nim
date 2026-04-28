import std/unittest

import textmate
import textmate/types

suite "stack":
  test "initialStack contributes the grammar's scope name":
    let jsonStr = """{ "scopeName": "source.test", "patterns": [] }"""
    let g = compileGrammar(parseRawGrammar(jsonStr))
    let s = initialStack(g)

    check s.parent == nil
    check s.grammar == g
    check s.contentName == "source.test"
    check fullScopes(s) == @["source.test"]

  test "fullScopes walks parent chain root-first and skips empty contentName":
    let jsonStr = """{ "scopeName": "source.test", "patterns": [] }"""
    let g = compileGrammar(parseRawGrammar(jsonStr))
    let root = initialStack(g)
    let mid = StackElement(parent: root, grammar: g, contentName: "")
    let leaf = StackElement(parent: mid, grammar: g, contentName: "string.quoted")

    check fullScopes(leaf) == @["source.test", "string.quoted"]

  test "fullScopes returns identical value on repeated calls (cache safety)":
    # Guards the lazy-memoisation in fullScopes: populating the cache on
    # first access must not perturb the return value on subsequent calls,
    # and must not leak state into parent or sibling frames.
    let jsonStr = """{ "scopeName": "source.test", "patterns": [] }"""
    let g = compileGrammar(parseRawGrammar(jsonStr))
    let root = initialStack(g)
    let mid = StackElement(parent: root, grammar: g, contentName: "")
    let leaf = StackElement(parent: mid, grammar: g, contentName: "string.quoted")

    let first = fullScopes(leaf)
    let second = fullScopes(leaf)
    check first == second
    check second == @["source.test", "string.quoted"]
    # The parent chain stays correct after the leaf's cache was filled.
    check fullScopes(root) == @["source.test"]
    check fullScopes(mid) == @["source.test"]
