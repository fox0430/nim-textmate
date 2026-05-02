## Source-code fixtures fed to the tokenizer.
##
## `NimSourceSample` is a moderate sample biased toward typical
## hand-written code: roughly half comments / blank lines, the rest
## short statements. `NimSourceDenseSample` is deliberately
## token-dense — long expressions packed with numbers, strings,
## type annotations, and operators — so the benchmark workload does
## not over-represent the cheap "empty / single-token line" case.
##
## `replicateLinesMix` rotates between the two so the produced
## workload reflects both regimes.

import std/strutils

const NimSourceSample* = """
## A small sample of Nim code used for benchmarking.
##
## It intentionally mixes comments, strings, numbers, type annotations,
## control flow, and procedure declarations to give the textmate
## tokenizer a realistic workload.

import std/[strutils, sequtils, tables, options]

const
  MaxItems = 1024
  Greeting = "Hello, world!\n"
  Pi = 3.14159265

type
  Color = enum
    cRed, cGreen, cBlue
  Point = object
    x, y: float
    label: string
  Shape = ref object of RootObj
    color: Color

proc add(a, b: int): int =
  ## Returns the sum.
  result = a + b

proc fib(n: int): int =
  if n < 2:
    return n
  var a = 0
  var b = 1
  for i in 2 .. n:
    let c = a + b
    a = b
    b = c
  result = b

proc greet(name: string = "world"): string =
  result = "Hello, " & name & "!"

proc isPrime(n: int): bool =
  if n < 2: return false
  if n mod 2 == 0: return n == 2
  var i = 3
  while i * i <= n:
    if n mod i == 0:
      return false
    i += 2
  result = true

iterator countUp(start, finish: int): int =
  var i = start
  while i <= finish:
    yield i
    inc i

template withLog(label: string, body: untyped): untyped =
  echo "[", label, "] start"
  body
  echo "[", label, "] done"

when isMainModule:
  echo Greeting
  echo "fib(10) = ", fib(10)
  echo "is 17 prime? ", isPrime(17)
  for k in countUp(1, 5):
    echo "k = ", k
  let pts = @[Point(x: 0.0, y: 0.0, label: "origin"),
              Point(x: 1.5, y: -2.25, label: "p1")]
  for p in pts:
    echo p.label, " -> (", p.x, ", ", p.y, ")"
  withLog("main"):
    discard fib(20)
"""

const NimSourceDenseSample* = """
## Token-dense companion sample. Deliberately avoids long comment
## blocks so each line carries multiple tokens (numbers, strings,
## type annotations, operators) and the tokenizer's per-token cost
## dominates over the per-line dispatch cost.

import std/[strformat, tables, sets, sequtils, strutils, options]

type
  Pair = object
    a, b: int
  Triple = tuple[x, y, z: float]

const
  Pi = 3.14159265358979
  E  = 2.71828182845904
  Hex1 = 0xDEADBEEF'u32
  Hex2 = 0xCAFEBABE'u32
  Bin  = 0b10101010'u8
  MaxItems = 1024
  Greeting = "Hello, world!\n"

let nums = @[0, 1, 2, 3, 5, 8, 13, 21, 34, 55, 89, 144, 233, 377, 610]
let names = @["alpha", "beta", "gamma", "delta", "epsilon"]
let mixed = @[(1, "a", 1.5), (2, "b", 2.5), (3, "c", 3.5)]

proc add[T: SomeNumber](a, b: T): T = a + b
proc mul[T: SomeNumber](a, b: T): T = a * b
proc clamp[T](v, lo, hi: T): T = max(lo, min(v, hi))
proc dot(u, v: Triple): float = u.x*v.x + u.y*v.y + u.z*v.z

let total = foldl(nums, a + b, 0)
let prod = foldl(nums, a * b, 1)
let mapped = mapIt(nums, it * it + 1)
let filtered = filterIt(nums, it > 10 and it < 200)
let joined = join(names, ", ")
let upper = mapIt(names, toUpperAscii(it))

echo fmt"sum={total} prod={prod} pi={Pi:.4f} e={E:.4f}"
echo fmt"hex1={Hex1:X} hex2={Hex2:X} bin={Bin:b}"
echo fmt"joined={joined} upper={upper}"

for i, n in nums:
  if n mod 2 == 0:
    echo fmt"even idx={i} val={n} sq={n*n}"
  else:
    echo fmt"odd  idx={i} val={n} sq={n*n}"

let url = "https://example.com/path?q=value&x=1#frag"
let json = "{\"key\": \"value\", \"n\": 42, \"f\": 3.14}"
let regex = "^(\\d+)\\.(\\d+)\\.(\\d+)$"
let escaped = "tab\there\nnewline\\backslash\"quote"

when defined(release):
  echo "release build, MaxItems=", MaxItems
else:
  echo "debug build, MaxItems=", MaxItems

case nums[0]
of 0..9: echo "single digit"
of 10..99: echo "two digit"
of 100..999: echo "three digit"
else: echo "many"

discard parseInt("12345")
discard parseFloat("1.5e3")
discard repeat("ab", 5)
"""

proc replicateLines*(sample: string, targetLines: int): seq[string] =
  ## Split `sample` into lines, then replicate the block until we have
  ## at least `targetLines` lines. Returns exactly `targetLines` lines.
  var base: seq[string] = @[]
  for line in splitLines(sample):
    base.add line
  if base.len == 0:
    return
  while result.len < targetLines:
    for line in base:
      if result.len >= targetLines:
        break
      result.add line

proc replicateLinesMix*(samples: openArray[string], targetLines: int): seq[string] =
  ## Rotate through `samples` block-by-block until we have `targetLines`
  ## lines. Each sample is split into a line block once; the result
  ## interleaves whole blocks (sample0, sample1, …, sample0, sample1,
  ## …) rather than line-by-line, so multi-line constructs like
  ## triple-quoted strings or block comments stay intact across the
  ## boundary inside one block.
  if samples.len == 0:
    return
  var blocks: seq[seq[string]] = @[]
  for s in samples:
    var lines: seq[string] = @[]
    for line in splitLines(s):
      lines.add line
    if lines.len > 0:
      blocks.add lines
  if blocks.len == 0:
    return
  while result.len < targetLines:
    for blk in blocks:
      for line in blk:
        if result.len >= targetLines:
          return
        result.add line
