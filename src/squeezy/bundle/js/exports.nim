# A dead simple JavaScript and CSS validator, bundler and minifier
#
# (c) 2025 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/squeezy

## Export collection for bundle output formats.
## Walks a parsed program's top-level nodes and records what it exports,
## so format wrappers can emit `exports.<name>=<local>;` lines.

import std/strutils
import pkg/sweetsyntax/engine/ast

type
  ExportEntry* = object
    exportedName*: string   ## name consumers see (after `as` renaming)
    localName*: string      ## local identifier in the module scope

  ExportKind* = enum
    exportNamed
    exportDefault

proc exportName(n: Node): string =
  ## Extract a declared identifier name from a function/class/var node.
  if n.isNil: return
  case n.kind
  of nkFunction:
    if n.children.len > 2 and not n.children[2].isNil and n.children[2].kind == nkIdent:
      result = n.children[2].name
  of nkStatement:
    if n.children.len > 0 and not n.children[0].isNil and n.children[0].kind == nkIdent:
      let kw = n.children[0].name
      case kw
      of "class":
        if n.children.len > 1 and not n.children[1].isNil and n.children[1].kind == nkIdent:
          result = n.children[1].name
      of "var", "let", "const":
        # Collect all declared names in the declaration list
        var names: seq[string]
        for i in 1 ..< n.children.len:
          let def = n.children[i]
          if not def.isNil and def.kind == nkIdentDefs and
             def.children.len > 0 and not def.children[0].isNil and
             def.children[0].kind == nkIdent:
            names.add def.children[0].name
        result = names.join(",")
  else:
    discard

proc collectExports*(prog: OpenAstProgram): seq[ExportEntry] =
  ## Collect all exported names from a parsed program.
  for node in prog.nodes:
    if node.isNil or node.kind != nkStatement: continue
    if node.children.len == 0 or node.children[0].isNil or
       node.children[0].kind != nkIdent or node.children[0].name != "export":
      continue

    if node.children.len < 2: continue
    let inner = node.children[1]

    if inner.kind == nkIdent and inner.name == "default":
      # export default <expr>
      result.add ExportEntry(exportedName: "default", localName: "__default")
    elif inner.kind == nkIdentDefs:
      # export { a, b as c }
      for child in inner.children:
        if child.isNil: continue
        if child.kind == nkIdent:
          result.add ExportEntry(exportedName: child.name, localName: child.name)
        elif child.kind == nkInfix and child.children.len >= 3 and
             not child.children[0].isNil and child.children[0].kind == nkIdent and
             child.children[0].name == "as":
          # [as, orig, alias]
          let orig = if child.children.len > 1 and not child.children[1].isNil: child.children[1].name else: ""
          let alias = if child.children.len > 2 and not child.children[2].isNil: child.children[2].name else: orig
          result.add ExportEntry(exportedName: alias, localName: orig)
    elif inner.kind == nkFunction or inner.kind == nkStatement:
      # export function foo() {} / export class Foo {} / export const x = ...
      let name = exportName(inner)
      if name.len > 0:
        for localName in name.split(","):
          result.add ExportEntry(exportedName: localName, localName: localName)
    # export * from '...' — handled by the bundler via re-export chain resolution
