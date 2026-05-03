## Reni-only micro-benchmark.
##
## Drives `reni.searchIntoCtx` directly with patterns extracted from
## the bundled Nim grammar so we can see what the regex engine costs
## on its own — separately from the textmate scanner / token-emit
## overhead.
##
## Build & run:
##   nim c -d:release --opt:speed bench/bench_reni.nim
##   ./bench/bench_reni

import std/[monotimes, os, strformat, strutils, times]

when defined(profiler):
  import std/nimprof

import pkg/reni

import ./source_samples

type Pat = tuple[name, pattern: string]

const Patterns: seq[Pat] = @[
  ("comment_block_begin", "#\\["),
  ("comment_line", "#.*$"),
  ("string_double_begin", "\""),
  ("string_escape", "\\\\."),
  ("string_placeholder", "\\$[A-Za-z_][A-Za-z0-9_]*"),
  ("number_float", "\\b\\d+\\.\\d+([eE][+-]?\\d+)?(['_]?[fF](32|64))?\\b"),
  ("number_hex", "\\b0[xX][0-9A-Fa-f]+(['_]?[iIuU](8|16|32|64))?\\b"),
  ("number_int", "\\b\\d+(['_]?[iIuU](8|16|32|64))?\\b"),
  (
    "kw_control",
    "\\b(if|elif|else|case|of|when|while|for|break|continue|return|yield|discard|raise|try|except|finally|defer)\\b",
  ),
  (
    "kw_decl",
    "\\b(proc|func|method|iterator|template|macro|converter|let|var|const|type|object|enum|tuple|ref|ptr)\\b",
  ),
  (
    "kw_other",
    "\\b(import|export|include|from|as|using|asm|bind|mixin|distinct|in|notin|is|isnot|of|cast|addr|and|or|xor|not|shl|shr|div|mod)\\b",
  ),
  (
    "type_support",
    "\\b(int|int8|int16|int32|int64|uint|uint8|uint16|uint32|uint64|float|float32|float64|bool|char|string|cstring|cint|cfloat|cdouble|pointer|byte|seq|array|set|range|openArray|varargs|auto|void|untyped|typed)\\b",
  ),
  ("operators", "(==|!=|<=|>=|<|>|=|\\+|-|\\*|/|%|\\.\\.|\\.\\.<|@|&|\\||\\^|~|\\?|:)"),
  ("identifier", "\\b[A-Za-z_][A-Za-z0-9_]*\\b"),
]

proc fmtSecs(ns: int64): string =
  let s = ns.float / 1.0e9
  if s >= 1.0:
    fmt"{s:>7.3f}s"
  else:
    fmt"{ns.float / 1.0e6:>6.2f}ms"

type RunStats = object
  perPatternNs: seq[int64]
  totalNs: int64
  hits: int

proc runOnce(regs: seq[Regex], ctx: MatchContext, lines: seq[string]): RunStats =
  result.perPatternNs = newSeq[int64](regs.len)
  var totalHits = 0
  let totalStart = getMonoTime()
  for pIdx, regex in regs:
    let pStart = getMonoTime()
    var hits = 0
    var m: Match
    for line in lines:
      var pos = 0
      while pos <= line.len:
        searchIntoCtx(ctx, line, regex, m, start = pos)
        if not m.found:
          break
        inc hits
        let nextPos = advanceAfterMatch(line, m.boundaries[0].b, pos)
        if nextPos < 0:
          break
        pos = nextPos
    result.perPatternNs[pIdx] = (getMonoTime() - pStart).inNanoseconds
    totalHits += hits
  result.totalNs = (getMonoTime() - totalStart).inNanoseconds
  result.hits = totalHits

proc parseLines(): int =
  result = 5000
  for i in 1 .. paramCount():
    let p = paramStr(i)
    if p.startsWith("--lines="):
      try:
        result = parseInt(p.substr("--lines=".len))
      except ValueError:
        stderr.writeLine "invalid --lines value: ", p
        quit(1)
    else:
      stderr.writeLine "unknown flag: ", p
      quit(1)

proc main() =
  let nLines = parseLines()
  let lines = replicateLinesMix([NimSourceSample, NimSourceDenseSample], nLines)
  var totalBytes = 0
  for line in lines:
    totalBytes += line.len

  echo "reni-only micro-benchmark"
  echo "  lines  = ", lines.len
  echo "  bytes  = ", totalBytes
  echo "  patterns = ", Patterns.len
  echo ""

  var regs = newSeq[Regex](Patterns.len)
  let compileStart = getMonoTime()
  for i, p in Patterns:
    regs[i] = re(p.pattern)
  let compileNs = (getMonoTime() - compileStart).inNanoseconds
  echo fmt"compile {Patterns.len} patterns: {fmtSecs(compileNs)}"
  echo ""

  let ctx = newMatchContext()
  # warmup
  discard runOnce(regs, ctx, lines)
  let stats = runOnce(regs, ctx, lines)

  echo "per-pattern findAll-equivalent timing:"
  echo "  ", "name".alignLeft(24), " ", "time".align(10), " ", "lines/s".align(12)
  for i, p in Patterns:
    let ns = stats.perPatternNs[i]
    let lps = lines.len.float / (ns.float / 1.0e9)
    echo "  ", p.name.alignLeft(24), " ", fmtSecs(ns), " ", fmt"{lps:>10.0f}".align(12)
  echo ""
  echo fmt"total:   {fmtSecs(stats.totalNs)}  hits={stats.hits}"
  echo fmt"avg per (pattern x line): {(stats.totalNs.float / (lines.len * Patterns.len).float):.1f} ns"

main()
