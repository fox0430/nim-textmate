# Package

version = "0.1.0"
author = "fox0430"
description = "A TextMate grammar parser"
license = "MIT"

# Dependencies

requires "nim >= 2.0.0"
requires "reni >= 0.1.0"

task bench, "Run the textmate + reni benchmark suite":
  exec "nim c -d:release -r bench/bench_textmate.nim"
  exec "nim c -d:release -r bench/bench_reni.nim"
