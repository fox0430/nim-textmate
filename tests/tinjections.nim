import std/unittest

import textmate

suite "grammar-level injections":
  test "self-injection adds a scope when selector matches current stack":
    # Injection targets text the base rules do not match, so priority
    # tie-breaking does not come into play here.
    let jsonStr = """
    {
      "scopeName": "source.js",
      "patterns": [ { "match": "\\balpha\\b", "name": "base.alpha" } ],
      "injections": {
        "source.js": {
          "patterns": [ { "match": "\\bbeta\\b", "name": "extra.beta" } ]
        }
      }
    }
    """
    let g = compileGrammar(parseRawGrammar(jsonStr))
    let lt = tokenizeLine("alpha beta gamma", initialStack(g))
    var sawExtra = false
    var sawBase = false
    for tok in lt.tokens:
      if "extra.beta" in tok.scopes:
        sawExtra = true
      if "base.alpha" in tok.scopes:
        sawBase = true
    check sawBase
    check sawExtra

  test "selector gates injection to matching scope only":
    # Injection selector targets `string.quoted` — should NOT fire
    # outside a quoted-string block.
    let jsonStr = """
    {
      "scopeName": "source.js",
      "patterns": [
        { "begin": "\"", "end": "\"", "name": "string.quoted" },
        { "match": "TODO", "name": "plain.todo" }
      ],
      "injections": {
        "string.quoted": {
          "patterns": [ { "match": "TODO", "name": "extra.inside-string" } ]
        }
      }
    }
    """
    let g = compileGrammar(parseRawGrammar(jsonStr))
    # Outside string: injection must not fire.
    let lt1 = tokenizeLine("TODO out", initialStack(g))
    for tok in lt1.tokens:
      check "extra.inside-string" notin tok.scopes

    # Inside string: injection fires.
    let lt2 = tokenizeLine("\"TODO\"", initialStack(g))
    var sawInside = false
    for tok in lt2.tokens:
      if "extra.inside-string" in tok.scopes:
        sawInside = true
    check sawInside

  test "L-priority injection wins the tie against a base rule at the same position":
    let jsonStr = """
    {
      "scopeName": "source.js",
      "patterns": [ { "match": "foo", "name": "base.foo" } ],
      "injections": {
        "L:source.js": {
          "patterns": [ { "match": "foo", "name": "injection.foo" } ]
        }
      }
    }
    """
    let g = compileGrammar(parseRawGrammar(jsonStr))
    let lt = tokenizeLine("foo", initialStack(g))
    var sawInjection = false
    var sawBase = false
    for tok in lt.tokens:
      if "injection.foo" in tok.scopes:
        sawInjection = true
      if "base.foo" in tok.scopes:
        sawBase = true
    check sawInjection
    check not sawBase

  test "default-priority injection loses tie to a base rule at the same position":
    let jsonStr = """
    {
      "scopeName": "source.js",
      "patterns": [ { "match": "foo", "name": "base.foo" } ],
      "injections": {
        "source.js": {
          "patterns": [ { "match": "foo", "name": "injection.foo" } ]
        }
      }
    }
    """
    let g = compileGrammar(parseRawGrammar(jsonStr))
    let lt = tokenizeLine("foo", initialStack(g))
    var sawBase = false
    var sawInjection = false
    for tok in lt.tokens:
      if "base.foo" in tok.scopes:
        sawBase = true
      if "injection.foo" in tok.scopes:
        sawInjection = true
    check sawBase
    check not sawInjection

  test "two L injections at the same position: first-declared wins":
    # Both injections target the same scope and match the same text.
    # Ties within the same priority bucket go to the earliest entry.
    let jsonStr = """
    {
      "scopeName": "source.js",
      "patterns": [],
      "injections": {
        "L:source.js": {
          "patterns": [ { "match": "foo", "name": "injection.first" } ]
        },
        "L:source.js ": {
          "patterns": [ { "match": "foo", "name": "injection.second" } ]
        }
      }
    }
    """
    let g = compileGrammar(parseRawGrammar(jsonStr))
    let lt = tokenizeLine("foo", initialStack(g))
    var sawFirst = false
    var sawSecond = false
    for tok in lt.tokens:
      if "injection.first" in tok.scopes:
        sawFirst = true
      if "injection.second" in tok.scopes:
        sawSecond = true
    check sawFirst
    check not sawSecond

  test "L injection beats a default injection at the same position":
    let jsonStr = """
    {
      "scopeName": "source.js",
      "patterns": [],
      "injections": {
        "source.js": {
          "patterns": [ { "match": "foo", "name": "injection.default" } ]
        },
        "L:source.js": {
          "patterns": [ { "match": "foo", "name": "injection.lpri" } ]
        }
      }
    }
    """
    let g = compileGrammar(parseRawGrammar(jsonStr))
    let lt = tokenizeLine("foo", initialStack(g))
    var sawDefault = false
    var sawL = false
    for tok in lt.tokens:
      if "injection.default" in tok.scopes:
        sawDefault = true
      if "injection.lpri" in tok.scopes:
        sawL = true
    check sawL
    check not sawDefault

  test "two default injections at the same position: first-declared wins":
    let jsonStr = """
    {
      "scopeName": "source.js",
      "patterns": [],
      "injections": {
        "source.js": {
          "patterns": [ { "match": "foo", "name": "injection.first" } ]
        },
        "source.js ": {
          "patterns": [ { "match": "foo", "name": "injection.second" } ]
        }
      }
    }
    """
    let g = compileGrammar(parseRawGrammar(jsonStr))
    let lt = tokenizeLine("foo", initialStack(g))
    var sawFirst = false
    var sawSecond = false
    for tok in lt.tokens:
      if "injection.first" in tok.scopes:
        sawFirst = true
      if "injection.second" in tok.scopes:
        sawSecond = true
    check sawFirst
    check not sawSecond

  test "R-priority injection loses tie to a base rule at the same position":
    let jsonStr = """
    {
      "scopeName": "source.js",
      "patterns": [ { "match": "foo", "name": "base.foo" } ],
      "injections": {
        "R:source.js": {
          "patterns": [ { "match": "foo", "name": "injection.rpri" } ]
        }
      }
    }
    """
    let g = compileGrammar(parseRawGrammar(jsonStr))
    let lt = tokenizeLine("foo", initialStack(g))
    var sawBase = false
    var sawR = false
    for tok in lt.tokens:
      if "base.foo" in tok.scopes:
        sawBase = true
      if "injection.rpri" in tok.scopes:
        sawR = true
    check sawBase
    check not sawR

  test "R-priority injection loses tie to a default injection at the same position":
    # Declare the R-priority entry first so a naive first-wins fallback would
    # pick it; the priority bucket must put default strictly above R.
    let jsonStr = """
    {
      "scopeName": "source.js",
      "patterns": [],
      "injections": {
        "R:source.js": {
          "patterns": [ { "match": "foo", "name": "injection.rpri" } ]
        },
        "source.js": {
          "patterns": [ { "match": "foo", "name": "injection.default" } ]
        }
      }
    }
    """
    let g = compileGrammar(parseRawGrammar(jsonStr))
    let lt = tokenizeLine("foo", initialStack(g))
    var sawDefault = false
    var sawR = false
    for tok in lt.tokens:
      if "injection.default" in tok.scopes:
        sawDefault = true
      if "injection.rpri" in tok.scopes:
        sawR = true
    check sawDefault
    check not sawR

  test "L injection beats R injection at the same position":
    # R entry is declared first; L must still win on priority alone.
    let jsonStr = """
    {
      "scopeName": "source.js",
      "patterns": [],
      "injections": {
        "R:source.js": {
          "patterns": [ { "match": "foo", "name": "injection.rpri" } ]
        },
        "L:source.js": {
          "patterns": [ { "match": "foo", "name": "injection.lpri" } ]
        }
      }
    }
    """
    let g = compileGrammar(parseRawGrammar(jsonStr))
    let lt = tokenizeLine("foo", initialStack(g))
    var sawL = false
    var sawR = false
    for tok in lt.tokens:
      if "injection.lpri" in tok.scopes:
        sawL = true
      if "injection.rpri" in tok.scopes:
        sawR = true
    check sawL
    check not sawR

