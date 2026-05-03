## Grammars used by the benchmark harness.
##
## A small but realistic JSON tmLanguage subset modelled on the
## community Nim grammar — enough rule kinds (match / begin-end /
## nested patterns / captures / backrefs) to exercise reni in patterns
## that real editors tokenize. The strings are kept small so the
## benchmark binary stays self-contained.

const NimGrammarJson* = """
{
  "scopeName": "source.nim",
  "patterns": [
    { "include": "#comments" },
    { "include": "#strings" },
    { "include": "#numbers" },
    { "include": "#keywords" },
    { "include": "#types" },
    { "include": "#operators" },
    { "include": "#identifiers" }
  ],
  "repository": {
    "comments": {
      "patterns": [
        {
          "name": "comment.block.nim",
          "begin": "#\\[",
          "end": "\\]#"
        },
        {
          "name": "comment.line.number-sign.nim",
          "match": "#.*$"
        }
      ]
    },
    "strings": {
      "patterns": [
        {
          "name": "string.quoted.triple.nim",
          "begin": "\"\"\"",
          "end": "\"\"\""
        },
        {
          "name": "string.quoted.double.nim",
          "begin": "\"",
          "end": "\"",
          "patterns": [
            { "name": "constant.character.escape.nim", "match": "\\\\." },
            { "name": "variable.other.placeholder.nim", "match": "\\$[A-Za-z_][A-Za-z0-9_]*" }
          ]
        },
        {
          "name": "string.quoted.single.nim",
          "match": "'(\\\\.|[^'])'"
        }
      ]
    },
    "numbers": {
      "patterns": [
        {
          "name": "constant.numeric.float.nim",
          "match": "\\b\\d+\\.\\d+([eE][+-]?\\d+)?(['_]?[fF](32|64))?\\b"
        },
        {
          "name": "constant.numeric.integer.hex.nim",
          "match": "\\b0[xX][0-9A-Fa-f]+(['_]?[iIuU](8|16|32|64))?\\b"
        },
        {
          "name": "constant.numeric.integer.nim",
          "match": "\\b\\d+(['_]?[iIuU](8|16|32|64))?\\b"
        }
      ]
    },
    "keywords": {
      "patterns": [
        {
          "name": "keyword.control.nim",
          "match": "\\b(if|elif|else|case|of|when|while|for|break|continue|return|yield|discard|raise|try|except|finally|defer)\\b"
        },
        {
          "name": "keyword.declaration.nim",
          "match": "\\b(proc|func|method|iterator|template|macro|converter|let|var|const|type|object|enum|tuple|ref|ptr)\\b"
        },
        {
          "name": "keyword.other.nim",
          "match": "\\b(import|export|include|from|as|using|asm|bind|mixin|distinct|in|notin|is|isnot|of|cast|addr|and|or|xor|not|shl|shr|div|mod)\\b"
        },
        {
          "name": "constant.language.nim",
          "match": "\\b(true|false|nil)\\b"
        }
      ]
    },
    "types": {
      "patterns": [
        {
          "name": "support.type.nim",
          "match": "\\b(int|int8|int16|int32|int64|uint|uint8|uint16|uint32|uint64|float|float32|float64|bool|char|string|cstring|cint|cfloat|cdouble|pointer|byte|seq|array|set|range|openArray|varargs|auto|void|untyped|typed)\\b"
        }
      ]
    },
    "operators": {
      "patterns": [
        {
          "name": "keyword.operator.nim",
          "match": "(==|!=|<=|>=|<|>|=|\\+|-|\\*|/|%|\\.\\.|\\.\\.<|@|&|\\||\\^|~|\\?|:)"
        }
      ]
    },
    "identifiers": {
      "patterns": [
        {
          "name": "entity.name.function.nim",
          "match": "\\b(proc|func|method|iterator|template|macro|converter)\\s+([A-Za-z_][A-Za-z0-9_]*)",
          "captures": {
            "1": { "name": "keyword.declaration.nim" },
            "2": { "name": "entity.name.function.nim" }
          }
        },
        {
          "name": "variable.other.nim",
          "match": "\\b[A-Za-z_][A-Za-z0-9_]*\\b"
        }
      ]
    }
  }
}
"""
