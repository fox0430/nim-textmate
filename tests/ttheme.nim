import std/[tables, unittest]

import textmate

const TmTheme = """
  {
    "name": "Demo",
    "settings": [
      { "settings": { "foreground": "#cccccc", "background": "#1e1e1e" } },
      { "scope": "keyword",
        "settings": { "foreground": "#ff5555", "fontStyle": "italic" } },
      { "scope": "keyword.operator",
        "settings": { "foreground": "#66ccff" } }
    ]
  }
"""

const VsCodeTheme = """
  {
    "name": "Vs",
    "tokenColors": [
      { "scope": ["keyword", "storage"],
        "settings": { "foreground": "#ff0000", "fontStyle": "bold underline" } },
      { "scope": "string.quoted",
        "settings": { "foreground": "#00ff00" } }
    ]
  }
"""

suite "parseFontStyle":
  test "empty string is fsNotSet":
    check parseFontStyle("") == fsNotSet

  test "single token italic":
    check parseFontStyle("italic") == fsItalic

  test "multiple tokens combine via OR":
    let fs = parseFontStyle("bold underline")
    check (fs and fsBold) == fsBold
    check (fs and fsUnderline) == fsUnderline
    check (fs and fsItalic) == fsNotSet

  test "none yields fsNone":
    check parseFontStyle("none") == fsNone

  test "none wins regardless of position":
    check parseFontStyle("italic none") == fsNone
    check parseFontStyle("none italic") == fsNone
    check parseFontStyle("bold none underline") == fsNone

  test "unknown tokens are ignored":
    check parseFontStyle("neon italic") == fsItalic

  test "comma separator also works":
    let fs = parseFontStyle("italic,bold")
    check (fs and fsItalic) == fsItalic
    check (fs and fsBold) == fsBold

suite "ColorMap":
  test "empty string intern returns NoColor":
    let m = newColorMap()
    check internColor(m, "") == NoColor
    check m.byId.len == 1
    check not m.byColor.hasKey("")

  test "ids start at 1 and are monotonic":
    let m = newColorMap()
    check internColor(m, "#ff0000") == ColorId(1)
    check internColor(m, "#00ff00") == ColorId(2)
    check internColor(m, "#0000ff") == ColorId(3)

  test "repeat intern returns the same id":
    let m = newColorMap()
    discard internColor(m, "#ff0000")
    discard internColor(m, "#00ff00")
    check internColor(m, "#ff0000") == ColorId(1)

  test "lookupColor round-trip":
    let m = newColorMap()
    let id = internColor(m, "#ff0000")
    check lookupColor(m, id) == "#ff0000"

  test "lookupColor for NoColor and unknown id returns empty string":
    let m = newColorMap()
    discard internColor(m, "#ff0000")
    check lookupColor(m, NoColor) == ""
    check lookupColor(m, ColorId(99)) == ""

suite "parseRawTheme":
  test "tmTheme settings form with defaults":
    let raw = parseRawTheme(TmTheme)
    check raw.name == "Demo"
    check raw.defaults.foreground == "#cccccc"
    check raw.defaults.background == "#1e1e1e"
    check raw.rules.len == 2
    check raw.rules[0].scope == "keyword"
    check raw.rules[0].fontStyle == "italic"
    check raw.rules[1].scope == "keyword.operator"
    check raw.rules[1].foreground == "#66ccff"

  test "VSCode tokenColors with scope array":
    let raw = parseRawTheme(VsCodeTheme)
    check raw.name == "Vs"
    check raw.rules.len == 2
    # Array scope is comma-joined so parseSelector sees OR groups.
    check raw.rules[0].scope == "keyword, storage"
    check raw.rules[0].fontStyle == "bold underline"

  test "theme with neither settings nor tokenColors":
    let raw = parseRawTheme("""{ "name": "Bare" }""")
    check raw.name == "Bare"
    check raw.rules.len == 0
    check raw.defaults.foreground == ""

  test "invalid JSON raises ThemeError":
    expect ThemeError:
      discard parseRawTheme("not json")

  test "non-object root raises ThemeError":
    expect ThemeError:
      discard parseRawTheme("[]")

  test "wrong-type settings raises ThemeError":
    expect ThemeError:
      discard parseRawTheme("""{ "settings": "nope" }""")

  test "scope array with non-string element raises ThemeError":
    expect ThemeError:
      discard
        parseRawTheme("""{ "tokenColors": [ { "scope": [1, 2], "settings": {} } ] }""")

