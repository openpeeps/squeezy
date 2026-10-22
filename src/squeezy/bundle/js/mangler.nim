# A dead simple JavaScript and CSS validator, bundler and minifier
#
# (c) 2025 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/squeezy

import std/[tables, sets]
import sweetsyntax/engine/ast
when defined(mangleTime):
  import std/times

type
  ScopeKind* = enum
    skProgram, skFunction, skBlock, skCatch, skFor, skSwitch, skClassSelf,
    skSynthetic
  Scope* = ref object
    parent*: Scope
    kind*: ScopeKind
    node*: Node
    bindings*: Table[int, string]
    labels*: Table[int, string]
    pending*: seq[tuple[id: int, keep: bool]]
    labelPending*: seq[tuple[id: int, keep: bool]]
    used*: HashSet[int]
    refNames*: HashSet[int]
    pinnedByWith*: HashSet[int]
    children*: seq[Scope]
    keepAll*: bool
    counter*: int
    savedB*: Scope
    savedF*: Scope
  Mangler* = ref object
    mapping: Table[int, string]
    used: HashSet[int]
    pinned: HashSet[int]
    preserved: HashSet[int]
    reserved: HashSet[int]
    counter: int
    names*: seq[string]
    nameIds: Table[string, int]
    trackOrig*: bool
    origNames*: Table[pointer, string]
    tAncUsed*: float
    tNextShort*: float
    scopes*: Table[pointer, Scope]
    taintMemo*: Table[pointer, int]
    withBodies*: seq[Scope]
    stack*: seq[Scope]

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

proc intern*(m: Mangler, name: string): int =
  ## Identifier interning: every distinct name hashes once globally, after
  ## which all scope tables compare small ints (no string hashing, copying
  ## or ordering effects in hot loops). Ids are dense per mangler run.
  let found = m.nameIds.getOrDefault(name, -1)
  if found >= 0:
    return found
  result = m.names.len
  m.names.add(name)
  m.nameIds[name] = result

proc newMangler*: Mangler =
  result = Mangler(mapping: initTable[int, string](),
    used: initHashSet[int](), pinned: initHashSet[int](),
    preserved: initHashSet[int](), reserved: initHashSet[int](),
    counter: 0,
    names: @[], nameIds: initTable[string, int](),
    trackOrig: false, origNames: initTable[pointer, string](),
    scopes: initTable[pointer, Scope](),
    taintMemo: initTable[pointer, int](), withBodies: @[], stack: @[])
  for w in ReservedWords:
    let id = result.intern(w)
    result.used.incl(id)
    result.pinned.incl(id)
    result.reserved.incl(id)
  for g in KnownGlobals:
    let id = result.intern(g)
    result.used.incl(id)
    result.pinned.incl(id)

proc isDeclKw*(name: string): bool {.inline.} =
  ## Case-free `name in ["var", "let", "const"]` for per-statement checks.
  case name.len
  of 3: name == "var" or name == "let"
  of 5: name == "const"
  else: false

proc addName*(m: Mangler, name: string) =
  ## Legacy flat collector entry (kept for API compat; codegen uses the
  ## scoped pass). Keys are interned ids like everywhere else.
  if name.len == 0: return
  let id = m.intern(name)
  if id in m.mapping: return
  if id in m.pinned:
    # Reserved words, known globals and preserved names are pinned to
    # themselves. Note this must NOT be `id in m.used`: an original
    # name colliding with an already-issued short name needs a fresh
    # short, not a self-pin (which would collide with the earlier name).
    m.mapping[id] = name
    return
  var shortName = genShortName(m.counter)
  while m.intern(shortName) in m.used:
    # A short name must never collide with a reserved word, a known global,
    # or another identifier's short name in the same bundle.
    m.counter += 1
    shortName = genShortName(m.counter)
  m.mapping[id] = shortName
  m.used.incl(m.intern(shortName))
  m.counter += 1

proc getMangled*(m: Mangler, name: string): string =
  result = m.mapping.getOrDefault(m.nameIds.getOrDefault(name, -1), name)

proc dumpMangler*(m: Mangler): string =
  for k, v in m.mapping.pairs:
    if k >= 0 and k < m.names.len and m.names[k] != v:
      result.add("  " & m.names[k] & " -> " & v & "\n")

proc preserveName*(m: Mangler, name: string) =
  ## Pin an identifier to itself so later passes never rename it
  ## (e.g. a bundle wrapper global), and block its reuse as a
  ## short name for anything else. Unlike reserved words and known
  ## globals (which shadowed bindings may reuse), preserved names are
  ## never renamed anywhere: assignment self-maps them on sight.
  if name.len == 0: return
  let id = m.intern(name)
  m.mapping[id] = name
  m.used.incl(id)
  m.pinned.incl(id)
  m.preserved.incl(id)

proc walkAndCollect*(m: Mangler, n: Node) =
  if n.isNil: return
  case n.kind
  of nkFunction:
    # Collect params and walk the body. Layout varies: plain functions keep
    # params at index 4 and body at 6, while methods carry leading flag
    # idents, so locate both by kind instead of position.
    for child in n.children:
      if child.isNil: continue
      if child.kind == nkIdentDefs:
        for param in child.children:
          if param.isNil: continue
          if param.kind == nkIdent:
            addName(m, param.name)
          elif param.kind == nkIdentDefs and param.children.len > 0 and
               not param.children[0].isNil and param.children[0].kind == nkIdent:
            addName(m, param.children[0].name)
            # Defaults may hold closures with their own bindings.
            for j in 1 ..< param.children.len:
              if not param.children[j].isNil:
                walkAndCollect(m, param.children[j])
          else:
            walkAndCollect(m, param)
      elif child.kind notin LeafNodes:
        # Body block, return type, decorators: walk everything else.
        # (nkNil is in LeafNodes, so no extra check is needed.)
        walkAndCollect(m, child)
  of nkStatement:
    if n.children.len > 0 and not n.children[0].isNil and
       n.children[0].kind == nkIdent and
       isDeclKw(n.children[0].name):
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
           isDeclKw(init.children[0].name):
          for i in 1 ..< init.children.len:
            let def = init.children[i]
            if def.isNil: continue
            if def.kind == nkIdentDefs and def.children.len > 0 and
               not def.children[0].isNil and def.children[0].kind == nkIdent:
              addName(m, def.children[0].name)
    # Always descend: initializers and loop bodies may declare more names.
    # (nkNil is in LeafNodes, so no extra check is needed.)
    if n.kind notin LeafNodes:
      for child in n.children:
        if not child.isNil:
          walkAndCollect(m, child)
  else:
    if n.kind notin LeafNodes:
      for child in n.children:
        if not child.isNil:
          walkAndCollect(m, child)

# ---------------------------------------------------------------------------
# Scoped mangler: per-scope short-name reuse.
#
# The legacy pass above assigns one bundle-global short name per original
# name, so N distinct locals burn through a..z, aa..zz into 3-letter names.
# Real minifiers restart the alphabet in every function scope: sibling
# functions each use a, b, c... for their own locals. This pass does that by
# renaming identifiers in place, scope by scope, before codegen runs.
#
# Design notes (all load-bearing, all verified against the d3.js corpus):
# - Three phases: (A) collect bindings + reference names into a scope tree,
#   (B) assign shorts top-down, (C) rename idents in place. Codegen is then
#   untouched: renamed idents pass through `getMangled` unchanged.
# - Only positions codegen mangles (the `nkIdent` choke point in codgen.nim)
#   are renamed. Dot right-hand sides, member keys, statement keywords and
#   operator/marker idents are never touched (positional, never ambiguous).
# - A candidate short is blocked when it is pinned (reserved word, known
#   global, preserved name), taken in its own scope, taken by an ancestor
#   binding referenced below (textual shadowing collision), or used below
#   without any binding (sloppy global / environment name).
# - `with` bodies keep every name (property shadowing is unknowable) and pin
#   the path to the root for the names they observe. Direct `eval` keeps its
#   whole scope path. Both are vanishingly rare and cost nothing otherwise.
# - `spread`/`ternary` callee markers share their shape with real calls, so
#   user bindings with those names are pinned instead of renamed.

type
  ManglePhase = enum mphCollect, mphRename

  MangleCtx = object
    m: Mangler
    phase: ManglePhase
    curB, curF: Scope
    prevWasWith: bool
    stripExports: bool

