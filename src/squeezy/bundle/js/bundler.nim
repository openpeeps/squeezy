# A dead simple JavaScript and CSS validator, bundler and minifier
#
# (c) 2025 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/squeezy

import std/[os, strutils]
import pkg/sweetsyntax/engine/ast
import ../common
import ./minifier
import ./exports
import ./formats

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
    modules.add((path, readFile(path)))

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

  let wrapped = opts.format != fmtES
  for (path, code) in modules:
    if wrapped:
      # Wrapped formats: drop import/export statements (deps are inlined).
      let jsOpts = JsGenOptions(minify: opts.minify, mangle: opts.mangle,
                                preserveComments: opts.preserveComments,
                                sourceMap: opts.sourceMap, stripExports: true)
      result.add(minifyJs(code, jsOpts).code)
    elif opts.minify:
      result.add(minifyJs(code).code)
    else:
      result.add(code)
    result.add("\n")

  if wrapped:
    # Collect the entry module's exports, following `export * from 'x'`
    # re-export chains through the module graph.
    var entryExports = collectExports(parseJsString(readFile(entryPoint)))
    var visitedStar: seq[string]

    proc collectStarExports(path: string) =
      let prog = parseJsString(readFile(path))
      for node in prog.nodes:
        if node.isNil or node.kind != nkStatement or node.children.len < 3: continue
        if not node.children[0].isNil and node.children[0].kind == nkIdent and
           node.children[0].name == "export" and
           not node.children[1].isNil and node.children[1].kind == nkIdent and
           node.children[1].name == "*" and
           not node.children[2].isNil and node.children[2].kind == nkLitString:
          let resolved = resolveModulePath(path, node.children[2].valStr)
          if resolved.len > 0 and resolved notin visitedStar:
            visitedStar.add(resolved)
            entryExports.add(collectExports(parseJsString(readFile(resolved))))
            collectStarExports(resolved)

    collectStarExports(entryPoint)
    let name = if opts.moduleName.len > 0: opts.moduleName
               else: entryPoint.splitFile().name
    result = wrapBundle(result, opts.format, name, entryExports)
