# A dead simple JavaScript and CSS validator, bundler and minifier
#
# (c) 2025 George Lemon | LGPL-v3 License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/squeezy

import std/[os, strutils]
import pkg/sweetsyntax/engine/ast
import ../common
import ./minifier

proc resolveModulePath(importer: string, specifier: string): string =
  if specifier.startsWith(".") or specifier.startsWith(".."):
    let dir = importer.parentDir()
    result = dir / specifier
    if not result.endsWith(".js") and not result.endsWith(".jsx") and
       not result.endsWith(".ts") and not result.endsWith(".tsx"):
      let withExt = result & ".js"
      if fileExists(withExt):
        return withExt
    if fileExists(result):
      return result
  else:
    if fileExists(specifier):
      return specifier

proc bundleJs*(entryPoint: string, opts: BundleConfig): string =
  var visited: seq[string]
  var modules: seq[(string, string)]

  proc processFile(path: string) =
    let absPath = path.absolutePath()
    if absPath in visited: return
    visited.add(absPath)
    let code = readFile(path)
    let prog = parseJsString(code)
    modules.add((path, code))

  processFile(entryPoint)

  for (path, code) in modules:
    let prog = parseJsString(code)
    for node in prog.nodes:
      if not node.isNil and node.kind == nkImport:
        var specifier: string
        for child in node.children:
          if not child.isNil and child.kind == nkLitString:
            specifier = child.valStr
        if specifier.len > 0:
          let resolved = resolveModulePath(path, specifier)
          if resolved.len > 0:
            processFile(resolved)

  for (path, code) in modules:
    if opts.minify:
      result.add(minifyJs(code).code)
    else:
      result.add(code)
    result.add("\n")