proc scopeKey(n: Node): pointer {.inline.} =
  cast[pointer](n)

proc isFnScopeKind(k: ScopeKind): bool {.inline.} =
  k in {skProgram, skFunction}

proc isEmptyishNode(n: Node): bool {.inline.} =
  n.isNil or n.kind == nkEmpty

proc stmtKwName(n: Node): string =
  ## Keyword of an nkStatement node, "" for anything else.
  if not n.isNil and n.kind == nkStatement and n.children.len > 0 and
     not n.children[0].isNil and n.children[0].kind == nkIdent:
    return n.children[0].name
  ""

proc isWithCall(n: Node): bool =
  ## `with` parses as a bare nkCall (never a statement), so it is detected
  ## by callee shape. A user function can never be named `with` (reserved).
  not n.isNil and n.kind == nkCall and n.children.len > 0 and
    not n.children[0].isNil and n.children[0].kind == nkIdent and
    n.children[0].name == "with"

proc isEvalCall(n: Node): bool =
  ## Direct eval by callee shape. Shadowed/indirect eval (`o.eval`, `(0,eval)`)
  ## never matches a bare-ident callee; exotic `(eval)()` over-taints safely.
  not n.isNil and n.kind == nkCall and n.children.len > 0 and
    not n.children[0].isNil and n.children[0].kind == nkIdent and
    n.children[0].name == "eval"

proc taintKind(m: Mangler, n: Node): int =
  ## Bitmask over a subtree: 1 = direct eval below, 2 = with below.
  ## Memoized, so the whole program costs one linear walk.
  if n.isNil or n.kind in LeafNodes:
    return 0
  let key = scopeKey(n)
  if m.taintMemo.hasKey(key):
    return m.taintMemo[key]
  var r = 0
  if isEvalCall(n):
    r = r or 1
  elif isWithCall(n):
    r = r or 2
  for c in n.children:
    if c.isNil or c.kind in LeafNodes:
      continue
    r = r or taintKind(m, c)
    if r == 3:
      break
  m.taintMemo[key] = r
  r

proc newScope(m: Mangler, ctx: var MangleCtx, kind: ScopeKind, node: Node,
              keepAll: bool): Scope =
  result = Scope(parent: ctx.curB, kind: kind, node: node,
    bindings: initTable[int, string](),
    labels: initTable[int, string](),
    pending: @[], labelPending: @[],
    used: initHashSet[int](),
    refNames: initHashSet[int](),
    pinnedByWith: initHashSet[int](),
    children: @[],
    keepAll: keepAll or (not ctx.curB.isNil and ctx.curB.keepAll),
    counter: 0, savedB: ctx.curB, savedF: ctx.curF)
  if not ctx.curB.isNil:
    ctx.curB.children.add(result)
  if not node.isNil:
    m.scopes[scopeKey(node)] = result
  ctx.curB = result
  if isFnScopeKind(kind):
    ctx.curF = result
  m.stack.add(result)

proc popScope(m: Mangler, ctx: var MangleCtx, s: Scope) =
  discard m.stack.pop()
  ctx.curB = s.savedB
  ctx.curF = s.savedF

proc noteUse(m: Mangler, ctx: MangleCtx, id: int) =
  ## Record an identifier use for every enclosing scope (collect phase).
  ## Property/key/marker positions never call this: positional names can
  ## never collide with a generated short. Reserved words can never be
  ## bindings either, so they are filtered (they would only bloat the
  ## reference sets); globals and sloppy frees still record.
  if ctx.phase != mphCollect or id in m.reserved:
    return
  for s in m.stack:
    s.refNames.incl(id)

proc doBind(ctx: var MangleCtx, s: Scope, id: int, keep: bool, name: string) =
  if ctx.phase != mphCollect:
    return
  # `spread`/`ternary` callee markers share their shape with real calls, so
  # user bindings with those names stay pinned instead of renamed.
  s.pending.add((id: id, keep: keep or name == "spread" or name == "ternary"))

proc doBindLabel(ctx: var MangleCtx, s: Scope, id: int, keep: bool) =
  if ctx.phase != mphCollect:
    return
  s.labelPending.add((id: id, keep: keep))

proc resolveIn(s: Scope, id: int, labNs: bool): tuple[short: string, ok: bool,
    keepAllOnPath: bool] =
  ## Innermost-first resolution over stored parent links (immune to walk
  ## drift). Reports whether a keepAll scope sits between the use and its
  ## binding, in which case the use keeps its original text.
  var sc = s
  var sawKeepAll = false
  while not sc.isNil:
    if sc.keepAll:
      sawKeepAll = true
    if labNs:
      if sc.labels.hasKey(id):
        return (sc.labels[id], true, sawKeepAll)
    else:
      if sc.bindings.hasKey(id):
        return (sc.bindings[id], true, sawKeepAll)
    sc = sc.parent
  ("", false, sawKeepAll)

proc doRename(ctx: var MangleCtx, node: Node, id: int, s: Scope, labNs: bool) =
  if ctx.phase != mphRename or node.isNil or node.kind != nkIdent:
    return
  if node.name.len > 0 and node.name[0] == '#':
    return # private names are properties, never bindings
  let r = resolveIn(s, id, labNs)
  if r.ok and not r.keepAllOnPath and r.short != node.name:
    node.name = r.short

proc enterRename(ctx: var MangleCtx, node: Node) =
  ## Switch to a scope registered in collect (program root is threaded).
  if ctx.phase != mphRename or node.isNil:
    return
  let key = scopeKey(node)
  if ctx.m.scopes.hasKey(key):
    let s = ctx.m.scopes[key]
    ctx.curB = s
    if isFnScopeKind(s.kind):
      ctx.curF = s

type
  IdentRole = enum irUse, irUseLabel, irBind, irBindLabel, irKeep, irSkip

proc walkStmt(ctx: var MangleCtx, n: Node)
proc walkValue(ctx: var MangleCtx, n: Node)
proc walkStmtList(ctx: var MangleCtx, nodes: openArray[Node])
proc walkTailSlots(ctx: var MangleCtx, nodes: openArray[Node], fromIdx: int)
proc walkFn(ctx: var MangleCtx, fn: Node, bindScope: Scope)
proc fnPlainName(fn: Node): Node
proc walkPatternDecl(ctx: var MangleCtx, n: Node, target: Scope)
proc walkPatternUse(ctx: var MangleCtx, n: Node)
proc walkDeclarator(ctx: var MangleCtx, def: Node, target: Scope, useMode: bool)
proc walkDeclAs(ctx: var MangleCtx, stmt: Node, blockTarget: Scope)
proc walkObjLiteral(ctx: var MangleCtx, n: Node)
proc keepWalk(ctx: var MangleCtx, n: Node, s: Scope)
proc walkWithBody(ctx: var MangleCtx, n: Node)
proc walkClassMembers(ctx: var MangleCtx, n: Node, body: Node)

template scopeBlock(ctx: var MangleCtx, kind: ScopeKind, node: Node,
                    keepAll: bool, body: untyped) =
  ## One template for scope entry in both phases: collect creates and
  ## registers the scope, rename looks it up. Identical traversal in both
  ## phases keeps the two perfectly consistent.
  if ctx.phase == mphCollect:
    let s = newScope(ctx.m, ctx, kind, node, keepAll)
    body
    popScope(ctx.m, ctx, s)
  else:
    let rb = ctx.curB
    let rf = ctx.curF
    enterRename(ctx, node)
    body
    ctx.curB = rb
    ctx.curF = rf

proc origName*(m: Mangler, n: Node): string =
  ## Pre-rename text of an identifier (for source-map `names`). Falls back
  ## to the current text for nodes the scoped pass never visited (property
  ## positions and coverage gaps keep their text, so the fallback is exact).
  if n.isNil or n.kind != nkIdent:
    return ""
  m.origNames.getOrDefault(scopeKey(n), n.name)

