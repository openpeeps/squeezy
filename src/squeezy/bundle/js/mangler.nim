# A dead simple JavaScript and CSS validator, bundler and minifier
#
# (c) 2025 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/squeezy

import std/tables
import sweetsyntax/engine/ast

type
  Mangler* = ref object
    mapping: Table[string, string]
    counter: int

const
  ReservedWords*: seq[string] = @[
    "abstract", "arguments", "await", "boolean", "break", "byte", "case",
    "catch", "char", "class", "const", "continue", "debugger", "default",
    "delete", "do", "double", "else", "enum", "eval", "export", "extends",
    "false", "final", "finally", "float", "for", "function", "goto", "if",
    "implements", "import", "in", "instanceof", "int", "interface", "let",
    "long", "native", "new", "null", "package", "private", "protected",
    "public", "return", "short", "static", "super", "switch", "synchronized",
    "this", "throw", "throws", "transient", "true", "try", "typeof", "var",
    "void", "volatile", "while", "with", "yield"
  ]

  KnownGlobals*: seq[string] = @[
    "console", "window", "document", "global", "process", "Buffer",
    "setTimeout", "setInterval", "clearTimeout", "clearInterval",
    "fetch", "XMLHttpRequest", "WebSocket", "localStorage", "sessionStorage",
    "JSON", "Math", "Date", "RegExp", "Error", "Map", "Set", "WeakMap",
    "WeakSet", "Promise", "Proxy", "Reflect", "Symbol", "BigInt",
    "Intl", "Array", "Object", "String", "Number", "Boolean", "Function",
    "ArrayBuffer", "DataView", "TypedArray", "Uint8Array", "Int8Array",
    "Uint16Array", "Int16Array", "Uint32Array", "Int32Array",
    "Float32Array", "Float64Array", "BigInt64Array", "BigUint64Array",
    "isNaN", "isFinite", "parseInt", "parseFloat", "encodeURI",
    "encodeURIComponent", "decodeURI", "decodeURIComponent",
    "require", "module", "exports", "__dirname", "__filename",
    "globalThis", "undefined", "Infinity", "NaN"
  ]

proc genShortName(n: int): string =
  var num = n
  while true:
    result = char(ord('a') + (num mod 26)) & result
    num = num div 26
    if num == 0: break
    num -= 1

proc newMangler*: Mangler =
  Mangler(mapping: initTable[string, string](), counter: 0)

proc addName*(m: Mangler, name: string) =
  if name.len == 0: return
  if name in m.mapping: return
  if name in ReservedWords or name in KnownGlobals:
    m.mapping[name] = name
    return
  var shortName = genShortName(m.counter)
  while shortName in ReservedWords or shortName in KnownGlobals or
        shortName in m.mapping:
    m.counter += 1
    shortName = genShortName(m.counter)
  m.mapping[name] = shortName
  m.counter += 1

proc getMangled*(m: Mangler, name: string): string =
  if name in m.mapping:
    return m.mapping[name]
  result = name

proc dumpMangler*(m: Mangler): string =
  for k, v in m.mapping.pairs:
    if k != v:
      result.add("  " & k & " -> " & v & "\n")

proc walkAndCollect*(m: Mangler, n: Node) =
  if n.isNil: return
  case n.kind
  of nkFunction:
    let children = n.children
    if children.len >= 5 and not children[4].isNil and children[4].kind == nkIdentDefs:
      for param in children[4].children:
        if param.isNil: continue
        if param.kind == nkIdent:
          addName(m, param.name)
        elif param.kind == nkIdentDefs and param.children.len > 0 and
             not param.children[0].isNil and param.children[0].kind == nkIdent:
          addName(m, param.children[0].name)
    if children.len >= 7 and not children[6].isNil:
      walkAndCollect(m, children[6])
  of nkStatement:
    if n.children.len > 0 and not n.children[0].isNil and
       n.children[0].kind == nkIdent and
       n.children[0].name in ["var", "let", "const"]:
      for i in 1 ..< n.children.len:
        let def = n.children[i]
        if def.isNil: continue
        if def.kind == nkIdentDefs and def.children.len > 0 and
           not def.children[0].isNil and def.children[0].kind == nkIdent:
          addName(m, def.children[0].name)
        elif def.kind == nkIdent:
          addName(m, def.name)
    elif n.children.len > 0 and not n.children[0].isNil and
         n.children[0].kind == nkIdent and
         n.children[0].name == "for":
      if n.children.len > 1 and not n.children[1].isNil:
        let init = n.children[1]
        if init.kind == nkStatement and init.children.len > 0 and
           not init.children[0].isNil and init.children[0].kind == nkIdent and
           init.children[0].name in ["var", "let", "const"]:
          for i in 1 ..< init.children.len:
            let def = init.children[i]
            if def.isNil: continue
            if def.kind == nkIdentDefs and def.children.len > 0 and
               not def.children[0].isNil and def.children[0].kind == nkIdent:
              addName(m, def.children[0].name)
    else:
      if n.kind notin LeafNodes and n.kind != nkNil:
        for child in n.children:
          if not child.isNil:
            walkAndCollect(m, child)
  else:
    if n.kind notin LeafNodes and n.kind != nkNil:
      for child in n.children:
        if not child.isNil:
          walkAndCollect(m, child)
