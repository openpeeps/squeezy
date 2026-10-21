# A dead simple JavaScript and CSS validator, bundler and minifier
#
# (c) 2025 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/squeezy

import std/[os, syncio]
import pkg/sweetsyntax/engine/ast
import ../common
import ./minifier
import ./exports
import ./formats
import ./resolve

type
  ImportKind* = enum
    ikDefault    ## `import D from 'm'`
    ikNamed      ## `import {a, b as c} from 'm'`
    ikNamespace  ## `import * as ns from 'm'`

  ImportBinding* = object
    importer*: string  ## abs path of the importing module
    local*: string     ## name bound in the importer
    imported*: string  ## exported name in the dep ("default", name, "*")
    target*: string    ## abs path of the dep ("" when external/unresolved)
    specifier*: string ## original specifier, for warnings
    kind*: ImportKind

proc warnBundle(msg: string) =
  try:
    stderr.writeLine("warning: " & msg)
  except CatchableError:
    discard

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

proc identName(n: Node): string =
  if not n.isNil and n.kind == nkIdent: n.name else: ""

proc importSpecifierOf(node: Node): string =
  ## Specifier of a static `import ... from 'x'` / `import 'x'` node.
  if node.isNil or node.kind != nkImport or node.kind in LeafNodes:
    return ""
  for child in node.children:
    if not child.isNil and child.kind == nkLitString and child.valStr.len > 0:
      return stripQuotes(child.valStr)
  return ""

proc importBindingsOf(node: Node, importerAbs, spec,
    targetAbs: string): seq[ImportBinding] =
  ## Bindings of one static import statement. Side-effect-only imports
  ## yield no bindings.
  var defaultName = ""
  for child in node.children:
    if child.isNil: continue
    case child.kind
    of nkIdent:
      if defaultName.len == 0:
        defaultName = child.name
    of nkIdentDefs:
      for c in child.children:
        if c.isNil: continue
        if c.kind == nkIdent and c.name.len > 0:
          result.add(ImportBinding(importer: importerAbs, local: c.name,
            imported: c.name, target: targetAbs, specifier: spec,
            kind: ikNamed))
        elif c.kind == nkInfix and c.children.len >= 3 and
            identName(c.children[0]) == "as":
          let orig = identName(c.children[1])
          let alias = identName(c.children[2])
          if orig.len > 0 and alias.len > 0:
            result.add(ImportBinding(importer: importerAbs, local: alias,
              imported: orig, target: targetAbs, specifier: spec,
              kind: ikNamed))
    of nkInfix:
      if child.children.len >= 3 and identName(child.children[0]) == "as" and
         identName(child.children[1]) == "*":
        let ns = identName(child.children[2])
        if ns.len > 0:
          result.add(ImportBinding(importer: importerAbs, local: ns,
            imported: "*", target: targetAbs, specifier: spec,
            kind: ikNamespace))
    else: discard
  if defaultName.len > 0:
    result.add(ImportBinding(importer: importerAbs, local: defaultName,
      imported: "default", target: targetAbs, specifier: spec,
      kind: ikDefault))

proc starFromSpecifier(node: Node): string =
  ## Specifier of `export * from 'x'`, else "".
  if node.isNil or node.kind != nkStatement or node.children.len < 3:
    return ""
  if identName(node.children[0]) != "export": return ""
  let inner = node.children[1]
  if inner.isNil or inner.kind != nkIdent or inner.name != "*": return ""
  let last = node.children[^1]
  if last.isNil or last.kind != nkLitString: return ""
  result = stripQuotes(last.valStr)

proc namedFromSpecs(node: Node): seq[(string, string)] =
  ## (orig, alias) pairs of `export {a, b as c} from 'x'`.
  if not isExportFrom(node): return @[]
  let inner = node.children[1]
  if inner.isNil or inner.kind != nkIdentDefs: return @[]
  for c in inner.children:
    if c.isNil: continue
    if c.kind == nkIdent and c.name.len > 0:
      result.add((c.name, c.name))
    elif c.kind == nkInfix and c.children.len >= 3 and
        identName(c.children[0]) == "as":
      let orig = identName(c.children[1])
      let alias = identName(c.children[2])
      if orig.len > 0 and alias.len > 0:
        result.add((orig, alias))