proc identSite(ctx: var MangleCtx, node: Node, role: IdentRole,
               target: Scope = nil) =
  ## Single choke point for identifier roles. Collect records bindings and
  ## uses; rename resolves both through the stored scope chain, so any
  ## coverage gap fails toward keep-keep consistency, never corruption.
  ## Names are interned once; all tables below compare small ints.
  if node.isNil or node.kind != nkIdent or node.name.len == 0:
    return
  if role == irSkip:
    return
  let id = ctx.m.intern(node.name)
  if ctx.phase == mphCollect:
    if ctx.m.trackOrig:
      # Source-map names need pre-rename text for every renamed ident.
      ctx.m.origNames[scopeKey(node)] = node.name
  if ctx.phase == mphCollect:
    case role
    of irUse, irUseLabel:
      noteUse(ctx.m, ctx, id)
    of irBind, irKeep:
      if not target.isNil:
        doBind(ctx, target, id, role == irKeep, node.name)
    of irBindLabel:
      if not target.isNil:
        doBindLabel(ctx, target, id, role == irKeep)
    of irSkip:
      discard
  else:
    case role
    of irUse:
      doRename(ctx, node, id, ctx.curB, false)
    of irUseLabel:
      doRename(ctx, node, id, ctx.curB, true)
    of irBind, irKeep:
      # Declaration sites rename to their own scope's entry directly, never
      # through the chain: the current scope may shadow the name with a
      # different binding (e.g. a function declaration shadowed by a const
      # of the same name inside its own body), and chain resolution would
      # pick the wrong one while uses resolve correctly.
      if not target.isNil and target.bindings.hasKey(id):
        let sh = target.bindings[id]
        if sh != node.name:
          node.name = sh
      # else: coverage gap fails toward keep-keep consistency.
    of irBindLabel:
      if not target.isNil and target.labels.hasKey(id):
        let sh = target.labels[id]
        if sh != node.name:
          node.name = sh
    of irSkip:
      discard

proc isTrivia(n: Node): bool =
  ## Nodes that carry no bindings and break no sibling adjacency.
  n.isNil or n.kind == nkEmpty or n.kind == nkInlineComment or
    n.kind == nkDocComment

proc isObjLiteralish(n: Node): bool =
  ## Mirror of codgen's isObjLiteral: statement blocks never hold bare
  ## nkColonExpr children, so the shapes stay unambiguous.
  if n.isNil or n.kind != nkBlock:
    return false
  for child in n.children:
    if child.isNil or child.kind == nkEmpty:
      continue
    if child.kind == nkInlineComment or child.kind == nkDocComment:
      continue
    if child.kind == nkCommentGroup:
      continue
    return child.kind == nkColonExpr or
      (child.kind == nkCall and child.children.len > 0 and
       not child.children[0].isNil and child.children[0].kind == nkIdent and
       child.children[0].name == "spread")
  false

proc scanIdentsKeep(ctx: var MangleCtx, text: string, s: Scope) =
  ## Over-approximate identifier scan of raw source text (template
  ## interpolations, catch destructuring kept verbatim by codegen).
  ## Everything found is self-mapped AND noted as used: the note blocks the
  ## word as a generated short everywhere below (sloppy-global rule), the
  ## self-map keeps declarations with the same name. Sound, conservative,
  ## vanishingly rare.
  if ctx.phase != mphCollect or s.isNil:
    return
  var i = 0
  while i < text.len:
    let c = text[i]
    if c == '\\' and i + 1 < text.len:
      i += 2
      continue
    if c in {'a'..'z', 'A'..'Z', '_', '$'}:
      var j = i + 1
      while j < text.len and text[j] in {'a'..'z', 'A'..'Z', '0'..'9', '_', '$'}:
        inc j
      let w = text[i ..< j]
      let id = ctx.m.intern(w)
      noteUse(ctx.m, ctx, id)
      doBind(ctx, s, id, true, w)
      i = j
    else:
      inc i

proc keepWalk(ctx: var MangleCtx, n: Node, s: Scope) =
  ## Keep an entire subtree verbatim (module interface names): every
  ## identifier self-maps in the current scope.
  if n.isNil:
    return
  if n.kind == nkIdent:
    if ctx.phase == mphCollect and not s.isNil:
      let id = ctx.m.intern(n.name)
      noteUse(ctx.m, ctx, id)
      doBind(ctx, s, id, true, n.name)
      if ctx.m.trackOrig:
        ctx.m.origNames[scopeKey(n)] = n.name
    elif ctx.phase == mphRename and not s.isNil:
      # Declaration-direct like all bind sites (see identSite).
      let id = ctx.m.intern(n.name)
      if s.bindings.hasKey(id):
        let sh = s.bindings[id]
        if sh != n.name:
          n.name = sh
    return
  if n.kind in LeafNodes:
    return
  for c in n.children:
    keepWalk(ctx, c, s)

proc walkWithBody(ctx: var MangleCtx, n: Node) =
  ## A with-body keeps every name (property shadowing is unknowable). One
  ## synthetic keepAll scope wraps any body shape; path pins are computed
  ## from its accumulated reference names before assignment.
  if ctx.phase == mphCollect:
    let s = newScope(ctx.m, ctx, skSynthetic, n, true)
    ctx.m.withBodies.add(s)
    walkStmt(ctx, n)
    popScope(ctx.m, ctx, s)
  else:
    let rb = ctx.curB
    let rf = ctx.curF
    enterRename(ctx, n)
    walkStmt(ctx, n)
    ctx.curB = rb
    ctx.curF = rf

proc walkTailSlots(ctx: var MangleCtx, nodes: openArray[Node], fromIdx: int) =
  ## Statement-list walk with the with-body rule: a with-call consumes its
  ## next sibling as its body (verified shape in if/while/block tails).
  ## Trivia never breaks adjacency; chains (`with(a) with(b) c()`) compose.
  var prevWith = false
  for i in fromIdx ..< nodes.len:
    let n = nodes[i]
    if isTrivia(n):
      continue
    if n.kind == nkCommentGroup:
      walkStmt(ctx, n)
      continue
    if prevWith:
      walkWithBody(ctx, n)
    else:
      walkStmt(ctx, n)
    prevWith = isWithCall(n)

proc walkStmtList(ctx: var MangleCtx, nodes: openArray[Node]) =
  walkTailSlots(ctx, nodes, 0)

proc walkStmtOrBlock(ctx: var MangleCtx, n: Node) =
  if isTrivia(n):
    return
  if n.kind == nkBlock:
    if isObjLiteralish(n):
      walkObjLiteral(ctx, n)
    else:
      scopeBlock(ctx, skBlock, n, false):
        walkStmtList(ctx, n.children)
    return
  walkStmt(ctx, n)

proc walkObjLiteral(ctx: var MangleCtx, n: Node) =
  ## Object literal members: keys are property namespace (skipped),
  ## values are uses, methods open function scopes. Parser-expanded
  ## `{a: a}` shorthand degrades back to `{a: x}` when renamed.
  if n.isNil or n.kind in LeafNodes:
    return
  for child in n.children:
    if child.isNil or child.kind == nkEmpty or
       child.kind == nkInlineComment or child.kind == nkDocComment:
      continue
    if child.kind == nkCommentGroup:
      for c in child.children:
        if not c.isNil and c.kind != nkInlineComment and
           c.kind != nkDocComment:
          walkValue(ctx, c)
      continue
    if child.kind == nkColonExpr:
      if child.children.len < 2:
        continue
      let key = child.children[0]
      let val = child.children[1]
      if child.children.len >= 3 and not child.children[2].isNil and
         child.children[2].kind == nkIdent and child.children[2].name == "=":
        # Destructuring default `{key = default}`: key stays (codegen emits
        # it raw), the default is an ordinary value use.
        if not key.isNil and key.kind == nkIdent:
          identSite(ctx, key, irKeep, ctx.curB)
        walkValue(ctx, val)
        continue
      if not val.isNil and val.kind == nkEmpty:
        # Bare shorthand `{a}`: normalize to expanded `[a, a-dup]` once in
        # collect (rename sees the expanded shape). The value then degrades
        # to `key: short` in codegen when renamed, exactly like parsed.
        if not key.isNil and key.kind == nkIdent:
          if ctx.phase == mphCollect:
            child.children[1] = Node(kind: nkIdent, name: key.name)
            identSite(ctx, child.children[1], irUse)
        continue
      if not key.isNil and key.kind == nkStatement:
        walkValue(ctx, key) # computed `[expr]`
      # Plain ident / string keys: property namespace, skipped.
      if val.isNil:
        continue
      if val.kind == nkFunction:
        walkFn(ctx, val, nil)
      else:
        walkValue(ctx, val)
      continue
    if child.kind == nkCall:
      walkValue(ctx, child) # spread member; callee marker stays pinned
      continue
    if child.kind == nkFunction:
      walkFn(ctx, child, nil)
      continue
    walkValue(ctx, child)

