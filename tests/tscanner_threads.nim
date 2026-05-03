import std/[atomics, unittest]

import textmate

# `Grammar` is thread-confined: a single compiled `Grammar` must only
# be tokenised against from one thread. This test exercises the
# supported pattern for parallel tokenisation — each worker compiles
# its own `Grammar` from the shared `RawGrammar` JSON and tokenises
# against that.
#
# Why per-thread compile is required: reni's `Regex` (held by every
# `Rule`'s `matchRegex` / `beginRegex` / `terminatorRegex`) does not
# support concurrent `searchIntoCtx` calls against the same instance.
# Sharing a compiled `Grammar` therefore deadlocks or corrupts memory
# for any non-trivial grammar (notably one with nested `patterns`
# inside a begin/end block, which is what most realistic grammars
# look like). The grammar below intentionally includes that shape so
# the test would detect regressions where compiled state leaked
# across threads.

const GrammarJson = """
{
  "scopeName": "source.test",
  "patterns": [
    { "match": "\\bfoo\\b", "name": "kw.foo" },
    { "match": "\\bbar\\b", "name": "kw.bar" },
    { "match": "\\b[A-Z][A-Za-z0-9_]*\\b", "name": "type.name" },
    {
      "begin": "\"",
      "end": "\"",
      "name": "string.quoted",
      "contentName": "meta.string.body",
      "patterns": [
        { "match": "\\\\.", "name": "constant.character.escape" },
        { "match": "\\$\\w+", "name": "variable.embedded" }
      ]
    },
    {
      "begin": "/\\*",
      "end": "\\*/",
      "name": "comment.block",
      "patterns": [
        { "match": "\\bTODO\\b", "name": "keyword.todo" },
        { "match": "\\bfoo\\b", "name": "kw.foo.in.comment" }
      ]
    }
  ]
}
"""

const TestLines = [
  "foo bar baz qux", "the \"quoted text with foo\" and bar inside",
  "\"abc $var\" foo \"def\\n\" bar \"xyz\"",
  "/* TODO block comment with foo */ trailing bar", "Type1 Type2 foo bar Mixed mixed",
  "no matches here just plain text", "\"abc $start", "still in string foo bar $cont",
  "ending\\n\" outside the string", "/* multi", "line bar foo TODO", "still */ after",
]

proc tokenizeAllOnce(g: Grammar): seq[seq[Token]] =
  var stack = initialStack(g)
  for line in TestLines:
    let lt = tokenizeLine(line, stack)
    result.add lt.tokens
    stack = lt.ruleStack

# Baseline computed single-threaded on its own `Grammar`. Workers
# parse and compile their own `Grammar` from the same JSON literal —
# `GrammarJson` is a `const`, hence safe to read from any thread.
let BaselineGrammar = compileGrammar(parseRawGrammar(GrammarJson))
let Baseline = tokenizeAllOnce(BaselineGrammar)

proc tokensMatch(a, b: seq[Token]): bool =
  if a.len != b.len:
    return false
  for i in 0 ..< a.len:
    if a[i].startIndex != b[i].startIndex:
      return false
    if a[i].endIndex != b[i].endIndex:
      return false
    if a[i].scopes != b[i].scopes:
      return false
  true

var failureCount: Atomic[int]

type WorkerArgs = object
  iters: int

proc worker(args: WorkerArgs) {.thread, gcsafe.} =
  # `Baseline`, `TestLines` and `GrammarJson` are immutable globals
  # populated before any thread is spawned; reads from worker threads
  # do not race with any writer. The cast tells Nim's gcsafe checker
  # we have established this contract manually.
  {.cast(gcsafe).}:
    let g = compileGrammar(parseRawGrammar(GrammarJson))
    for _ in 1 .. args.iters:
      var stack = initialStack(g)
      for j, line in TestLines:
        let lt = tokenizeLine(line, stack)
        if not tokensMatch(lt.tokens, Baseline[j]):
          discard failureCount.fetchAdd(1)
        stack = lt.ruleStack

suite "thread-confined Grammar":
  test "concurrent tokenizeLine with one Grammar per thread reproduces the baseline":
    # Each worker compiles its own `Grammar` from the shared JSON, then
    # tokenises the corpus repeatedly. The grammar deliberately exercises
    # the paths that would have raced if `Grammar` were shared:
    # `expansionCache`, `patternExpansionCache` (via the nested
    # `patterns` in both begin/end rules), and per-rule cached match
    # state. With per-thread `Grammar`, no cross-thread state remains
    # and the test must complete deterministically.
    failureCount.store(0)
    const NThreads = 8
    const Iters = 200
    var threads: array[NThreads, Thread[WorkerArgs]]
    for i in 0 ..< NThreads:
      createThread(threads[i], worker, WorkerArgs(iters: Iters))
    joinThreads(threads)
    check failureCount.load == 0
