## Macro-benchmark for the textmate tokenizer.
##
## Compiles the bundled Nim grammar and tokenises a large synthetic
## document, reporting wall time, lines/sec, and bytes/sec.
##
## Build & run:
##   nim c -d:release --opt:speed bench/bench_textmate.nim
##   ./bench/bench_textmate
##
## Flags:
##   --lines=N      number of lines to tokenize (default 5000)
##   --warmup=N     number of warmup runs (default 1)
##   --runs=N       number of timed runs (default 5)

import std/[monotimes, os, strformat, strutils, times]

import pkg/textmate

import ./grammars
import ./source_samples

type Config = object
  lines: int
  warmup: int
  runs: int

proc parseFlags(): Config =
  result = Config(lines: 5000, warmup: 1, runs: 5)
  for i in 1 .. paramCount():
    let p = paramStr(i)
    if p.startsWith("--lines="):
      result.lines = parseInt(p.substr("--lines=".len))
    elif p.startsWith("--warmup="):
      result.warmup = parseInt(p.substr("--warmup=".len))
    elif p.startsWith("--runs="):
      result.runs = parseInt(p.substr("--runs=".len))
    else:
      stderr.writeLine "unknown flag: ", p
      quit(1)
  if result.runs < 1:
    stderr.writeLine "--runs must be >= 1 (got ", result.runs, ")"
    quit(1)
  if result.lines < 1:
    stderr.writeLine "--lines must be >= 1 (got ", result.lines, ")"
    quit(1)
  if result.warmup < 0:
    stderr.writeLine "--warmup must be >= 0 (got ", result.warmup, ")"
    quit(1)

proc tokenizeAll(g: Grammar, lines: seq[string]): tuple[tokens, bytes: int] =
  var stack = initialStack(g)
  var totalTokens = 0
  var totalBytes = 0
  for line in lines:
    let lt = tokenizeLine(line, stack)
    totalTokens += lt.tokens.len
    totalBytes += line.len
    stack = lt.ruleStack
  (totalTokens, totalBytes)

proc fmtSecs(ns: int64): string =
  let s = ns.float / 1.0e9
  if s >= 1.0:
    fmt"{s:>7.3f}s"
  else:
    fmt"{ns.float / 1.0e6:>6.2f}ms"

proc fmtNum(n: float): string =
  if n >= 1.0e6:
    fmt"{n / 1.0e6:>7.2f}M"
  elif n >= 1.0e3:
    fmt"{n / 1.0e3:>7.2f}K"
  else:
    fmt"{n:>9.2f}"

proc main() =
  let cfg = parseFlags()
  echo "textmate tokenizer benchmark"
  echo "  lines  = ", cfg.lines
  echo "  warmup = ", cfg.warmup
  echo "  runs   = ", cfg.runs
  echo ""

  let compileStart = getMonoTime()
  let g = compileGrammar(parseRawGrammar(NimGrammarJson))
  let compileNs = (getMonoTime() - compileStart).inNanoseconds
  echo fmt"grammar compile: {fmtSecs(compileNs)}"

  let lines = replicateLinesMix([NimSourceSample, NimSourceDenseSample], cfg.lines)
  var totalBytes = 0
  for ln in lines:
    totalBytes += ln.len
  echo fmt"input: {lines.len} lines, {totalBytes} bytes"
  echo ""

  for i in 1 .. cfg.warmup:
    discard tokenizeAll(g, lines)

  var bestNs = high(int64)
  var sumNs: int64 = 0
  var lastTokens = 0
  for run in 1 .. cfg.runs:
    let t0 = getMonoTime()
    let (tokens, _) = tokenizeAll(g, lines)
    let dt = (getMonoTime() - t0).inNanoseconds
    lastTokens = tokens
    sumNs += dt
    if dt < bestNs:
      bestNs = dt
    let linesPerSec = lines.len.float / (dt.float / 1.0e9)
    let bytesPerSec = totalBytes.float / (dt.float / 1.0e9)
    echo fmt"  run {run}: {fmtSecs(dt)}  {fmtNum(linesPerSec)} lines/s  {fmtNum(bytesPerSec)} B/s  tokens={tokens}"

  let avgNs = sumNs div cfg.runs
  echo ""
  echo fmt"best:  {fmtSecs(bestNs)}  ({fmtNum(lines.len.float / (bestNs.float / 1.0e9))} lines/s)"
  echo fmt"avg:   {fmtSecs(avgNs)}"
  echo fmt"tokens emitted: {lastTokens}"

main()