proc walkPatternDecl(ctx: var MangleCtx, n: Node, target: Scope) =
  ## Binding patterns (`var {a, b: [c]}`, params, catch): idents bind in
  ## the target scope, defaults and computed keys are value uses. The
  ## `{a = d}` shape keeps its key (codegen emits it raw).
  if n.isNil or n.kind in LeafNodes:
    if not n.isNil and n.kind == nkIdent:
      identSite(ctx, n, irBind, target)
    return
  case n.kind
  of nkIdent:
    identSite(ctx, n, irBind, target)
  of nkArrayLit:
    for el in n.children:
      if el.isNil or el.kind == nkEmpty:
        continue
      if el.kind == nkIdent:
        identSite(ctx, el, irBind, target)
      elif el.kind == nkInfix and el.children.len >= 3 and
           not el.children[0].isNil and el.children[0].kind == nkIdent and
           el.children[0].name == "=":
        walkPatternDecl(ctx, el.children[1], target)
        walkValue(ctx, el.children[2])
      elif el.kind == nkPrefix:
        for j in 1 ..< el.children.len:
          if el.children[j].isNil or el.children[j].kind == nkEmpty:
            continue
          walkPatternDecl(ctx, el.children[j], target)
      elif el.kind == nkBlock or el.kind == nkArrayLit or
           el.kind == nkIdentDefs:
        walkPatternDecl(ctx, el, target)
      else:
        walkValue(ctx, el)
  of nkBlock:
    for member in n.children:
      if member.isNil or member.kind == nkEmpty or
         member.kind == nkInlineComment or member.kind == nkDocComment:
        continue
      if member.kind != nkColonExpr or member.children.len < 2:
        walkValue(ctx, member)
        continue
      let key = member.children[0]
      let val = member.children[1]
      if member.children.len >= 3 and not member.children[2].isNil and
         member.children[2].kind == nkIdent and
         member.children[2].name == "=":
        if not key.isNil and key.kind == nkIdent:
          identSite(ctx, key, irKeep, target)
        walkValue(ctx, val)
        continue
      if not val.isNil and val.kind == nkEmpty:
        # Bare shorthand: normalize to expanded once in collect (rename
        # sees `[a, a-dup]` and binds the value like parsed shorthand).
        if not key.isNil and key.kind == nkIdent:
          if ctx.phase == mphCollect:
            member.children[1] = Node(kind: nkIdent, name: key.name)
            identSite(ctx, member.children[1], irBind, target)
        continue
      if not val.isNil and val.kind == nkInfix and val.children.len >= 3 and
         not val.children[0].isNil and val.children[0].kind == nkIdent and
         val.children[0].name == "=":
        walkPatternDecl(ctx, val.children[1], target)
        walkValue(ctx, val.children[2])
      elif not val.isNil and (val.kind == nkBlock or val.kind == nkArrayLit or
                              val.kind == nkIdentDefs):
        walkPatternDecl(ctx, val, target)
      elif not val.isNil and val.kind == nkIdent:
        identSite(ctx, val, irBind, target)
      else:
        walkValue(ctx, val)
  of nkIdentDefs:
    if n.children.len > 0:
      walkPatternDecl(ctx, n.children[0], target)
    for j in 1 ..< n.children.len:
      if n.children[j].isNil or n.children[j].kind == nkEmpty:
        continue
      if j == 1:
        keepWalk(ctx, n.children[j], ctx.curB) # type slot: kept verbatim
      else:
        walkValue(ctx, n.children[j]) # default value
  of nkStatement:
    if stmtKwName(n) in ["var", "let", "const"]:
      walkDeclAs(ctx, n, target)
    else:
      for i in 1 ..< n.children.len:
        walkValue(ctx, n.children[i])
  else:
    for c in n.children:
      walkValue(ctx, c)

proc walkPatternUse(ctx: var MangleCtx, n: Node) =
  ## Assignment-target patterns (`{a} = x`): nothing binds, keys are
  ## property reads, values resolve. Bare keys keep (raw emission).
  if n.isNil or n.kind in LeafNodes:
    if not n.isNil and n.kind == nkIdent:
      identSite(ctx, n, irUse)
    return
  case n.kind
  of nkIdent:
    identSite(ctx, n, irUse)
  of nkArrayLit:
    for el in n.children:
      if el.isNil or el.kind == nkEmpty:
        continue
      if el.kind == nkIdent:
        identSite(ctx, el, irUse)
      elif el.kind == nkInfix and el.children.len >= 3 and
           not el.children[0].isNil and el.children[0].kind == nkIdent and
           el.children[0].name == "=":
        walkPatternUse(ctx, el.children[1])
        walkValue(ctx, el.children[2])
      elif el.kind == nkPrefix:
        for j in 1 ..< el.children.len:
          if el.children[j].isNil or el.children[j].kind == nkEmpty:
            continue
          walkPatternUse(ctx, el.children[j])
      elif el.kind == nkBlock or el.kind == nkArrayLit or
           el.kind == nkIdentDefs:
        walkPatternUse(ctx, el)
      else:
        walkValue(ctx, el)
  of nkBlock:
    for member in n.children:
      if member.isNil or member.kind == nkEmpty or
         member.kind == nkInlineComment or member.kind == nkDocComment:
        continue
      if member.kind != nkColonExpr or member.children.len < 2:
        walkValue(ctx, member)
        continue
      let key = member.children[0]
      let val = member.children[1]
      if member.children.len >= 3 and not member.children[2].isNil and
         member.children[2].kind == nkIdent and
         member.children[2].name == "=":
        walkPatternUse(ctx, key)
        walkValue(ctx, val)
        continue
      if not val.isNil and val.kind == nkEmpty:
        # Bare shorthand target: normalize to expanded once in collect;
        # rename degrades it to `key: short` like parsed shorthand.
        if not key.isNil and key.kind == nkIdent:
          if ctx.phase == mphCollect:
            member.children[1] = Node(kind: nkIdent, name: key.name)
            identSite(ctx, member.children[1], irUse)
        continue
      if not val.isNil and val.kind == nkInfix and val.children.len >= 3 and
         not val.children[0].isNil and val.children[0].kind == nkIdent and
         val.children[0].name == "=":
        walkPatternUse(ctx, val.children[1])
        walkValue(ctx, val.children[2])
      elif not val.isNil and (val.kind == nkBlock or val.kind == nkArrayLit or
                              val.kind == nkIdentDefs):
        walkPatternUse(ctx, val)
      elif not val.isNil and val.kind == nkIdent:
        identSite(ctx, val, irUse)
      else:
        walkValue(ctx, val)
  else:
    for c in n.children:
      walkValue(ctx, c)

proc walkDeclarator(ctx: var MangleCtx, def: Node, target: Scope,
                    useMode: bool) =
  if def.isNil or def.kind == nkEmpty:
    return
  if def.kind == nkIdent:
    identSite(ctx, def, if useMode: irUse else: irBind, target)
    return
  if def.kind == nkBlock or def.kind == nkArrayLit:
    if useMode:
      walkPatternUse(ctx, def)
    else:
      walkPatternDecl(ctx, def, target)
    return
  if def.kind != nkIdentDefs:
    walkValue(ctx, def)
    return
  if def.children.len > 0:
    let head = def.children[0]
    if not head.isNil and head.kind == nkIdent:
      identSite(ctx, head, if useMode: irUse else: irBind, target)
    elif not head.isNil and (head.kind == nkBlock or head.kind == nkArrayLit or
                             head.kind == nkIdentDefs):
      if useMode:
        walkPatternUse(ctx, head)
      else:
        walkPatternDecl(ctx, head, target)
    elif not head.isNil:
      walkValue(ctx, head)
  for j in 1 ..< def.children.len:
    if def.children[j].isNil or def.children[j].kind == nkEmpty:
      continue
    if j == 1 and not useMode:
      keepWalk(ctx, def.children[j], ctx.curB) # type slot: kept verbatim
    else:
      walkValue(ctx, def.children[j]) # initializer / default value

