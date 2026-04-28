import std/unittest

import textmate/selector

suite "scope selector parsing":
  test "single atom":
    let sel = parseSelector("string.quoted")
    check sel.priority == spDefault
    check sel.groups.len == 1
    check sel.groups[0].includePaths.len == 1
    check sel.groups[0].includePaths[0] == @["string.quoted"]
    check sel.groups[0].excludePaths.len == 0

  test "descendant path":
    let sel = parseSelector("meta.function string.quoted")
    check sel.groups[0].includePaths[0] == @["meta.function", "string.quoted"]

  test "comma groups":
    let sel = parseSelector("comment, string")
    check sel.groups.len == 2
    check sel.groups[0].includePaths[0] == @["comment"]
    check sel.groups[1].includePaths[0] == @["string"]

  test "exclusion":
    let sel = parseSelector("source.js - string")
    check sel.groups.len == 1
    check sel.groups[0].includePaths[0] == @["source.js"]
    check sel.groups[0].excludePaths[0] == @["string"]

  test "L: priority parsed":
    let sel = parseSelector("L:keyword")
    check sel.priority == spL
    check sel.groups[0].includePaths[0] == @["keyword"]

  test "R: priority parsed":
    let sel = parseSelector("R:keyword")
    check sel.priority == spR

suite "scope selector matching":
  test "atom prefix at dot boundary":
    let sel = parseSelector("string.quoted")
    check sel.matches(@["source.js", "string.quoted.double.js"])
    check sel.matches(@["source.js", "string.quoted"])
    check not sel.matches(@["source.js", "string.quotedfoo"])

  test "descendant ordering":
    let sel = parseSelector("meta.function string.quoted")
    check sel.matches(@["source.js", "meta.function.js", "string.quoted.double"])
    # Reversed order — must NOT match.
    check not sel.matches(@["source.js", "string.quoted", "meta.function"])

  test "OR group":
    let sel = parseSelector("comment, string.quoted")
    check sel.matches(@["source.js", "comment.line"])
    check sel.matches(@["source.js", "string.quoted.double"])
    check not sel.matches(@["source.js", "keyword.control"])

  test "exclusion blocks a match":
    let sel = parseSelector("source.js - string.quoted")
    check sel.matches(@["source.js", "keyword.control"])
    check not sel.matches(@["source.js", "string.quoted.double"])

  test "empty selector matches nothing":
    let sel = parseSelector("")
    check not sel.matches(@["source.js"])
    check sel.isEmpty