proc exportEntriesOf(path: string): seq[ExportEntry] =
  ## Direct exports of a module; empty when it cannot be parsed.
  try:
    result = collectExports(parseJsString(readFile(path)))
  except CatchableError:
    discard

proc findExport(entries: seq[ExportEntry], name: string): ExportEntry =
  for e in entries:
    if e.exportedName == name: return e

proc collectStarNames(path: string, opts: BundleConfig,
    seen: var seq[string]): seq[string] =
  ## Transitive non-default names re-exported through `export *` chains.
  let prog = try: parseJsString(readFile(path))
               except CatchableError: return @[]
  for node in prog.nodes:
    let spec = starFromSpecifier(node)
    if spec.len == 0: continue
    let resolved = resolveFor(opts, path, spec)
    if resolved.len == 0: continue
    let abs = resolved.absolutePath()
    if abs in seen: continue
    seen.add(abs)
    for e in exportEntriesOf(resolved):
      if e.exportedName != "default" and e.exportedName notin result:
        result.add(e.exportedName)
    for n in collectStarNames(resolved, opts, seen):
      if n notin result: result.add(n)

proc newIdentNode(name: string): Node =
  Node(kind: nkIdent, name: name)

proc makeAliasNode(local, depLocal: string): Node =
  ## `var local = depLocal;`
  Node(kind: nkStatement, children: @[
    newIdentNode("var"),
    Node(kind: nkIdentDefs, children: @[
      newIdentNode(local), Node(kind: nkEmpty), newIdentNode(depLocal)])])

proc makeNsAliasNode(local: string,
    props: seq[(string, string)]): Node =
  ## `var local = {prop: depLocal, ...};`
  var members: seq[Node] = @[]
  for (pname, plocal) in props:
    members.add(Node(kind: nkColonExpr,
      children: @[newIdentNode(pname), newIdentNode(plocal)]))
  Node(kind: nkStatement, children: @[
    newIdentNode("var"),
    Node(kind: nkIdentDefs, children: @[
      newIdentNode(local), Node(kind: nkEmpty),
      Node(kind: nkBlock, children: members)])])