proc walkDeclAs(ctx: var MangleCtx, stmt: Node, blockTarget: Scope) =
  ## var/let/const statements. `var` hoists to the function scope no matter
  ## how deeply nested; let/const bind the given block target.
  if stmt.isNil or stmt.kind in LeafNodes or stmt.children.len == 0:
    return
  let target =
    if stmtKwName(stmt) == "var": ctx.curF
    else: blockTarget
  for i in 1 ..< stmt.children.len:
    walkDeclarator(ctx, stmt.children[i], target, false)

proc walkValue(ctx: var MangleCtx, n: Node) =
  ## Expression position. Every ident is a use except dot right-hand sides,
  ## member keys and callee/operator markers (positional, never bindings).
  ## Missed resolutions keep their text, which is always sound.
  if n.isNil or n.kind in LeafNodes:
    if not n.isNil and n.kind == nkIdent:
      identSite(ctx, n, irUse)
    elif not n.isNil and n.kind == nkLitString and n.valStr.len >= 2 and
         n.valStr[0] == '`':
      # Template literal: `${...}` interpolations are raw code text that
      # codegen passes through byte-exact, so every word they mention must
      # keep its name or declarations would detach from their uses.
      scanIdentsKeep(ctx, n.valStr, ctx.curB)
    return
  case n.kind
  of nkIdent:
    identSite(ctx, n, irUse)
  of nkDotExpr:
    if n.children.len >= 1:
      walkValue(ctx, n.children[0])
    # Right-hand side: property namespace, skipped.
  of nkCall:
    if n.children.len > 0:
      let callee = n.children[0]
      if not callee.isNil and callee.kind == nkIdent and
         (callee.name == "spread" or callee.name == "ternary" or
          callee.name == "with" or callee.name == "eval"):
        discard # markers and tainted callees keep their text
      else:
        walkValue(ctx, callee)
      for i in 1 ..< n.children.len:
        walkValue(ctx, n.children[i])
  of nkBlock:
    if isObjLiteralish(n):
      walkObjLiteral(ctx, n)
    else:
      scopeBlock(ctx, skBlock, n, false):
        walkStmtList(ctx, n.children)
  of nkStatement:
    let kw = stmtKwName(n)
    if kw == "comma":
      for i in 1 ..< n.children.len:
        walkValue(ctx, n.children[i])
    elif kw == "function" and n.children.len > 1:
      let inner = n.children[1]
      if not inner.isNil and inner.kind == nkFunction:
        walkFn(ctx, inner,
          if not fnPlainName(inner).isNil: ctx.curF else: nil)
      else:
        walkValue(ctx, inner)
    elif kw == "computed":
      if n.children.len > 1:
        walkValue(ctx, n.children[1])
    else:
      for i in 1 ..< n.children.len:
        let c = n.children[i]
        if c.isNil:
          continue
        if c.kind == nkStatement or c.kind == nkBlock or c.kind == nkFunction:
          walkStmt(ctx, c)
        else:
          walkValue(ctx, c)
  of nkFunction:
    walkFn(ctx, n, nil)
  else:
    for c in n.children:
      walkValue(ctx, c)

proc walkFnParams(ctx: var MangleCtx, params: Node, fnScope: Scope) =
  ## One nkIdentDefs of formal parameters (or generic parameters, which
  ## rename consistently with their annotation uses).
  if params.isNil or params.kind in LeafNodes or params.kind != nkIdentDefs:
    return
  for p in params.children:
    if p.isNil or p.kind == nkEmpty:
      continue
    if p.kind == nkIdent:
      identSite(ctx, p, irBind, fnScope)
    elif p.kind == nkIdentDefs:
      if p.children.len > 0:
        walkPatternDecl(ctx, p.children[0], fnScope)
      for j in 1 ..< p.children.len:
        if p.children[j].isNil or p.children[j].kind == nkEmpty:
          continue
        if j == 1:
          keepWalk(ctx, p.children[j], fnScope)
        else:
          walkValue(ctx, p.children[j])
    elif p.kind == nkPrefix:
      for j in 1 ..< p.children.len:
        if p.children[j].isNil or p.children[j].kind == nkEmpty:
          continue
        walkPatternDecl(ctx, p.children[j], fnScope)
    elif p.kind == nkBlock or p.kind == nkArrayLit:
      walkPatternDecl(ctx, p, fnScope)
    else:
      walkValue(ctx, p)

proc isMFlag(name: string): bool {.inline.} =
  ## Mirror of codgen.isMethodFlag (mangler cannot import codgen): method
  ## member flags other than `*`. Keep in sync.
  case name.len
  of 3: name == "get" or name == "set"
  of 5: name == "async"
  of 6: name == "static"
  else: false

proc fnIsArrow(fn: Node): bool {.inline.} =
  ## Mirror of genFn's arrow test: leading empty marker or async flag.
  fn.children.len > 0 and not fn.children[0].isNil and
    (fn.children[0].kind == nkEmpty or
     (fn.children[0].kind == nkIdent and fn.children[0].name == "async"))

proc fnPlainName(fn: Node): Node =
  ## Mirror of genFn's plain-function name slot (index 2): nil when absent.
  ## Method and arrow shapes never bind a name of their own.
  if fnIsArrow(fn):
    return nil
  let ch = fn.children
  if ch.len > 0 and not ch[0].isNil and ch[0].kind == nkIdent and
     ch[0].name == "function" and ch.len > 2 and not ch[2].isNil and
     ch[2].kind == nkIdent:
    return ch[2]
  nil

proc walkFn(ctx: var MangleCtx, fn: Node, bindScope: Scope) =
  ## Any function shape. Slots mirror genFn/genMethod exactly (fixed
  ## indices, never kind-scans: a kind-scan would capture parameter lists
  ## nested inside default values). `bindScope` binds a declaration name,
  ## nil self-binds an expression name inside its own scope.
  if fn.isNil or fn.kind in LeafNodes or fn.kind != nkFunction:
    return
  let ch = fn.children
  if fnIsArrow(fn):
    scopeBlock(ctx, skFunction, fn, false):
      if ch.len > 1 and not ch[1].isNil:
        if ch[1].kind == nkIdentDefs:
          walkFnParams(ctx, ch[1], ctx.curF)
        else:
          walkPatternDecl(ctx, ch[1], ctx.curF)
      if ch.len > 2 and not ch[2].isNil:
        let body = ch[2]
        if body.kind == nkBlock and isObjLiteralish(body):
          walkObjLiteral(ctx, body) # parenthesized object body
        elif body.kind == nkBlock:
          walkStmtList(ctx, body.children) # block body, fn scope itself
        elif body.kind != nkEmpty:
          walkValue(ctx, body) # concise body
    return
  if ch.len > 0 and not ch[0].isNil and ch[0].kind == nkIdent and
     ch[0].name == "function":
    # Plain function (declaration or named expression).
    scopeBlock(ctx, skFunction, fn, false):
      let nm = fnPlainName(fn)
      if not nm.isNil:
        if bindScope.isNil:
          identSite(ctx, nm, irBind, ctx.curF)
        else:
          identSite(ctx, nm, irBind, bindScope)
      if ch.len > 3 and not ch[3].isNil and ch[3].kind == nkIdentDefs:
        walkFnParams(ctx, ch[3], ctx.curF) # generics: consistent w/ uses
      if ch.len > 4 and not ch[4].isNil and ch[4].kind == nkIdentDefs:
        walkFnParams(ctx, ch[4], ctx.curF)
      let bodyIdx = if ch.len >= 7: 6 else: ch.len - 1
      if bodyIdx > 4 and bodyIdx < ch.len and not ch[bodyIdx].isNil:
        let body = ch[bodyIdx]
        if body.kind == nkBlock and not isObjLiteralish(body):
          walkStmtList(ctx, body.children)
        elif body.kind != nkEmpty and body.kind != nkBlock:
          walkStmt(ctx, body)
    return
  # Method shape: leading flags, optional empty marker, params, body.
  scopeBlock(ctx, skFunction, fn, false):
    var i = 0
    while i < ch.len and not ch[i].isNil and ch[i].kind == nkIdent and
          (ch[i].name == "*" or isMFlag(ch[i].name)):
      inc i
    if i < ch.len and not ch[i].isNil and ch[i].kind == nkEmpty:
      inc i
    if i < ch.len and not ch[i].isNil and ch[i].kind == nkIdentDefs:
      walkFnParams(ctx, ch[i], ctx.curF)
    if ch.len > 0:
      let body = ch[^1]
      if not body.isNil and body.kind == nkBlock:
        if not isObjLiteralish(body):
          walkStmtList(ctx, body.children)
      elif not body.isNil and body.kind != nkEmpty:
        walkStmt(ctx, body)

