# A dead simple JavaScript and CSS validator, bundler and minifier
#
# (c) 2025 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/squeezy

import std/os
import pkg/sweetsyntax/engine/ast
import ../common
import ./minifier
import ./exports
import ./formats
import ./resolve

proc resolveFor(opts: BundleConfig, importer: string,
    specifier: string): string =
  var rOpts = defaultResolveOpts()
  rOpts.nodePaths = opts.nodePaths
  rOpts.externals = opts.externals
  result = resolveSpecifier(importer, specifier, rOpts)

proc isExportFrom(node: Node): bool =
  ## True for `export {a} from 'x'` and `export * from 'x'`.
  ## Excludes `export default <expr>` and local `export {...}`.
  if node.isNil or node.kind != nkStatement or node.children.len < 3:
    return false
  let first = node.children[0]
  if first.isNil or first.kind != nkIdent or first.name != "export":
    return false
  let inner = node.children[1]
  if inner.isNil:
    return false
  let isReExportShape =
    inner.kind == nkIdentDefs or
    (inner.kind == nkIdent and inner.name == "*")
  if not isReExportShape:
    return false
  let last = node.children[^1]
  result = not last.isNil and last.kind == nkLitString

proc collectSpecifiers*(prog: OpenAstProgram): seq[string] =
  ## Collect every module specifier in a program: static `import`,
  ## `export ... from` re-exports, `require('x')` calls, and dynamic
  ## `import('x')` calls (parsed as `nkCall[nkImport, litString]`).
  proc walk(n: Node, specs: var seq[string]) =
    if n.isNil:
      return
    case n.kind
    of nkImport:
      if n.kind notin LeafNodes:
        for child in n.children:
          if not child.isNil and child.kind == nkLitString and
              child.valStr.len > 0:
            let spec = stripQuotes(child.valStr)
            if spec.len > 0:
              specs.add(spec)
    of nkCall:
      if n.kind notin LeafNodes and n.children.len >= 2:
        let callee = n.children[0]
        let arg = n.children[^1]
        if not callee.isNil and not arg.isNil and
            arg.kind == nkLitString and arg.valStr.len > 0:
          if callee.kind == nkImport or
              (callee.kind == nkIdent and callee.name == "require"):
            let spec = stripQuotes(arg.valStr)
            if spec.len > 0:
              specs.add(spec)
    of nkStatement:
      if isExportFrom(n):
        let spec = stripQuotes(n.children[^1].valStr)
        if spec.len > 0:
          specs.add(spec)
    else:
      discard
    if n.kind notin LeafNodes:
      for child in n.children:
        walk(child, specs)

  var specs: seq[string] = @[]
  for node in prog.nodes:
    walk(node, specs)
  result = specs

proc bundleJs*(entryPoint: string, opts: BundleConfig): string =
  var visited: seq[string]
  var modules: seq[(string, string)]

  proc processFile(path: string) =
    let absPath = path.absolutePath()
    if absPath in visited: return
    visited.add(absPath)
    modules.add((path, readFile(path)))

  processFile(entryPoint)

  # Index worklist: processFile appends during traversal.
  var idx = 0
  while idx < modules.len:
    let (path, code) = modules[idx]
    inc idx
    let prog =
      try:
        parseJsString(code)
      except CatchableError:
        continue
    for specifier in collectSpecifiers(prog):
      let resolved = resolveFor(opts, path, specifier)
      if resolved.len > 0:
        try:
          processFile(resolved)
        except CatchableError:
          discard

  let wrapped = opts.format != fmtES
  # Phase 1: per-module codegen. Mangle stays off here — it runs once
  # over the whole bundle below so short names are unique bundle-wide.
  # (Per-module mangling assigned the same short names in every file.)
  let genOpts = JsGenOptions(minify: opts.minify, mangle: false,
                             preserveComments: opts.preserveComments,
                             sourceMap: false, stripExports: wrapped)
  for (path, code) in modules:
    if wrapped:
      # Wrapped formats: drop import/export statements (deps are inlined).
      result.add(minifyJs(code, genOpts).code)
    elif opts.minify:
      result.add(minifyJs(code).code)
    else:
      result.add(code)
    result.add("\n")

  let bundleName = if opts.moduleName.len > 0: opts.moduleName
                     else: entryPoint.splitFile().name
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
          let resolved = resolveFor(opts, path,
            stripQuotes(node.children[2].valStr))
          if resolved.len > 0 and resolved notin visitedStar:
            visitedStar.add(resolved)
            entryExports.add(collectExports(parseJsString(readFile(resolved))))
            collectStarExports(resolved)

    collectStarExports(entryPoint)
    result = wrapBundle(result, opts.format, bundleName, entryExports)

  # Phase 2: whole-bundle mangle pass. Wrapped formats only: es output
  # keeps native import/export statements whose cross-module binding
  # names a global rename could break (es + mangle stays as-is).
  if opts.mangle and wrapped:
    var mangleOpts = JsGenOptions(minify: opts.minify, mangle: true,
                                  preserveComments: opts.preserveComments)
    if opts.format == fmtIIFE and bundleName.len > 0:
      # The iife global (`var NAME=...`) is the public entry point;
      # never hand it out as a short name.
      mangleOpts.preserveNames = @[bundleName]
    result = minifyJs(result, mangleOpts).code
