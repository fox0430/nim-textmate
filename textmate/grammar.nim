import std/[json, tables]

import ./types

proc expectStr(node: JsonNode, field: string): string =
  if node.kind != JString:
    raise newException(
      GrammarError, "field '" & field & "' must be a string, got " & $node.kind
    )
  node.getStr()

proc expectArray(node: JsonNode, field: string): seq[JsonNode] =
  if node.kind != JArray:
    raise newException(
      GrammarError, "field '" & field & "' must be an array, got " & $node.kind
    )
  node.elems

proc expectObject(node: JsonNode, field: string) =
  if node.kind != JObject:
    raise newException(
      GrammarError, "field '" & field & "' must be an object, got " & $node.kind
    )

proc decodePattern(node: JsonNode, field: string): RawPattern

proc decodePatternList(node: JsonNode, field: string): seq[RawPattern] =
  let arr = expectArray(node, field)
  for i, item in arr:
    result.add decodePattern(item, field & "[" & $i & "]")

proc decodeCapture(node: JsonNode, field: string): RawCapture =
  expectObject(node, field)
  if node.hasKey("name"):
    result.name = expectStr(node["name"], field & ".name")
  if node.hasKey("patterns"):
    result.patterns = decodePatternList(node["patterns"], field & ".patterns")

proc decodeCaptures(node: JsonNode, field: string): OrderedTable[string, RawCapture] =
  expectObject(node, field)
  for key, value in node.fields.pairs:
    result[key] = decodeCapture(value, field & "." & key)

proc decodePattern(node: JsonNode, field: string): RawPattern =
  if node.kind != JObject:
    raise newException(
      GrammarError,
      "pattern at '" & field & "' must be a JSON object, got " & $node.kind,
    )
  if node.hasKey("name"):
    result.name = expectStr(node["name"], field & ".name")
  if node.hasKey("contentName"):
    result.contentName = expectStr(node["contentName"], field & ".contentName")
  if node.hasKey("match"):
    result.match = expectStr(node["match"], field & ".match")
  if node.hasKey("begin"):
    result.begin = expectStr(node["begin"], field & ".begin")
  if node.hasKey("end"):
    result.`end` = expectStr(node["end"], field & ".end")
  if node.hasKey("while"):
    result.`while` = expectStr(node["while"], field & ".while")
  if node.hasKey("include"):
    let inc = expectStr(node["include"], field & ".include")
    if inc.len == 0:
      raise newException(GrammarError, "empty 'include' at " & field)
    result.`include` = inc
  if node.hasKey("patterns"):
    result.patterns = decodePatternList(node["patterns"], field & ".patterns")
  if node.hasKey("captures"):
    result.captures = decodeCaptures(node["captures"], field & ".captures")
  if node.hasKey("beginCaptures"):
    result.beginCaptures =
      decodeCaptures(node["beginCaptures"], field & ".beginCaptures")
  if node.hasKey("endCaptures"):
    result.endCaptures = decodeCaptures(node["endCaptures"], field & ".endCaptures")
  if node.hasKey("whileCaptures"):
    result.whileCaptures =
      decodeCaptures(node["whileCaptures"], field & ".whileCaptures")

proc decodeRepository(node: JsonNode, field: string): OrderedTable[string, RawPattern] =
  expectObject(node, field)
  for key, value in node.fields.pairs:
    result[key] = decodePattern(value, field & "." & key)

proc decodeInjections(node: JsonNode, field: string): OrderedTable[string, RawPattern] =
  expectObject(node, field)
  for key, value in node.fields.pairs:
    # Each injection value is a pattern-object-like wrapper whose only
    # meaningful payload is `patterns` (alongside optional name /
    # contentName). Anything else (`match`, `begin`, …) written at the
    # top level would be silently dropped during compilation, so reject
    # it loudly instead.
    let childField = field & "[\"" & key & "\"]"
    if value.kind != JObject:
      raise newException(
        GrammarError,
        "injection at '" & childField & "' must be a JSON object, got " & $value.kind,
      )
    if not value.hasKey("patterns"):
      raise newException(
        GrammarError, "injection at '" & childField & "' must contain 'patterns'"
      )
    result[key] = decodePattern(value, childField)

proc parseRawGrammar*(jsonStr: string): RawGrammar =
  ## Parse a tmLanguage grammar file (JSON). PLIST is not supported.
  ##
  ## Raises ``GrammarError`` if the input is not valid JSON, the root is
  ## not an object, ``scopeName`` is missing, or any field has the wrong
  ## JSON type.
  let root =
    try:
      parseJson(jsonStr)
    except JsonParsingError as e:
      raise newException(GrammarError, "invalid JSON: " & e.msg)
  if root.kind != JObject:
    raise newException(GrammarError, "grammar root must be an object")
  if root.hasKey("name"):
    result.name = expectStr(root["name"], "name")
  if not root.hasKey("scopeName"):
    raise newException(GrammarError, "grammar missing scopeName")
  result.scopeName = expectStr(root["scopeName"], "scopeName")
  if root.hasKey("patterns"):
    result.patterns = decodePatternList(root["patterns"], "patterns")
  if root.hasKey("repository"):
    result.repository = decodeRepository(root["repository"], "repository")
  if root.hasKey("injections"):
    result.injections = decodeInjections(root["injections"], "injections")
  if root.hasKey("injectionSelector"):
    result.injectionSelector = expectStr(root["injectionSelector"], "injectionSelector")
  if root.hasKey("firstLineMatch"):
    result.firstLineMatch = expectStr(root["firstLineMatch"], "firstLineMatch")