proc walkForStmt(ctx: var MangleCtx, n: Node) =
  ## Classic and for-of/in loops. `var` initializers hoist to the function
  ## scope; let/const bind the loop scope shared with the body head.
  if n.isNil or n.kind in LeafNodes or n.children.len < 2:
    return
  scopeBlock(ctx, skFor, n, false):
    let marker =
      if n.children.len > 1 and not n.children[1].isNil and
         n.children[1].kind == nkIdent: n.children[1].name
      else: ""
    if marker in ["of", "in", "await-of", "await-in"] and n.children.len >= 4:
      let lhs = n.children[2]
      if not lhs.isNil and lhs.kind == nkStatement and
         stmtKwName(lhs) in ["var", "let", "const"]:
        walkDeclAs(ctx, lhs, ctx.curB)
      elif not lhs.isNil and (lhs.kind == nkBlock or lhs.kind == nkArrayLit):
        walkPatternUse(ctx, lhs)
      else:
        walkValue(ctx, lhs)
      walkValue(ctx, n.children[3])
      if n.children.len > 4:
        walkStmtOrBlock(ctx, n.children[4])
      if n.children.len > 5:
        walkTailSlots(ctx, n.children, 5)
    else:
      if n.children.len > 1:
        let init = n.children[1]
        if not init.isNil and init.kind == nkStatement and
           stmtKwName(init) in ["var", "let", "const"]:
          walkDeclAs(ctx, init, ctx.curB)
        elif not init.isNil and init.kind != nkEmpty:
          walkValue(ctx, init)
      if n.children.len > 2:
        walkValue(ctx, n.children[2])
      if n.children.len > 3:
        walkValue(ctx, n.children[3])
      if n.children.len > 4:
        walkStmtOrBlock(ctx, n.children[4])
      if n.children.len > 5:
        walkTailSlots(ctx, n.children, 5)

proc walkClassStmt(ctx: var MangleCtx, n: Node, isDecl: bool) =
  ## Class declarations bind the enclosing block scope; named class
  ## expressions additionally self-bind for their method bodies. `extends`
  ## always resolves in the enclosing scopes.
  if n.isNil or n.kind in LeafNodes or n.children.len < 2:
    return
  let nameNode =
    if n.children[1].kind == nkIdent: n.children[1] else: nil
  if isDecl and not nameNode.isNil:
    identSite(ctx, nameNode, irBind, ctx.curB)
  if n.children.len > 2 and not n.children[2].isNil and
     n.children[2].kind != nkEmpty:
    walkValue(ctx, n.children[2]) # extends
  if n.children.len <= 3:
    return
  let body = n.children[3]
  if body.isNil or body.kind in LeafNodes or body.kind != nkBlock:
    walkValue(ctx, body)
    return
  if not isDecl and not nameNode.isNil:
    scopeBlock(ctx, skClassSelf, n, false):
      identSite(ctx, nameNode, irBind, ctx.curB)
      walkClassMembers(ctx, n, body)
  else:
    walkClassMembers(ctx, n, body)

proc walkClassMembers(ctx: var MangleCtx, n: Node, body: Node) =
  if body.isNil or body.kind in LeafNodes:
    return
  for child in body.children:
    if child.isNil or child.kind == nkEmpty or
       child.kind == nkInlineComment or child.kind == nkDocComment:
      continue
    if child.kind == nkStatement and stmtKwName(child) == "static-block":
      if child.children.len > 1:
        walkStmtOrBlock(ctx, child.children[1])
      continue
    if child.kind == nkStatement and stmtKwName(child) == "field" and
       child.children.len >= 3:
      var j = 1
      while j < child.children.len - 2:
        j = j # flags (`*`, get/set/async/static) are positional, skipped
        if child.children[j].isNil:
          inc j
          continue
        if child.children[j].kind == nkIdent and
           (child.children[j].name == "*" or child.children[j].name == "get" or
            child.children[j].name == "set" or
            child.children[j].name == "async" or
            child.children[j].name == "static"):
          inc j
        else:
          break
      let key = child.children[j]
      if not key.isNil and key.kind == nkStatement:
        walkValue(ctx, key) # computed `[expr]`
      # Plain ident / string keys: property namespace, skipped.
      let init = child.children[j + 1]
      if not init.isNil and init.kind != nkEmpty:
        walkValue(ctx, init)
      continue
    if child.kind != nkColonExpr or child.children.len < 2:
      walkValue(ctx, child)
      continue
    let key = child.children[0]
    let val = child.children[1]
    if not key.isNil and key.kind == nkStatement:
      walkValue(ctx, key) # computed `[expr]`
    if val.isNil or val.kind == nkEmpty:
      continue
    if val.kind == nkFunction:
      walkFn(ctx, val, nil)
    else:
      walkValue(ctx, val) # initialized field `x = expr`

proc boundIdsOf(ctx: var MangleCtx, n: Node): seq[int] =
  ## Read-only shape walk returning the ids a declarator binds (no side
  ## effects): used to pre-keep exported names before the normal walk
  ## binds everything around them.
  if n.isNil or n.kind in LeafNodes:
    if not n.isNil and n.kind == nkIdent:
      return @[ctx.m.intern(n.name)]
    return @[]
  case n.kind
  of nkIdent:
    return @[ctx.m.intern(n.name)]
  of nkArrayLit:
    for el in n.children:
      if el.isNil or el.kind == nkEmpty:
        continue
      if el.kind == nkInfix and el.children.len >= 3 and
         not el.children[0].isNil and el.children[0].kind == nkIdent and
         el.children[0].name == "=":
        result.add(boundIdsOf(ctx, el.children[1]))
      elif el.kind == nkPrefix:
        for j in 1 ..< el.children.len:
          result.add(boundIdsOf(ctx, el.children[j]))
      else:
        result.add(boundIdsOf(ctx, el))
  of nkBlock:
    for member in n.children:
      if member.isNil or member.kind != nkColonExpr or member.children.len < 2:
        continue
      let key = member.children[0]
      let val = member.children[1]
      if member.children.len >= 3 and not member.children[2].isNil and
         member.children[2].kind == nkIdent and
         member.children[2].name == "=":
        if not key.isNil and key.kind == nkIdent:
          result.add(ctx.m.intern(key.name))
      elif not val.isNil and val.kind == nkEmpty:
        if not key.isNil and key.kind == nkIdent:
          result.add(ctx.m.intern(key.name))
      elif not val.isNil and val.kind == nkInfix and val.children.len >= 3 and
           not val.children[0].isNil and val.children[0].kind == nkIdent and
           val.children[0].name == "=":
        result.add(boundIdsOf(ctx, val.children[1]))
      else:
        result.add(boundIdsOf(ctx, val))
  of nkIdentDefs:
    if n.children.len > 0:
      result.add(boundIdsOf(ctx, n.children[0]))
  else:
    discard

proc preKeep(ctx: var MangleCtx, s: Scope, id: int) =
  ## Self-map `id` in `s` before the normal walk binds around it: the
  ## later normal arrival respects the existing keep entry.
  if ctx.phase != mphCollect or s.isNil:
    return
  doBind(ctx, s, id, true, ctx.m.names[id])