suite "compileTheme":
  test "preserves rule order":
    let t = compileTheme(parseRawTheme(TmTheme))
    check t.rules.len == 2
    check t.rules[0].order == 0
    check t.rules[1].order == 1

  test "specificity is the length of the longest matched atom":
    let t = compileTheme(parseRawTheme(TmTheme))
    # "keyword" -> 7 characters; "keyword.operator" -> 16 characters.
    check t.rules[0].specificity == "keyword".len
    check t.rules[1].specificity == "keyword.operator".len
    # And the second rule is genuinely more specific than the first,
    # which is what `resolveTheme` actually uses.
    check t.rules[1].specificity > t.rules[0].specificity

  test "defaults populate defaultStyle via the shared ColorMap":
    let t = compileTheme(parseRawTheme(TmTheme))
    check lookupColor(t.colorMap, t.defaultStyle.foreground) == "#cccccc"
    check lookupColor(t.colorMap, t.defaultStyle.background) == "#1e1e1e"
    check t.defaultStyle.fontStyle == fsNotSet

  test "empty selector rules are dropped":
    let raw = parseRawTheme(
      """
      { "settings": [
        { "scope": "", "settings": { "foreground": "#abcdef" } },
        { "scope": "   ", "settings": { "foreground": "#fedcba" } }
      ] }
    """
    )
    # Both entries had no `scope` atom — the first becomes defaults, the
    # second has an empty selector and gets dropped by compileTheme.
    let t = compileTheme(raw)
    check t.rules.len == 0

suite "resolveTheme":
  test "empty scopes fall through to defaultStyle":
    let t = compileTheme(parseRawTheme(TmTheme))
    let s = resolveTheme(t, @[])
    check lookupColor(t.colorMap, s.foreground) == "#cccccc"
    check lookupColor(t.colorMap, s.background) == "#1e1e1e"
    check s.fontStyle == fsNotSet

  test "single scope-specific match overrides foreground":
    let t = compileTheme(parseRawTheme(TmTheme))
    let s = resolveTheme(t, @["source.test", "keyword"])
    check lookupColor(t.colorMap, s.foreground) == "#ff5555"
    check s.fontStyle == fsItalic
    check lookupColor(t.colorMap, s.background) == "#1e1e1e"

  test "most-specific rule wins the field":
    let t = compileTheme(parseRawTheme(TmTheme))
    let s = resolveTheme(t, @["source.test", "keyword.operator"])
    check lookupColor(t.colorMap, s.foreground) == "#66ccff"

  test "field-level inheritance: fontStyle from less-specific rule":
    # "keyword" sets italic; "keyword.operator" only sets fg. The
    # resolved style on `keyword.operator` should inherit italic from
    # the "keyword" rule even though it is less specific.
    let t = compileTheme(parseRawTheme(TmTheme))
    let s = resolveTheme(t, @["source.test", "keyword.operator"])
    check s.fontStyle == fsItalic
    check lookupColor(t.colorMap, s.foreground) == "#66ccff"

  test "equal specificity: later-declared rule wins":
    const J = """
      { "settings": [
        { "scope": "keyword",
          "settings": { "foreground": "#aaaaaa" } },
        { "scope": "keyword",
          "settings": { "foreground": "#bbbbbb" } }
      ] }
    """
    let t = compileTheme(parseRawTheme(J))
    let s = resolveTheme(t, @["keyword"])
    check lookupColor(t.colorMap, s.foreground) == "#bbbbbb"

  test "theme with no rules returns defaultStyle":
    let t = compileTheme(parseRawTheme("""{ "name": "N" }"""))
    let s = resolveTheme(t, @["keyword"])
    check s.foreground == NoColor
    check s.background == NoColor
    check s.fontStyle == fsNotSet

  test "non-matching scope leaves defaults intact":
    let t = compileTheme(parseRawTheme(TmTheme))
    let s = resolveTheme(t, @["source.test", "comment.line"])
    check lookupColor(t.colorMap, s.foreground) == "#cccccc"

  test "VSCode tokenColors array scope matches either atom":
    let t = compileTheme(parseRawTheme(VsCodeTheme))
    let a = resolveTheme(t, @["source.x", "keyword"])
    let b = resolveTheme(t, @["source.x", "storage"])
    check lookupColor(t.colorMap, a.foreground) == "#ff0000"
    check lookupColor(t.colorMap, b.foreground) == "#ff0000"
