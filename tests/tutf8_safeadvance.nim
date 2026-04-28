import std/unittest

import textmate/tokenizer

suite "safeAdvance":
  test "ASCII advances by one byte":
    check safeAdvance("abc", 0) == 1
    check safeAdvance("abc", 1) == 2
    check safeAdvance("abc", 2) == 3

  test "multi-byte rune advances past the continuation bytes":
    # "é" is 0xC3 0xA9 (2 bytes). From pos 1 (at 'é'), we should land on pos 3.
    let s = "aé"
    check s.len == 3
    check safeAdvance(s, 1) == 3

  test "3-byte rune advances correctly":
    # "あ" is 0xE3 0x81 0x82 (3 bytes). From pos 0, we should land on pos 3.
    let s = "あb"
    check s.len == 4
    check safeAdvance(s, 0) == 3
    check safeAdvance(s, 3) == 4

  test "past-end returns pos + 1 so the caller loop terminates":
    check safeAdvance("ab", 2) == 3
    check safeAdvance("", 0) == 1

  test "lone continuation byte in the middle still advances at least one":
    # "é" bytes: 0xC3, 0xA9. Starting at pos 1 (a lone continuation byte in
    # isolation from its leader) must not be treated as the start of a rune.
    # The helper should still step forward strictly.
    let s = "aé"
    let p = safeAdvance(s, 1)
    check p > 1
    check p <= s.len

  test "strictly monotone across the whole string":
    let s = "aéあb"
    var prev = 0
    var pos = 0
    while pos < s.len:
      pos = safeAdvance(s, pos)
      check pos > prev
      prev = pos