proc walkImportExport(ctx: var MangleCtx, n: Node) =
  ## Module boundary names keep their text (stripped imports vanish with the
  ## statement; stripped export declarations behave like plain ones).
  if n.isNil or n.kind in LeafNodes:
    return
  let kw = stmtKwName(n)
  if kw == "import" and ctx.stripExports:
    return
  if kw == "export" and ctx.stripExports:
    if n.children.len > 1:
      let inner = n.children[1]
      if inner.isNil:
        return
      if inner.kind == nkIdent and inner.name == "default":
        if n.children.len > 2:
          let expr = n.children[2]
          if not expr.isNil and expr.kind == nkFunction:
            if not fnPlainName(expr).isNil:
              walkFn(ctx, expr, ctx.curF)
            else:
              walkValue(ctx, expr)
          elif not expr.isNil and expr.kind == nkStatement and
               stmtKwName(expr) == "class":
            walkClassStmt(ctx, expr, true)
          else:
            walkValue(ctx, expr) # `var __default = expr` is synthetic
        return
      if inner.kind == nkFunction:
        walkFn(ctx, inner,
          if not fnPlainName(inner).isNil: ctx.curF else: nil)
        return
      if inner.kind == nkStatement:
        walkStmt(ctx, inner)
        return
    return
  if kw == "export" and not ctx.stripExports:
    # Preserved module interface: exported declaration names keep their
    # text (importers link against them), but parameters, locals and
    # initializers still mangle. Specifier lists (`export {a, b}`) keep
    # everything; default expressions are ordinary values.
    if n.children.len > 1:
      let inner = n.children[1]
      if not inner.isNil and inner.kind == nkIdent and inner.name == "default":
        if n.children.len > 2:
          walkValue(ctx, n.children[2])
        return
      if not inner.isNil and inner.kind == nkFunction and
         not fnPlainName(inner).isNil:
        preKeep(ctx, ctx.curB, ctx.m.intern(fnPlainName(inner).name))
        walkFn(ctx, inner, ctx.curF)
        return
      if not inner.isNil and inner.kind == nkStatement and
         stmtKwName(inner) == "class" and inner.children.len > 1 and
         not inner.children[1].isNil and inner.children[1].kind == nkIdent:
        preKeep(ctx, ctx.curB, ctx.m.intern(inner.children[1].name))
        walkClassStmt(ctx, inner, true)
        return
      if not inner.isNil and inner.kind == nkStatement and
         stmtKwName(inner) in ["var", "let", "const"]:
        for i in 1 ..< inner.children.len:
          for id in boundIdsOf(ctx, inner.children[i]):
            preKeep(ctx, ctx.curB, id)
        walkDeclAs(ctx, inner, ctx.curB)
        return
    for i in 1 ..< n.children.len:
      keepWalk(ctx, n.children[i], ctx.curB)
    return
  # Preserved module interface: every name self-maps.
  for i in 1 ..< n.children.len:
    keepWalk(ctx, n.children[i], ctx.curB)

proc walkStmt(ctx: var MangleCtx, n: Node) =
  if n.isNil or n.kind == nkEmpty or n.kind == nkInlineComment or
     n.kind == nkDocComment:
    return
  if n.kind == nkCommentGroup:
    for c in n.children:
      if not c.isNil and c.kind != nkInlineComment and c.kind != nkDocComment:
        walkStmt(ctx, c)
    return
  if n.kind == nkBlock:
    if isObjLiteralish(n):
      walkObjLiteral(ctx, n)
    else:
      scopeBlock(ctx, skBlock, n, false):
        walkStmtList(ctx, n.children)
    return
  if n.kind == nkReturn:
    for c in n.children:
      walkValue(ctx, c)
    return
  if n.kind == nkFunction:
    # Bare named plain function: a declaration (Annex-B binds the function
    # scope, which also keeps sloppy hoisting sound); anything else is an
    # expression with a self-bound name.
    if not fnPlainName(n).isNil:
      walkFn(ctx, n, ctx.curF)
    else:
      walkFn(ctx, n, nil)
    return
  if n.kind != nkStatement:
    walkValue(ctx, n)
    return
  let kw = stmtKwName(n)
  if kw == "var" or kw == "let" or kw == "const":
    walkDeclAs(ctx, n, ctx.curB)
  elif kw == "if":
    if n.children.len > 1:
      walkValue(ctx, n.children[1])
    if n.children.len > 2:
      walkTailSlots(ctx, n.children, 2)
  elif kw == "while":
    if n.children.len > 1:
      walkValue(ctx, n.children[1])
    if n.children.len > 2:
      walkTailSlots(ctx, n.children, 2)
  elif kw == "do-while":
    if n.children.len > 1:
      walkStmtOrBlock(ctx, n.children[1])
    if n.children.len > 2:
      # Trailing extras (with-bodies) walk as statements, the last child
      # stays the condition value.
      if n.children.len > 3:
        walkTailSlots(ctx, n.children[2 .. ^2], 0)
      walkValue(ctx, n.children[^1])
  elif kw == "for":
    walkForStmt(ctx, n)
  elif kw == "switch":
    if n.children.len > 1:
      walkValue(ctx, n.children[1])
    if n.children.len > 2:
      let body = n.children[2]
      if not body.isNil and body.kind == nkBlock:
        scopeBlock(ctx, skSwitch, n, false):
          walkStmtList(ctx, body.children)
      else:
        walkStmt(ctx, body)
  elif kw == "try":
    for i in 1 ..< n.children.len:
      let clause = n.children[i]
      if clause.isNil:
        continue
      if clause.kind == nkBlock:
        scopeBlock(ctx, skBlock, clause, false):
          walkStmtList(ctx, clause.children)
      elif clause.kind == nkStatement and stmtKwName(clause) == "except":
        scopeBlock(ctx, skCatch, clause, false):
          if clause.children.len > 1:
            let param = clause.children[1]
            if not param.isNil and param.kind == nkIdent:
              identSite(ctx, param, irBind, ctx.curB)
            elif not param.isNil and (param.kind == nkBlock or
                                      param.kind == nkArrayLit):
              walkPatternDecl(ctx, param, ctx.curB)
            elif not param.isNil and param.kind == nkLitString:
              scanIdentsKeep(ctx, param.valStr, ctx.curB)
          if clause.children.len > 2:
            # The catch body shares the catch scope (no extra push).
            for j in 2 ..< clause.children.len - 1:
              walkStmt(ctx, clause.children[j])
            let body = clause.children[^1]
            if not body.isNil and body.kind == nkBlock:
              walkStmtList(ctx, body.children)
            elif not body.isNil:
              walkStmt(ctx, body)
      else:
        walkStmtOrBlock(ctx, clause)
  elif kw == "label":
    if n.children.len > 1 and not n.children[1].isNil and
       n.children[1].kind == nkIdent:
      identSite(ctx, n.children[1], irBindLabel, ctx.curB)
    if n.children.len > 2:
      walkTailSlots(ctx, n.children, 2)
  elif kw == "break" or kw == "continue":
    if n.children.len > 1 and not n.children[1].isNil and
       n.children[1].kind == nkIdent:
      identSite(ctx, n.children[1], irUseLabel)
  elif kw == "return" or kw == "throw":
    for i in 1 ..< n.children.len:
      walkValue(ctx, n.children[i])
  elif kw == "debugger":
    discard
  elif kw == "class":
    walkClassStmt(ctx, n, true)
  elif kw == "function":
    if n.children.len > 1:
      let inner = n.children[1]
      if not inner.isNil and inner.kind == nkFunction:
        walkFn(ctx, inner,
          if not fnPlainName(inner).isNil: ctx.curF else: nil)
      else:
        walkValue(ctx, inner)
  elif kw == "async":
    if n.children.len > 1:
      let inner = n.children[1]
      if not inner.isNil and inner.kind == nkFunction:
        walkFn(ctx, inner,
          if not fnPlainName(inner).isNil: ctx.curF else: nil)
      else:
        walkValue(ctx, inner)
    if n.children.len > 2:
      walkTailSlots(ctx, n.children, 2)
  elif kw == "import" or kw == "export":
    walkImportExport(ctx, n)
  elif kw == "comma":
    for i in 1 ..< n.children.len:
      walkValue(ctx, n.children[i])
  elif kw == "computed":
    if n.children.len > 1:
      walkValue(ctx, n.children[1])
  elif kw == "field":
    walkClassMembers(ctx, n, n)
  else:
    for i in 1 ..< n.children.len:
      let c = n.children[i]
      if c.isNil:
        continue
      if c.kind == nkStatement or c.kind == nkBlock or c.kind == nkFunction:
        walkStmt(ctx, c)
      else:
        walkValue(ctx, c)

proc isBoundAbove(s: Scope, id: int): bool =
  ## Whether `id` names a value binding in this scope or any ancestor.
  ## Replaces the old cloned chain sets: a linear walk over pending lists
  ## (int compares, cache-friendly) instead of hashing long strings into
  ## thousands of cloned sets. Labels live in a separate namespace and are
  ## excluded: a value short colliding with a label original is positional
  ## and harmless.
  var sc = s
  while not sc.isNil:
    for e in sc.pending:
      if e.id == id:
        return true
    sc = sc.parent
  false