proc bundleJs*(entryPoint: string, opts: BundleConfig): string =
  var visited: seq[string]
  var modules: seq[tuple[path, abs, code: string]]
  var bindings: seq[ImportBinding]

  proc processFile(path: string) =
    let absPath = path.absolutePath()
    if absPath in visited: return
    visited.add(absPath)
    let code =
      try: readFile(path)
      except CatchableError: return
    # Post-order: dependencies are emitted before their importers, so
    # alias assignments placed after each dep chunk bind correctly.
    try:
      let prog = parseJsString(code)
      for specifier in collectSpecifiers(prog):
        let resolved = resolveFor(opts, path, specifier)
        if resolved.len > 0:
          processFile(resolved)
    except CatchableError:
      discard
    modules.add((path, absPath, code))

  processFile(entryPoint)

  let wrapped = opts.format != fmtES
  # Phase 1: per-module codegen. Mangle stays off here — it runs once
  # over the whole bundle below so short names are unique bundle-wide.
  # (Per-module mangling assigned the same short names in every file.)
  let genOpts = JsGenOptions(minify: opts.minify, mangle: false,
                             preserveComments: opts.preserveComments,
                             sourceMap: false, stripExports: wrapped)

  # Rewrite: drop imports of bundled modules, inline re-exports (es),
  # and remember alias bindings for the emit loop below.
  var programs: seq[OpenAstProgram] = @[]
  var changed: seq[bool] = @[]
  for m in modules:
    let prog = try: parseJsString(m.code) except CatchableError: nil
    if prog.isNil:
      programs.add(nil)
      changed.add(false)
      continue
    var drops: seq[int] = @[]
    var replacements: seq[(int, Node)] = @[]
    var touched = false
    for i, node in prog.nodes:
      if node.isNil: continue
      if node.kind == nkImport:
        let spec = importSpecifierOf(node)
        if spec.len == 0: continue
        let target = resolveFor(opts, m.path, spec)
        if target.len == 0: continue  # external/builtin/missing: keep
        let bs = importBindingsOf(node, m.abs, spec, target.absolutePath())
        if bs.len == 0:
          drops.add(i)  # side-effect import of a bundled module
          touched = true
          continue
        var missing = false
        let entries = exportEntriesOf(target)
        for b in bs:
          if b.kind == ikNamespace: continue
          if findExport(entries, b.imported).exportedName.len == 0:
            warnBundle(m.path & ": '" & spec & "' has no export '" &
              b.imported & "'")
            missing = true
        if wrapped or not missing:
          for b in bs: bindings.add(b)
          drops.add(i)
          touched = true
        # es + missing export: keep the statement so names still
        # resolve at runtime instead of dangling silently.
      elif not wrapped and isExportFrom(node):
        let spec = stripQuotes(node.children[^1].valStr)
        if spec.len == 0: continue
        let target = resolveFor(opts, m.path, spec)
        if target.len == 0: continue
        let inner = node.children[1]
        if not inner.isNil and inner.kind == nkIdent:
          # export * from 'm' -> explicit re-export of enumerable names
          var seen: seq[string] = @[]
          let names = collectStarNames(target, opts, seen)
          if names.len > 0:
            var items: seq[Node] = @[]
            for n in names: items.add(newIdentNode(n))
            replacements.add((i, Node(kind: nkStatement, children: @[
              newIdentNode("export"),
              Node(kind: nkIdentDefs, children: items)])))
            touched = true
        elif not inner.isNil and inner.kind == nkIdentDefs:
          var ok = true
          var items: seq[Node] = @[]
          for (orig, alias) in namedFromSpecs(node):
            let e = findExport(exportEntriesOf(target), orig)
            if e.exportedName.len == 0 or e.localName.len == 0:
              warnBundle(m.path & ": '" & spec & "' has no export '" &
                orig & "'")
              ok = false
              break
            if e.localName == alias:
              items.add(newIdentNode(alias))
            else:
              items.add(Node(kind: nkInfix, children: @[
                newIdentNode("as"), newIdentNode(e.localName),
                newIdentNode(alias)]))
          if ok:
            replacements.add((i, Node(kind: nkStatement, children: @[
              newIdentNode("export"),
              Node(kind: nkIdentDefs, children: items)])))
            touched = true
    var newNodes: seq[Node] = @[]
    for i, node in prog.nodes:
      if i in drops: continue
      var replaced = false
      for (ri, rn) in replacements:
        if ri == i:
          newNodes.add(rn)
          replaced = true
          break
      if not replaced:
        newNodes.add(node)
    programs.add(OpenAstProgram(nodes: newNodes))
    changed.add(touched)

  # Aliases live after their dep chunk, so they capture the right
  # bindings even when several deps share generated names.
  for b in bindings:
    for mi, m in modules:
      if m.abs == b.target:
        changed[mi] = true
        break

  for mi, m in modules:
    if programs[mi].isNil or (not changed[mi] and not wrapped and
        not opts.minify):
      # Untouched es module without minification: byte-identical output.
      result.add(m.code)
    else:
      var allNodes = programs[mi].nodes
      for b in bindings:
        if b.target != m.abs: continue
        case b.kind
        of ikNamespace:
          var props: seq[(string, string)] = @[]
          for e in exportEntriesOf(m.path):
            if e.exportedName.len == 0 or e.localName.len == 0: continue
            var dup = false
            for (pn, _) in props:
              if pn == e.exportedName:
                dup = true
                break
            if not dup:
              props.add((e.exportedName, e.localName))
          var seen: seq[string] = @[]
          for n in collectStarNames(m.path, opts, seen):
            var dup = false
            for (pn, _) in props:
              if pn == n:
                dup = true
                break
            if not dup:
              props.add((n, n))
          allNodes.add(makeNsAliasNode(b.local, props))
        of ikDefault, ikNamed:
          let e = findExport(exportEntriesOf(m.path), b.imported)
          if e.exportedName.len == 0 or e.localName.len == 0: continue
          if e.localName == b.local: continue  # binds directly already
          allNodes.add(makeAliasNode(b.local, e.localName))
      if wrapped or opts.minify:
        result.add(minifyJsProgram(OpenAstProgram(nodes: allNodes),
          genOpts).code)
      else:
        # Unminified es with rewrites: regenerate so dropped imports
        # and aliases take effect.
        var plainOpts = genOpts
        plainOpts.stripExports = false
        result.add(minifyJsProgram(OpenAstProgram(nodes: allNodes),
          plainOpts).code)
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