suite "registry-level injections (injectionSelector)":
  test "grammar with injectionSelector contributes rules to another grammar":
    let jsonA = """
    {
      "scopeName": "source.a",
      "patterns": [ { "match": "\\w+", "name": "word" } ]
    }
    """
    let jsonB = """
    {
      "scopeName": "source.b",
      "injectionSelector": "L:source.a",
      "patterns": [ { "match": "SPECIAL", "name": "from.b" } ]
    }
    """
    let reg = newRegistry()
    discard reg.addGrammar(parseRawGrammar(jsonA))
    discard reg.addGrammar(parseRawGrammar(jsonB))
    let gA = reg.grammarForScope("source.a")
    let lt = tokenizeLine("SPECIAL word", initialStack(gA, reg))
    var sawFromB = false
    for tok in lt.tokens:
      if "from.b" in tok.scopes:
        sawFromB = true
    check sawFromB

  test "registry injection does not fire when no registry is passed":
    # Without registry context, B's cross-grammar injection is invisible.
    let jsonA = """
    {
      "scopeName": "source.a",
      "patterns": [ { "match": "\\w+", "name": "word" } ]
    }
    """
    let jsonB = """
    {
      "scopeName": "source.b",
      "injectionSelector": "L:source.a",
      "patterns": [ { "match": "SPECIAL", "name": "from.b" } ]
    }
    """
    let reg = newRegistry()
    discard reg.addGrammar(parseRawGrammar(jsonA))
    discard reg.addGrammar(parseRawGrammar(jsonB))
    let gA = reg.grammarForScope("source.a")
    # No registry argument -> no cross-grammar discovery.
    let lt = tokenizeLine("SPECIAL word", initialStack(gA))
    for tok in lt.tokens:
      check "from.b" notin tok.scopes

  test "registry R-priority injectionSelector loses tie to default-priority":
    # Register the R-priority grammar first so OrderedTable iteration puts it
    # ahead of the default-priority one; default must still win on priority.
    # Base has no rule matching "foo", so the contest is purely between the
    # two injection buckets.
    let jsonA = """
    {
      "scopeName": "source.a",
      "patterns": [ { "match": "\\bbar\\b", "name": "base.bar" } ]
    }
    """
    let jsonR = """
    {
      "scopeName": "source.r",
      "injectionSelector": "R:source.a",
      "patterns": [ { "match": "\\bfoo\\b", "name": "from.r" } ]
    }
    """
    let jsonD = """
    {
      "scopeName": "source.d",
      "injectionSelector": "source.a",
      "patterns": [ { "match": "\\bfoo\\b", "name": "from.d" } ]
    }
    """
    let reg = newRegistry()
    discard reg.addGrammar(parseRawGrammar(jsonA))
    discard reg.addGrammar(parseRawGrammar(jsonR))
    discard reg.addGrammar(parseRawGrammar(jsonD))
    let gA = reg.grammarForScope("source.a")
    let lt = tokenizeLine("foo", initialStack(gA, reg))
    var sawDefault = false
    var sawR = false
    for tok in lt.tokens:
      if "from.d" in tok.scopes:
        sawDefault = true
      if "from.r" in tok.scopes:
        sawR = true
    check sawDefault
    check not sawR