proc nextShort(m: Mangler, s: Scope, ancUsed: HashSet[int]): string =
  ## Shortest name avoiding pinned words, own-scope names, referenced
  ## ancestor shorts (textual shadowing collisions) and free names used
  ## below (sloppy globals, environment names).
  while true:
    result = genShortName(s.counter)
    s.counter += 1
    let cid = m.intern(result)
    if cid in m.pinned:
      continue
    if cid in s.used:
      continue
    if cid in ancUsed:
      continue
    when defined(mangleTime):
      let tN0 = epochTime()
    let freeBlocked = cid in s.refNames and not isBoundAbove(s, cid)
    when defined(mangleTime):
      m.tNextShort += epochTime() - tN0
    if freeBlocked:
      continue
    break

proc assignOne(m: Mangler, s: Scope, id: int, keep: bool,
               ancUsed: HashSet[int], labNs: bool) =
  if labNs:
    if s.labels.hasKey(id):
      if keep:
        s.labels[id] = m.names[id]
        s.used.incl(id)
      return
    if keep:
      s.labels[id] = m.names[id]
      s.used.incl(id)
      m.mapping[id] = m.names[id]
      return
    let c = nextShort(m, s, ancUsed)
    s.labels[id] = c
    s.used.incl(m.intern(c))
    m.mapping[id] = c
    return
  if s.bindings.hasKey(id):
    if keep:
      # Keep-role arrives late (e.g. an export specifier after the var):
      # the exported link needs the original text everywhere.
      s.bindings[id] = m.names[id]
      s.used.incl(id)
    return
  if keep or id in m.preserved:
    # Explicitly preserved names (bundle wrapper globals) self-map on
    # sight, unlike shadowable reserved/known-global words.
    s.bindings[id] = m.names[id]
    s.used.incl(id)
    m.mapping[id] = m.names[id]
    return
  let c = nextShort(m, s, ancUsed)
  s.bindings[id] = c
  s.used.incl(m.intern(c))
  m.mapping[id] = c

proc assignScope(m: Mangler, s: Scope, forceTaint: int = 0) =
  ## Top-down assignment: ancestors resolve first so descendants can dodge
  ## referenced shorts. Deterministic: pending order is AST order and no
  ## table is ever iterated for decisions.
  var t = forceTaint
  if not s.node.isNil:
    t = t or taintKind(m, s.node)
  when defined(mangleTime):
    let tA0 = epochTime()
  var ancUsed = initHashSet[int]()
  # Scopes that bind nothing assign nothing: skip the ancestor scan
  # entirely (roughly half of all block scopes).
  if s.pending.len + s.labelPending.len > 0:
    var a = s.parent
    while not a.isNil:
      # Dense pending lists, not the sparse binding tables: same content,
      # no empty-slot visits. The short resolves on reference hits only.
      for e in a.pending:
        if e.id in s.refNames:
          ancUsed.incl(m.intern(a.bindings[e.id]))
      for e in a.labelPending:
        if e.id in s.refNames:
          ancUsed.incl(m.intern(a.labels[e.id]))
      a = a.parent
  when defined(mangleTime):
    m.tAncUsed += epochTime() - tA0
  let evalTainted = (t and 1) != 0
  # Keeps first: a kept name self-maps to its own text, so it must occupy
  # `used` before normal bindings draw shorts, or a normal could be issued
  # the kept text (`const s` twice from different originals).
  for e in s.pending:
    if e.keep or s.keepAll or evalTainted or (e.id in s.pinnedByWith):
      assignOne(m, s, e.id, true, ancUsed, false)
  for e in s.labelPending:
    if e.keep or s.keepAll or evalTainted or (e.id in s.pinnedByWith):
      assignOne(m, s, e.id, true, ancUsed, true)
  for e in s.pending:
    if not (e.keep or s.keepAll or evalTainted or (e.id in s.pinnedByWith)):
      assignOne(m, s, e.id, false, ancUsed, false)
  for e in s.labelPending:
    if not (e.keep or s.keepAll or evalTainted or (e.id in s.pinnedByWith)):
      assignOne(m, s, e.id, false, ancUsed, true)
  # Keep-propagation runs as a pre-pass (see propagateKeeps): by the time
  # assignment runs, propagated entries already carry keep=true.
  for ch in s.children:
    assignScope(m, ch)

proc propagateKeeps(m: Mangler, root: Scope) =
  ## Pre-pass before assignment: a kept name (template interpolation, export
  ## link, with-observed binding) detaches if an ancestor renames the same
  ## binding, so convert the nearest normal ancestor entry to keep. Doing
  ## this before assignment keeps keeps-first ordering intact and can never
  ## collide with an issued short. Scopes owning a normal twin keep
  ## resolving locally and propagate nothing.
  var stack = @[root]
  while stack.len > 0:
    let s = stack.pop()
    for e in s.pending:
      if not e.keep:
        continue
      var ownsNormal = false
      for f in s.pending:
        if f.id == e.id and not f.keep:
          ownsNormal = true
          break
      if ownsNormal:
        continue
      var a = s.parent
      while not a.isNil:
        var nearest = -1
        var nearestKeep = false
        for i in 0 ..< a.pending.len:
          if a.pending[i].id == e.id:
            nearest = i
            nearestKeep = a.pending[i].keep
            break
        if nearest >= 0:
          if not nearestKeep:
            a.pending[nearest].keep = true
          break
        a = a.parent
    for e in s.labelPending:
      if not e.keep:
        continue
      var ownsNormal = false
      for f in s.labelPending:
        if f.id == e.id and not f.keep:
          ownsNormal = true
          break
      if ownsNormal:
        continue
      var a = s.parent
      while not a.isNil:
        var nearest = -1
        var nearestKeep = false
        for i in 0 ..< a.labelPending.len:
          if a.labelPending[i].id == e.id:
            nearest = i
            nearestKeep = a.labelPending[i].keep
            break
        if nearest >= 0:
          if not nearestKeep:
            a.labelPending[nearest].keep = true
          break
        a = a.parent
    for ch in s.children:
      stack.add(ch)

proc mangleScopes*(m: Mangler, nodes: openArray[Node],
                   stripExports: bool = false) =
  ## Scoped whole-program mangling: collect bindings and reference names,
  ## assign per-scope shorts top-down, rename identifiers in place.
  ## Codegen then passes renamed idents through `getMangled` untouched.
  m.scopes = initTable[pointer, Scope]()
  m.taintMemo = initTable[pointer, int]()
  m.withBodies = @[]
  m.stack = @[]
  m.origNames = initTable[pointer, string]()
  var ctx = MangleCtx(m: m, phase: mphCollect, curB: nil, curF: nil,
    stripExports: stripExports)
  let root = newScope(m, ctx, skProgram, nil, false)
  walkStmtList(ctx, nodes)
  popScope(m, ctx, root)
  when defined(mangleTime):
    let tA = epochTime()
  # With path pins: scopes above a with-body keep the names it observes.
  for wb in m.withBodies:
    var s = wb.parent
    while not s.isNil:
      for o in wb.refNames:
        s.pinnedByWith.incl(o)
      s = s.parent
  # Keep-propagation before any assignment (see propagateKeeps).
  propagateKeeps(m, root)
  # Program taint: a direct eval anywhere observes program bindings.
  var progTaint = 0
  for n in nodes:
    progTaint = progTaint or taintKind(m, n)
  when defined(mangleTime):
    let tPre = epochTime()
  assignScope(m, root, progTaint)
  when defined(mangleTime):
    let tB = epochTime()
  var ctx2 = MangleCtx(m: m, phase: mphRename, curB: root, curF: root,
    stripExports: stripExports)
  walkStmtList(ctx2, nodes)
  when defined(mangleTime):
    stderr.writeLine("mangle collect+walk done; prepasses=" & $(tPre - tA) &
      " assign=" & $(tB - tPre) & " rename=" & $(epochTime() - tB) &
      " ancUsed=" & $m.tAncUsed & " nextShortFree=" & $m.tNextShort)

proc mangleScopes*(m: Mangler, node: Node, stripExports: bool = false) =
  if node.isNil or node.kind in LeafNodes:
    return
  let arr = @[node]
  mangleScopes(m, arr, stripExports)
