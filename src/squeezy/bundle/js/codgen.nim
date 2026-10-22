# A dead simple JavaScript and CSS validator, bundler and minifier
#
# (c) 2025 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/squeezy

import std/[strutils, os]
import sweetsyntax/engine/ast
import ../common
import ../sourcemap
import ./exports
import ./mangler
when defined(sweetSyntaxDebug):
  import pkg/openparser/json

var debugDepth*: int

const
  IdentChars = {'a'..'z', 'A'..'Z', '0'..'9', '_', '$'}

type
  GenContext = object
    result: string
    genLine, genCol: int
    opts: JsGenOptions
    mangler: Mangler
    sourceMap: SourceMap
    depth: int

proc add(ctx: var GenContext, s: string) {.inline.} =
  if ctx.result.len > 0 and ctx.result[^1] in IdentChars and s.len > 0 and s[0] in IdentChars:
    ctx.result.add(' ')
  ctx.result.add(s)
  if ctx.sourceMap != nil:
    for c in s:
      if c == '\n':
        inc ctx.genLine
        ctx.genCol = 0
      else:
        inc ctx.genCol

proc add(ctx: var GenContext, c: char) {.inline.} =
  ctx.result.add(c)
  if ctx.sourceMap != nil:
    if c == '\n':
      inc ctx.genLine
      ctx.genCol = 0
    else:
      inc ctx.genCol

proc track(ctx: var GenContext, n: Node, addName: bool = false) {.inline.} =
  if ctx.sourceMap != nil and n != nil:
    var nameIdx = -1
    if addName and n.kind == nkIdent:
      # With whole-bundle mangling the AST carries final (short) names;
      # the map's `names` must still show the pre-rename originals.
      let name =
        if ctx.mangler != nil and ctx.mangler.trackOrig: ctx.mangler.origName(n)
        else: n.name
      nameIdx = ctx.sourceMap.addName(name)
    ctx.sourceMap.addMapping(ctx.genLine, ctx.genCol, n.ln, n.col, 0, nameIdx)

const
  PrecAssign = 0
  PrecCond = 1
  PrecNullish = 1
  PrecLogOr = 2
  PrecLogAnd = 3
  PrecBitOr = 4
  PrecBitXor = 5
  PrecBitAnd = 6
  PrecEquals = 7
  PrecCompare = 8
  PrecShift = 9
  PrecAdd = 10
  PrecMult = 11
  PrecExp = 12
  PrecPrefix = 13
  PrecMember = 14
  PrecCall = 15
  PrecPostfix = 16

  AssignOps* = ["=", "+=", "-=", "*=", "/=", "%=", "**=",
                "&=", "|=", "^=", "<<=", ">>=", ">>>=",
                "&&=", "||=", "??="]

  RightAssocOps = ["=", "+=", "-=", "*=", "/=", "%=", "**=",
                   "&=", "|=", "^=", "<<=", ">>=", ">>>=",
                   "&&=", "||=", "??=", "**"]

proc getPrec(op: string): int =
  case op
  of "??": PrecNullish
  of "||": PrecLogOr
  of "&&": PrecLogAnd
  of "|": PrecBitOr
  of "^": PrecBitXor
  of "&": PrecBitAnd
  of "==", "!=", "===", "!==": PrecEquals
  of "<", ">", "<=", ">=", "instanceof", "in": PrecCompare
  of "<<", ">>", ">>>": PrecShift
  of "+", "-": PrecAdd
  of "*", "/", "%": PrecMult
  of "**": PrecExp
  of ".": PrecMember
  of "[": PrecMember - 1
  of "(": PrecCall - 1
  of "=", "+=", "-=", "*=", "/=", "%=", "**=", "&=", "|=", "^=", "<<=", ">>=", ">>>=", "&&=", "||=", "??=": PrecAssign
  else: -1

proc isRightAssoc(op: string): bool {.inline.} =
  ## Right-associative ops are `**` plus every assignment op (all of which
  ## end in `=`). The trailing-`=` prefilter keeps non-assign operators to a
  ## couple of character compares instead of a 17-element scan.
  if op == "**": return true
  if op.len == 0 or op[^1] != '=': return false
  getPrec(op) == PrecAssign

proc isBlockStmtKw*(kw: string): bool {.inline.} =
  ## Block-like statement heads that self-terminate in `genBlockStmts` and
  ## may go unterminated before `else` in `genThenElse`.
  case kw.len
  of 2: kw == "if"
  of 3: kw == "for" or kw == "try"
  of 5: kw == "while" or kw == "class" or kw == "label"
  of 6: kw == "switch"
  of 8: kw == "function" or kw == "do-while"
  else: false

proc isMethodFlag*(name: string): bool {.inline.} =
  ## Method member flags other than `*` (handled separately at each site).
  case name.len
  of 3: name == "get" or name == "set"
  of 5: name == "async"
  of 6: name == "static"
  else: false

proc isWordPrefixOp*(opName: string): bool {.inline.} =
  ## Word operators needing no operand spacing logic beyond the default.
  case opName.len
  of 3: opName == "new"
  of 4: opName == "void"
  of 6: opName == "typeof" or opName == "delete"
  else: false

proc canonicalFloatStr*(s: string): string =
  ## Minified canonical form of a float literal's text: `0.5` -> `.5`,
  ## `10.0` -> `10`. Shared by emission and the tight-spacing predicate so
  ## both agree on the first output character.
  result = s
  if result.len > 1 and result[0] == '0' and result[1] == '.':
    result = result[1 .. ^1]
  elif result.len > 2 and result[0] == '-' and result[1] == '0' and
       result[2] == '.':
    result = "-" & result[2 .. ^1]
  if result == ".0":
    result = "0"
  elif result == "-.0":
    result = "-0"
  elif result.len > 2 and result[^2] == '.' and result[^1] == '0' and
       'e' notin result and 'E' notin result:
    result = result[0 .. ^3]

proc returnOperandTight(n: Node): bool =
  ## True when a `return`/`throw`/`case` operand needs no separating space:
  ## its first emitted char cannot join an identifier (`return(`, `return[`,
  ## `return"`, `return!0`, `return/.../`, `return{`). Anything starting with
  ## an identifier char, digit or `.`-digit needs the space (`return0.5`
  ## would lex as one identifier). Conservative: unknown shapes keep it.
  if n.isNil:
    return false
  case n.kind
  of nkCall:
    if n.children.len > 0 and not n.children[0].isNil and
       n.children[0].kind == nkIdent and n.children[0].name == "ternary" and
       n.children.len > 1:
      return returnOperandTight(n.children[1]) # condition leads
    if n.children.len > 0 and not n.children[0].isNil and
       n.children[0].kind == nkIdent and n.children[0].name == "spread":
      return false
    return true # parenthesized call
  of nkArrayLit:
    return true
  of nkLitString:
    return n.valStr.len > 0 and n.valStr[0] in {'"', '\'', '`'}
  of nkLitBool, nkRegex:
    return true
  of nkLitInt:
    let t = $n.valInt
    return t.len > 0 and t[0] == '-'
  of nkLitFloat:
    let s = canonicalFloatStr($n.valFloat)
    return s.len > 0 and (s[0] == '.' or s[0] == '-')
  of nkBlock:
    return true # object literal body
  of nkPrefix:
    if n.children.len > 0 and not n.children[0].isNil and
       n.children[0].kind == nkIdent:
      let op = n.children[0].name
      return op == "!" or op == "~" or op == "+" or op == "-"
    return false
  of nkInfix:
    # Recurse into the leftmost operand (its first char leads).
    if n.children.len >= 2:
      return returnOperandTight(n.children[1])
    return false
  else:
    return false

proc needsParens(childPrec, parentPrec: int, parentOp: string, isLhs: bool): bool =
  if childPrec < parentPrec: return true
  if childPrec > parentPrec: return false
  if childPrec == parentPrec:
    if isRightAssoc(parentOp):
      return not isLhs
    else:
      return isLhs
  return false

proc isObjLiteral(n: Node): bool =
  ## Object literals and destructuring patterns share the nkBlock shape
  ## (pattern defaults ride as 3-child nkColonExpr members carrying an
  ## `=` marker). Leading comments and empties are trivia, not members.
  ## Statement blocks never hold bare nkColonExpr children (labels parse
  ## as nkStatement), so the shapes stay unambiguous.
  if n.kind != nkBlock or n.children.len == 0:
    return false
  var first: Node = nil
  for child in n.children:
    if child.isNil or child.kind == nkEmpty: continue
    if child.kind in {nkInlineComment, nkDocComment}: continue
    first = child
    break
  if first.isNil:
    return false
  result = first.kind == nkColonExpr or
    (first.kind == nkCall and first.children.len > 0 and
     not first.children[0].isNil and
     first.children[0].kind == nkIdent and
     first.children[0].name == "spread")

proc genNode(ctx: var GenContext, n: Node, parentPrec: int = -1, parentOp: string = "", isLhs: bool = true)
proc genStmt(ctx: var GenContext, n: Node)
proc genBlockStmts(ctx: var GenContext, children: seq[Node])
proc stripSemiBeforeBrace(ctx: var GenContext, lastChild: Node)

proc unwrapComments(n: Node): Node =
  ## Peels nested nkCommentGroup wrappers off an expression.
  result = n
  while not result.isNil and result.kind == nkCommentGroup and
        result.children.len > 0:
    result = result.children[0]

proc isCommaExpr(n: Node): bool

proc leadingUnarySign(n: Node): char =
  ## Returns the sign character (`+`/`-`) of the unary operator at the far
  ## left of an expression, if any — used to avoid emitting `a++b`.
  var cur = unwrapComments(n)
  while not cur.isNil:
    case cur.kind
    of nkPrefix:
      let opName = if cur.children.len > 0 and not cur.children[0].isNil and
        cur.children[0].kind == nkIdent: cur.children[0].name else: ""
      if opName == "+" or opName == "-":
        return opName[0]
      if opName == "++":
        return '+'
      if opName == "--":
        return '-'
      if cur.children.len > 1:
        cur = unwrapComments(cur.children[1])
      else:
        return '\0'
    of nkInfix:
      if cur.children.len >= 2:
        cur = unwrapComments(cur.children[1])
      else:
        return '\0'
    of nkCall, nkDotExpr, nkBracketExpr, nkPostfix:
      if cur.children.len > 0:
        let first = unwrapComments(cur.children[0])
        if first.kind == nkIdent and first.name == "ternary" and
           cur.children.len > 1:
          # Ternary call: children are [ternary, cond, then, else]
          cur = unwrapComments(cur.children[1])
        else:
          cur = first
      else:
        return '\0'
    of nkCommentGroup:
      if cur.children.len > 0:
        cur = unwrapComments(cur.children[0])
      else:
        return '\0'
    else:
      return '\0'
  '\0'

proc needsTightParens(n: Node): bool =
  ## True for nodes that must be parenthesized when used as a member/call/
  ## subscript target (`(a || b).c`, `(a, b)(x)`, `(++a).b`).
  let inner = unwrapComments(n)
  if inner.isNil: return false
  if inner.kind == nkInfix: return true
  if isCommaExpr(inner): return true
  if inner.kind == nkCall and inner.children.len > 0 and
     inner.children[0].kind == nkIdent and inner.children[0].name == "ternary":
    return true
  # ++a and --a must be wrapped before member access: (++a).b not ++a.b
  if inner.kind == nkPrefix and inner.children.len > 0 and
     not inner.children[0].isNil and inner.children[0].kind == nkIdent:
    let preOp = inner.children[0].name
    if preOp.len == 2 and preOp[1] == preOp[0] and preOp[0] in {'+', '-'}:
      return true
  false

proc genTightOperand(ctx: var GenContext, n: Node, minPrec: int) =
  ## Emits an operand that binds tighter than most operators.
  if needsTightParens(n):
    ctx.add('(')
    genNode(ctx, n, 0)
    ctx.add(')')
  else:
    genNode(ctx, n, minPrec)

proc isCommaExpr(n: Node): bool =
  ## Parser shape for a parenthesized comma expression `(a, b)`.
  let n = unwrapComments(n)
  not n.isNil and n.kind == nkStatement and n.children.len > 1 and
    not n.children[0].isNil and n.children[0].kind == nkIdent and
    n.children[0].name == "comma"

proc needsCondParens(n: Node): bool =
  ## Ternary conditions exclude assignment, comma, arrow and nested
  ## ternaries (`(m = re.exec(s)) ? ...` must keep its parens: without them
  ## the assignment swallows the branches and re-parses as `m = (...?...:...)`,
  ## reading the variable before it is assigned). Mirrors the ShortCircuit
  ## grammar; everything else re-parses identically bare.
  let inner = unwrapComments(n)
  if inner.isNil: return false
  if isCommaExpr(inner): return true
  if inner.kind == nkFunction: return true
  if inner.kind == nkCall and inner.children.len > 0 and
     not inner.children[0].isNil and inner.children[0].kind == nkIdent and
     inner.children[0].name == "ternary":
    return true # right-nested `(a?b:c)?d:e` would flatten without parens
  if inner.kind == nkInfix and inner.children.len >= 3 and
     not inner.children[0].isNil and inner.children[0].kind == nkIdent:
    return getPrec(inner.children[0].name) == PrecAssign
  if inner.kind == nkPrefix and inner.children.len > 0 and
     not inner.children[0].isNil and inner.children[0].kind == nkIdent and
     inner.children[0].name == "yield":
    return true
  false

proc needsValueParens(n: Node): bool =
  ## Comma expressions as operands that a bare comma would split
  ## (`return (a, b)`, `throw (a, b)`, `=> (a, b)`, `x = (a, b)` all re-parse
  ## with the comma escaping its group). Call/array arguments and var
  ## initializers already wrap these; this covers the remaining value slots.
  isCommaExpr(n)

proc genExprList(ctx: var GenContext, nodes: seq[Node], startIdx: int = 0) =
  for i in startIdx ..< nodes.len:
    let n = nodes[i]
    if n.isNil: continue
    if i > startIdx:
      ctx.add(',')
    # Parenthesized comma expressions as arguments must keep their parens
    if isCommaExpr(n):
      ctx.add('(')
      genNode(ctx, n, 0)
      ctx.add(')')
    else:
      genNode(ctx, n, PrecAssign, "comma")

proc genThenElse(ctx: var GenContext, body: Node, beforeElse: bool = false) =
  ## Emits an if/loop body that is not a brace block. A terminating `;` is
  ## required: without it the next statement can bind to the body
  ## (e.g. `if(x)return l do{...}` instead of `if(x)return l;do{...}`).
  ## Missing bodies become empty statements (`else ;`).
  if body.isNil or body.kind == nkEmpty:
    ctx.add(';')
    return
  if body.kind == nkBlock:
    genNode(ctx, body, -1)
  else:
    genStmt(ctx, body)
    # Always terminate: bodies like `a={}` end in `}` yet still need a `;`
    let isControl = body.kind == nkStatement and body.children.len > 0 and
      not body.children[0].isNil and body.children[0].kind == nkIdent and
      isBlockStmtKw(body.children[0].name)
    if ctx.result.len > 0 and ctx.result[^1] != ';':
      if beforeElse:
        # Only control-flow bodies may go unterminated before `else`
        if isControl:
          discard
        else:
          ctx.add(';')
      else:
        ctx.add(';')

proc isDeclStmt*(n: Node): bool =
  ## True for var/let/const declaration statements.
  n.kind == nkStatement and n.children.len > 0 and not n.children[0].isNil and
    n.children[0].kind == nkIdent and isDeclKw(n.children[0].name)

proc genMemberKey(ctx: var GenContext, key: Node) =
  ## Emits an object/class member key: identifier, quoted string or
  ## computed `[expr]` (marked by the parser as a "computed" statement).
  case key.kind
  of nkIdent:
    ctx.add(key.name)
  of nkLitString:
    ctx.add(key.valStr)  # raw token, quotes included
  of nkStatement:
    if key.children.len > 1 and not key.children[0].isNil and
       key.children[0].kind == nkIdent and key.children[0].name == "computed":
      ctx.add('[')
      genNode(ctx, key.children[1], PrecAssign)
      ctx.add(']')
    else:
      genStmt(ctx, key)
  else:
    genNode(ctx, key, PrecAssign)

proc genMethod(ctx: var GenContext, fn: Node, key: Node) =
  ## Emits a method-shorthand member: `[flags] key[*](params){body}`.
  ## Layout: [flagIdents..., (empty marker)?, params(nkIdentDefs), body(nkBlock)].
  let ch = fn.children
  var i = 0
  var preFlags: seq[string]
  var star = false
  while i < ch.len and not ch[i].isNil and ch[i].kind == nkIdent:
    let name = ch[i].name
    if name == "*":
      star = true
      inc i
    elif isMethodFlag(name):
      preFlags.add(name)
      inc i
    else:
      break
  if i < ch.len and not ch[i].isNil and ch[i].kind == nkEmpty:
    inc i  # arrow-shape marker from object literal methods
  for f in preFlags:
    ctx.add(f)
    ctx.add(' ')
  if star:
    ctx.add('*')
  genMemberKey(ctx, key)
  ctx.add('(')
  if i < ch.len and not ch[i].isNil and ch[i].kind == nkIdentDefs:
    genExprList(ctx, ch[i].children, 0)
    inc i
  ctx.add(')')
  let body = ch[^1]
  if not body.isNil and body.kind == nkBlock:
    ctx.add('{')
    genBlockStmts(ctx, body.children)
    ctx.add('}')
  elif not body.isNil and body.kind != nkEmpty:
    ctx.add('{')
    genStmt(ctx, body)
    ctx.add('}')

proc isMethodShorthand(fn: Node): bool =
  ## Method-shaped function node used for object/class members:
  ## [flagIdents..., params(nkIdentDefs), body(nkBlock)].
  ## Arrow functions (`[empty, params, body]`) are deliberately excluded:
  ## the empty marker is reserved for arrows so the shapes never collide.
  if fn.isNil or fn.kind != nkFunction or fn.children.len < 2: return false
  let last = fn.children[^1]
  let params = fn.children[^2]
  if last.isNil or last.kind != nkBlock: return false
  if params.isNil or params.kind != nkIdentDefs: return false
  for j in 0 ..< fn.children.len - 2:
    let c = fn.children[j]
    if c.isNil: continue
    if c.kind != nkIdent: return false
    if c.name != "*" and not isMethodFlag(c.name):
      return false
  true

proc isAsyncArrow(fn: Node): bool =
  ## `[async, params, body]` shape. In object-literal value position this
  ## is always an async arrow: async object methods do not parse today,
  ## so unlike plain arrows no method shape collides with it there.
  ## (Class bodies are different — real async methods live there —
  ## so this guard applies to the object site only.)
  if fn.isNil or fn.kind != nkFunction or fn.children.len != 3:
    return false
  let first = fn.children[0]
  let params = fn.children[1]
  let body = fn.children[2]
  result = not first.isNil and first.kind == nkIdent and
    first.name == "async" and not params.isNil and
    params.kind == nkIdentDefs and not body.isNil and
    body.kind == nkBlock

proc genObjLiteral(ctx: var GenContext, n: Node) =
  ctx.add('{')
  var firstItem = true
  for child in n.children:
    if child.isNil or child.kind == nkEmpty: continue
    if child.kind in {nkInlineComment, nkDocComment}:
      # Interleaved comments must not produce stray commas
      if ctx.opts.preserveComments:
        if not firstItem: ctx.add(',')
        firstItem = false
        if child.kind == nkInlineComment: ctx.add("/*" & child.children[0].valStr & "*/")
        else: ctx.add("/*" & child.children[0].valStr & "*/")
      continue
    if not firstItem: ctx.add(',')
    firstItem = false
    case child.kind
    of nkColonExpr:
      if child.children.len < 2: continue
      let key = child.children[0]
      let val = child.children[1]
      if key.isNil or val.isNil: continue
      if child.children.len >= 3 and not child.children[2].isNil and
         child.children[2].kind == nkIdent and child.children[2].name == "=":
        # Destructuring default `{ key = default }`: kept verbatim,
        # never degraded into `key: default`. A comma default keeps its
        # parens (`{a = (b, c)}` bare would read `c` as another member).
        genMemberKey(ctx, key)
        ctx.add('=')
        if needsValueParens(val):
          ctx.add('(')
          genNode(ctx, val, 0)
          ctx.add(')')
        else:
          genNode(ctx, val, PrecAssign)
      elif val.kind == nkFunction and isMethodShorthand(val) and
          not isAsyncArrow(val):
        genMethod(ctx, val, key)
      elif val.kind == nkEmpty:
        # Bare shorthand `{a}` — parser expands to `key:key`; emit compact form
        genMemberKey(ctx, key)
      elif key.kind == nkIdent and val.kind == nkIdent and key.name == val.name:
        # ES2015 shorthand: `{a: a}` and `{a}` mean exactly the same thing,
        # so equal texts always collapse. (Names are final here: the scoped
        # pass renames in place before codegen, leaving no mapping to apply.)
        ctx.add(key.name)
      else:
        genMemberKey(ctx, key)
        ctx.add(':')
        genNode(ctx, val, PrecAssign)
    of nkCall:
      if child.children.len > 0 and child.children[0].kind == nkIdent and
         child.children[0].name == "spread":
        ctx.add("...")
        if child.children.len > 1:
          if needsValueParens(child.children[1]):
            ctx.add('(')
            genNode(ctx, child.children[1], 0)
            ctx.add(')')
          else:
            genNode(ctx, child.children[1], PrecAssign)
    of nkFunction:
      genNode(ctx, child)
    else:
      genNode(ctx, child, PrecAssign)
  ctx.add('}')

proc genFn(ctx: var GenContext, n: Node) =
  ctx.track(n)
  let children = n.children
  let isAsync = children.len >= 1 and not children[0].isNil and
    children[0].kind == nkIdent and children[0].name == "async"
  let isArrow = children.len >= 1 and not children[0].isNil and
    (children[0].kind == nkEmpty or isAsync)
  if isAsync:
    ctx.add("async ")
  if not isArrow:
    if children.len >= 1 and not children[0].isNil and children[0].kind == nkIdent:
      ctx.add("function")
    if children.len >= 2 and not children[1].isNil and children[1].kind == nkIdent and children[1].name == "*":
      ctx.add('*')
    if children.len >= 3 and not children[2].isNil and children[2].kind == nkIdent:
      ctx.add(' ')
      ctx.add(children[2].name)
    if children.len >= 4 and not children[3].isNil and children[3].kind == nkIdentDefs and
       children[3].children.len > 0:
      ctx.add('<')
      genExprList(ctx, children[3].children, 0)
      ctx.add('>')
    ctx.add('(')
    if children.len >= 5 and not children[4].isNil and children[4].kind == nkIdentDefs:
      genExprList(ctx, children[4].children, 0)
    ctx.add(')')
    let bodyIdx = if children.len >= 7: 6 else: children.len - 1
    if bodyIdx < children.len:
      let body = children[bodyIdx]
      if not body.isNil and body.kind == nkBlock:
        ctx.add('{')
        genBlockStmts(ctx, body.children)
        ctx.add('}')
      elif not body.isNil and body.kind == nkEmpty:
        discard
      elif not body.isNil:
        ctx.add('{')
        genStmt(ctx, body)
        ctx.add('}')
  else:
    let paramsIdx = 1
    let bodyIdx = 2
    if paramsIdx < children.len and not children[paramsIdx].isNil and
       children[paramsIdx].kind == nkIdentDefs:
      let params = children[paramsIdx]
      # A single IDENT param may drop its parentheses; patterns
      # (`[a, b] =>`, `{a} =>`) must keep them.
      let singleIdent = params.children.len == 1 and not params.children[0].isNil and
        params.children[0].kind == nkIdent
      if singleIdent:
        genNode(ctx, params.children[0], PrecAssign)
      else:
        ctx.add('(')
        genExprList(ctx, params.children, 0)
        ctx.add(')')
    ctx.add("=>")
    if bodyIdx < children.len:
      let body = children[bodyIdx]
      if not body.isNil and body.kind == nkBlock and isObjLiteral(body):
        # Parenthesized object body `=> ({...})`: bare braces would
        # re-parse as a statement block, so keep the grouping parens.
        ctx.add('(')
        genObjLiteral(ctx, body)
        ctx.add(')')
      elif not body.isNil and body.kind == nkBlock:
        # Block bodies keep their braces — unwrapping a single statement
        # would produce invalid arrows (`(i,j) => for(...) {...}`).
        ctx.add('{')
        genBlockStmts(ctx, body.children)
        ctx.add('}')
      elif not body.isNil and body.kind == nkEmpty:
        discard
      elif not body.isNil:
        # A concise comma body `() => (a, b)` must keep its parens: bare it
        # splits into two parameters/body pieces.
        if needsValueParens(body):
          ctx.add('(')
          genNode(ctx, body, 0)
          ctx.add(')')
        else:
          genNode(ctx, body, PrecAssign)

proc genNode(ctx: var GenContext, n: Node, parentPrec: int = -1, parentOp: string = "", isLhs: bool = true) =
  if n.isNil:
    return
  when defined(sweetSyntaxDebug):
    inc ctx.depth
    if ctx.depth > 500 and ctx.depth mod 100 == 0:
      let start = ctx.result.len - min(ctx.result.len, 80)
      let tail = ctx.result[start..^1]
      stderr.writeLine("depth=" & $ctx.depth & " kind=" & $n.kind & " code=" & tail)
  case n.kind
  of nkEmpty: discard
  of nkNil:
    ctx.track(n)
    ctx.add("null")
  of nkLitBool:
    ctx.track(n)
    # `!0`/`!1` are shorter than `true`/`false` and valid wherever a value
    # is (keys lex as idents, never bools, so no key position can hit this).
    if ctx.opts.minify:
      ctx.add(if n.valBool: "!0" else: "!1")
    else:
      ctx.add(if n.valBool: "true" else: "false")
  of nkLitInt:
    ctx.track(n)
    ctx.add($n.valInt)
  of nkLitFloat:
    ctx.track(n)
    if ctx.opts.minify:
      ctx.add(canonicalFloatStr($n.valFloat))
    else:
      ctx.add($n.valFloat)
  of nkLitString:
    ctx.track(n)
    let raw = n.valStr
    # Template literals are lexed as strings with backtick delimiters —
    # pass them through byte-exact (no re-quoting, no escape rewriting).
    if raw.len >= 2 and raw[0] == '`' and raw[^1] == '`':
      ctx.add(raw)
    else:
      # String tokens carry raw source text (escapes included). Pick the
      # quote style needing fewer additional escapes. Bounds avoid the
      # old `raw[1..^2]` slice allocation; both scans run on `raw` directly.
      let (lo, hi) = if raw.len >= 2 and (raw[0] == '"' or raw[0] == '\''):
        (1, raw.len - 1) else: (0, raw.len)
      var dq = 0
      var sq = 0
      var k = lo
      while k < hi:
        if raw[k] == '\\' and k + 1 < hi:
          k += 2
          continue
        if raw[k] == '"': inc dq
        elif raw[k] == '\'': inc sq
        inc k
      let q: char = if sq < dq: '\'' else: '"'
      if lo == 1 and raw[0] == q and (if q == '\'': sq else: dq) == 0:
        # Already optimal: the rebuild loop below would copy every byte
        # unchanged (escape pairs pass through, no unescaped q to fix),
        # so emit the token as-is in a single add.
        ctx.add(raw)
      else:
        ctx.add(q)
        k = lo
        while k < hi:
          let c = raw[k]
          if c == '\\' and k + 1 < hi:
            ctx.add(c)
            ctx.add(raw[k + 1])
            k += 2
            continue
          if c == q:
            ctx.add('\\')
            ctx.add(q)
          else:
            ctx.add(c)
          inc k
        ctx.add(q)
  of nkLitBigInt:
    ctx.track(n)
    ctx.add(n.valBigInt & "n")
  of nkIdent:
    ctx.track(n, addName=true)
    # Names are final: the scoped pass renames in place before codegen, so
    # no flat-table lookup applies here (it would re-map generated shorts
    # that collide with other originals).
    ctx.add(n.name)
  of nkVarTy: ctx.add(n.name)
  of nkRegex:
    if n.children.len > 0 and n.children[0].kind == nkLitString:
      ctx.add(n.children[0].valStr)
  of nkInlineComment:
    if ctx.opts.preserveComments:
      # Wrapped formats never emit statement newlines, so a `//` comment
      # would swallow the code that follows it on the same line. Always
      # emit block form (sanitizing any `*/` inside the text).
      ctx.add("/*" & n.children[0].valStr.replace("*/", "* /") & "*/")
  of nkDocComment:
    if ctx.opts.preserveComments:
      ctx.add("/*" & n.children[0].valStr & "*/")
  of nkPrefix:
    let opName = if n.children.len > 0 and n.children[0].kind == nkIdent: n.children[0].name else: ""
    let operand = if n.children.len > 1: n.children[1] else: nil
    if opName == "spread":
      ctx.add("...")
      if not operand.isNil:
        if needsValueParens(operand):
          ctx.add('(')
          genNode(ctx, operand, 0)
          ctx.add(')')
        else:
          genNode(ctx, operand, PrecAssign)
    elif opName == "await":
      ctx.add("await ")
      if not operand.isNil:
        genNode(ctx, operand, PrecPrefix)
    else:
      let addSpace = isWordPrefixOp(opName)
      ctx.add(opName)
      if addSpace and not operand.isNil:
        if operand.kind in {nkLitInt, nkLitFloat, nkLitString, nkLitBool, nkNil}:
          ctx.add(' ')
        elif operand.kind == nkPrefix:
          ctx.add(' ')
      # Avoid mis-lexing: `- -t` must not become `--t`, `+ +t` not `++t`
      if not addSpace and not operand.isNil and opName.len in 1 .. 2 and
         opName[0] in {'+', '-'} and (opName.len == 1 or opName[1] == opName[0]):
        let opSign = if opName == "+" or opName == "++": '+' else: '-'
        let operandSign = leadingUnarySign(operand)
        if operandSign == opSign:
          ctx.add(' ')
      if not operand.isNil:
        if opName == "new":
          # `new X(args)` — only wrap when the callee itself has lower
          # precedence (e.g. `new (a || b)()`), never around a plain call.
          let callee = if operand.kind == nkCall and operand.children.len > 0:
            operand.children[0] else: operand
          if callee.kind == nkInfix or callee.kind == nkCall:
            ctx.add('(')
            genNode(ctx, operand, 0)
            ctx.add(')')
          else:
            genNode(ctx, operand, PrecPrefix)
        elif operand.kind == nkInfix or isCommaExpr(operand):
          ctx.add('(')
          genNode(ctx, operand, 0)
          ctx.add(')')
        else:
          genNode(ctx, operand, PrecPrefix)
  of nkPostfix:
    if n.children.len >= 2:
      genTightOperand(ctx, n.children[0], PrecPostfix)
      if n.children[1].kind == nkIdent:
        ctx.add(n.children[1].name)
  of nkInfix:
    if n.children.len >= 3 and n.children[0].kind == nkIdent:
      let op = n.children[0].name
      let lhs = n.children[1]
      let rhs = n.children[2]
      let prec = getPrec(op)
      if prec >= 0:
        # Every op mapping to PrecAssign is an assignment op by construction
        # of getPrec — no separate `op in AssignOps` scan needed.
        if prec == PrecAssign:
          # Brace-pattern assignment targets at STATEMENT position
          # (`({a} = x);`) require parens; declarator patterns
          # (`const [a,b] = x`) stay bare
          let lhsTarget = unwrapComments(lhs)
          if parentPrec < 0 and lhsTarget.kind == nkBlock:
            ctx.add('(')
            genNode(ctx, lhs, prec, op, false)
            ctx.add(op)
            genNode(ctx, rhs, prec, op, true)
            ctx.add(')')
          else:
            genNode(ctx, lhs, prec, op, false)
            ctx.add(op)
            if isCommaExpr(rhs):
              # `x = (a, b)` must keep its parens: bare it re-parses as
              # `(x = a), b`, assigning the wrong value.
              ctx.add('(')
              genNode(ctx, rhs, 0)
              ctx.add(')')
            else:
              genNode(ctx, rhs, prec, op, true)
        else:
          # Unwrap each side once: the old code re-ran unwrapComments up to
          # three times per side across these checks.
          let ulhs = unwrapComments(lhs)
          let urhs = unwrapComments(rhs)
          let wrapLhs = isCommaExpr(lhs) or
            (ulhs.kind == nkCall and ulhs.children.len > 0 and
             ulhs.children[0].kind == nkIdent and
             ulhs.children[0].name == "ternary") or
            (lhs.kind == nkInfix and lhs.children.len >= 3 and
             lhs.children[0].kind == nkIdent and
             needsParens(getPrec(lhs.children[0].name), prec, op, false))
          let wrapRhs = isCommaExpr(rhs) or
            (urhs.kind == nkCall and urhs.children.len > 0 and
             urhs.children[0].kind == nkIdent and
             urhs.children[0].name == "ternary") or
            (rhs.kind == nkInfix and rhs.children.len >= 3 and
             rhs.children[0].kind == nkIdent and
             needsParens(getPrec(rhs.children[0].name), prec, op, true))
          if wrapLhs:
            ctx.add('(')
            genNode(ctx, lhs, 0)
            ctx.add(')')
          else:
            genNode(ctx, lhs, prec, op, false)
          if op == "**":
            ctx.add(op)
          else:
            ctx.add(op)
          if wrapRhs:
            ctx.add('(')
            genNode(ctx, rhs, 0)
            ctx.add(')')
          else:
            # Avoid mis-lexing: `a + +b` must not emit as `a++b`
            if (op == "+" or op == "-") and leadingUnarySign(rhs) == op[0]:
              ctx.add(' ')
            genNode(ctx, rhs, prec, op, true)
      else:
        genNode(ctx, lhs, PrecAssign)
        if op[0] in {'a'..'z', 'A'..'Z'}:
          ctx.add(' ')
          ctx.add(op)
          ctx.add(' ')
        else:
          ctx.add(op)
        genNode(ctx, rhs, PrecAssign)
  of nkDotExpr:
    ctx.track(n)
    if n.children.len >= 2:
      genTightOperand(ctx, n.children[0], PrecMember)
      ctx.add('.')
      if n.children[1].kind == nkIdent:
        ctx.add(n.children[1].name)
      else:
        genNode(ctx, n.children[1], PrecMember)
  of nkArrayLit:
    ctx.add('[')
    genExprList(ctx, n.children, 0)
    ctx.add(']')
  of nkBracketExpr:
    if n.children.len >= 2:
      let first = n.children[0]
      if first.kind in {nkIdent, nkDotExpr, nkCall, nkTagCall, nkBracketExpr,
                          nkFunction, nkInfix}:
        genTightOperand(ctx, first, PrecMember - 1)
        ctx.add('[')
        genExprList(ctx, n.children, 1)
        ctx.add(']')
      else:
        ctx.add('[')
        genExprList(ctx, n.children, 0)
        ctx.add(']')
    elif n.children.len == 1:
      ctx.add('[')
      genNode(ctx, n.children[0], 0)
      ctx.add(']')
    else:
      ctx.add("[]")
  of nkColonExpr:
    if n.children.len >= 2:
      genNode(ctx, n.children[0], PrecAssign)
      if n.children.len >= 3 and not n.children[2].isNil and
         n.children[2].kind == nkIdent and n.children[2].name == "=":
        ctx.add('=')
      else:
        ctx.add(':')
      genNode(ctx, n.children[1], PrecAssign)
  of nkTagCall:
    # Tagged template: the callee and template stay adjacent with no call
    # parens. Wrapping would demote the tag protocol (strings, values...)
    # to a plain cooked-string call. Tags bind tightest, so bare emission
    # re-parses identically in every legal position.
    ctx.track(n)
    if n.children.len >= 1:
      genTightOperand(ctx, n.children[0], PrecCall)
    if n.children.len >= 2:
      genNode(ctx, n.children[1], PrecAssign)
  of nkCall:
    ctx.track(n)
    if n.children.len > 0 and n.children[0].kind == nkIdent:
      if n.children[0].name == "ternary":
        if n.children.len >= 4:
          if needsCondParens(n.children[1]):
            ctx.add('(')
            genNode(ctx, n.children[1], 0)
            ctx.add(')')
          else:
            genNode(ctx, n.children[1], PrecCond)
          ctx.add('?')
          # Comma expressions as branches need their grouping parens back
          if isCommaExpr(n.children[2]):
            ctx.add('(')
            genNode(ctx, n.children[2], 0)
            ctx.add(')')
          else:
            genNode(ctx, n.children[2], PrecCond)
          ctx.add(':')
          if isCommaExpr(n.children[3]):
            ctx.add('(')
            genNode(ctx, n.children[3], 0)
            ctx.add(')')
          else:
            genNode(ctx, n.children[3], PrecCond - 1)
        return
      elif n.children[0].name == "spread":
        ctx.add("...")
        if n.children.len > 1:
          if needsValueParens(n.children[1]):
            ctx.add('(')
            genNode(ctx, n.children[1], 0)
            ctx.add(')')
          else:
            genNode(ctx, n.children[1], PrecAssign)
        return
    if n.children.len > 0:
      genTightOperand(ctx, n.children[0], PrecCall)
    ctx.add('(')
    if n.children.len > 1:
      genExprList(ctx, n.children, 1)
    ctx.add(')')
  of nkReturn:
    ctx.track(n)
    ctx.add("return")
    if n.children.len > 0:
      if ctx.opts.minify and returnOperandTight(n.children[0]):
        genNode(ctx, n.children[0], PrecAssign)
      else:
        ctx.add(' ')
        if needsValueParens(n.children[0]):
          ctx.add('(')
          genNode(ctx, n.children[0], 0)
          ctx.add(')')
        else:
          genNode(ctx, n.children[0], PrecAssign)
  of nkImport:
    if ctx.opts.stripExports:
      # Wrapped formats: imports are inlined as sibling modules — drop the statement
      return
    if n.children.len == 0:
      ctx.add("import")
    elif n.children.len == 2 and n.children[0].kind == nkEmpty and
         n.children[1].kind == nkLitString:
      ctx.add("import ")
      genNode(ctx, n.children[1], PrecAssign)
    elif n.children.len >= 2 and n.children[0].kind == nkEmpty and
         n.children[1].kind == nkIdentDefs:
      ctx.add("import {")
      genExprList(ctx, n.children[1].children, 0)
      ctx.add("}")
      if n.children.len >= 3 and n.children[2].kind == nkLitString:
        ctx.add(" from ")
        genNode(ctx, n.children[2], PrecAssign)
    elif n.children.len >= 2 and n.children[0].kind == nkEmpty and
         (n.children[1].kind == nkPrefix or
          (n.children[1].kind == nkInfix and n.children[1].children.len >= 3 and
           n.children[1].children[0].kind == nkIdent and
           n.children[1].children[0].name == "as")):
      ctx.add("import ")
      genNode(ctx, n.children[1], PrecAssign)
      if n.children.len >= 3 and n.children[2].kind == nkLitString:
        ctx.add(" from ")
        genNode(ctx, n.children[2], PrecAssign)
    elif n.children.len >= 2 and n.children[0].kind == nkIdent and
         n.children[1].kind == nkLitString:
      ctx.add("import ")
      genNode(ctx, n.children[0], PrecAssign)
      ctx.add(" from ")
      genNode(ctx, n.children[1], PrecAssign)
    elif n.children.len >= 2 and n.children[0].kind == nkIdent:
      ctx.add("import ")
      genNode(ctx, n.children[0], PrecAssign)
      if n.children.len >= 2 and n.children[1].kind == nkIdentDefs:
        ctx.add(", {")
        genExprList(ctx, n.children[1].children, 0)
        ctx.add("}")
        if n.children.len >= 3 and n.children[2].kind == nkLitString:
          ctx.add(" from ")
          genNode(ctx, n.children[2], PrecAssign)
      elif n.children.len >= 2 and
           (n.children[1].kind == nkPrefix or
            (n.children[1].kind == nkInfix and n.children[1].children.len >= 3 and
             n.children[1].children[0].kind == nkIdent and
             n.children[1].children[0].name == "as")):
        ctx.add(", ")
        genNode(ctx, n.children[1], PrecAssign)
        if n.children.len >= 3 and n.children[2].kind == nkLitString:
          ctx.add(" from ")
          genNode(ctx, n.children[2], PrecAssign)
      else:
        for i in 1 ..< n.children.len:
          ctx.add(',')
          ctx.add(' ')
          genNode(ctx, n.children[i], PrecAssign)
    else:
      ctx.add("import ")
      for i, child in n.children:
        if i > 0: ctx.add(',')
        ctx.add(' ')
        genNode(ctx, child, PrecAssign)
  of nkInclude:
    ctx.add("include")
    if n.children.len > 0:
      ctx.add(' ')
      genNode(ctx, n.children[0], PrecAssign)
  of nkFunction:
    genFn(ctx, n)
  of nkVar:
    ctx.add("var")
    for i, child in n.children:
      if i > 0: ctx.add(',')
      if i == 0: ctx.add(' ')
      genNode(ctx, child, PrecAssign)
  of nkCommentGroup:
    ## Commented expressions: children are comments plus exactly one
    ## expression node (last). Emit the expression transparently — braces
    ## would change the meaning (`(a && b)` must not become `{a && b}`).
    var exprNode: Node = nil
    for c in n.children:
      if not c.isNil and c.kind notin {nkInlineComment, nkDocComment}:
        exprNode = c
    genNode(ctx, exprNode, parentPrec, parentOp, isLhs)
    if ctx.opts.preserveComments:
      for c in n.children:
        if not c.isNil and c.kind == nkDocComment:
          ctx.add("/*" & c.children[0].valStr & "*/")
        elif not c.isNil and c.kind == nkInlineComment:
          ctx.add("//" & c.children[0].valStr & "\n")
  of nkBlock:
    if isObjLiteral(n):
      genObjLiteral(ctx, n)
    else:
      ctx.add('{')
      genBlockStmts(ctx, n.children)
      var lastChild: Node = nil
      for j in countdown(n.children.len - 1, 0):
        if not n.children[j].isNil and n.children[j].kind != nkEmpty and
           n.children[j].kind != nkInlineComment and
           n.children[j].kind != nkDocComment:
          lastChild = n.children[j]
          break
      stripSemiBeforeBrace(ctx, lastChild)
      ctx.add('}')
  of nkStatement:
    genStmt(ctx, n)
  of nkIdentDefs:
    for i, child in n.children:
      if child.isNil: continue
      if i == 0:
        genNode(ctx, child, PrecAssign)
      elif i == 1 and child.kind != nkEmpty:
        ctx.add(':')
        genNode(ctx, child, PrecAssign)
      elif i == 2 and child.kind != nkEmpty:
        ctx.add('=')
        # Parenthesized comma expressions keep their grouping
        if isCommaExpr(child):
          ctx.add('(')
          genNode(ctx, child, 0)
          ctx.add(')')
        else:
          genNode(ctx, child, PrecAssign)
  of nkClass, nkInterface:
    discard
  else:
    discard

proc fnNameless(n: Node): bool =
  ## True for function nodes that cannot appear as bare statements:
  ## arrows and anonymous function expressions.
  if n.isNil or n.kind != nkFunction or n.children.len == 0: return false
  let c0 = n.children[0]
  if c0.isNil: return false
  if c0.kind == nkEmpty: return true
  if c0.kind == nkIdent and c0.name == "async":
    return n.children.len < 4
  if c0.kind == nkIdent and c0.name == "function":
    return not (n.children.len > 2 and not n.children[2].isNil and
                n.children[2].kind == nkIdent)
  false

proc genStmt(ctx: var GenContext, n: Node) =
  if n.isNil or n.kind == nkEmpty:
    return
  if n.kind == nkBlock:
    genNode(ctx, n, -1)
    return
  if n.kind != nkStatement:
    ctx.track(n)
    # A nameless function (or an immediately-invoked one) at statement
    # position must stay parenthesized — `function(){}()` parses as a
    # declaration plus a call, changing the meaning entirely.
    if (n.kind == nkFunction and fnNameless(n)) or
       (n.kind == nkCall and n.children.len > 0 and fnNameless(n.children[0])):
      ctx.add('(')
      genNode(ctx, n, -1, "", true)
      ctx.add(')')
      return
    genNode(ctx, n, -1, "", true)
    return
  ctx.track(n)
  if n.children.len == 0:
    return
  let kwNode = n.children[0]
  if kwNode.isNil or kwNode.kind != nkIdent:
    genNode(ctx, n, -1)
    return
  let kw = kwNode.name

  case kw
  of "var", "let", "const":
    ctx.add(kw)
    var firstDecl = true
    for i in 1 ..< n.children.len:
      let decl = n.children[i]
      if decl.isNil or decl.kind == nkEmpty: continue
      if firstDecl:
        ctx.add(' ')
        firstDecl = false
      else:
        ctx.add(',')
      genNode(ctx, decl, PrecAssign)
  of "if":
    ctx.add("if(")
    if n.children.len > 1 and not n.children[1].isNil:
      genNode(ctx, n.children[1], PrecAssign)
    ctx.add(')')
    var hasElse = false
    if n.children.len > 3:
      for j in 3 ..< n.children.len:
        let c = n.children[j]
        if not c.isNil and c.kind != nkEmpty:
          hasElse = true
          break
    if n.children.len > 2:
      genThenElse(ctx, n.children[2], beforeElse = hasElse)
    else:
      ctx.add(';')
    # Trailing children hold the else side: either an else-if chain
    # (nested nkStatement("if")), a plain body statement/expression,
    # or a block.
    var i = 3
    while i < n.children.len:
      let clause = n.children[i]
      i += 1
      if clause.isNil or clause.kind == nkEmpty:
        continue
      ctx.add("else")
      if clause.kind == nkStatement and clause.children.len > 0 and
         not clause.children[0].isNil and clause.children[0].kind == nkIdent and
         clause.children[0].name == "else":
        # explicit else wrapper (defensive; not produced by the JS parser)
        if clause.children.len > 1:
          genThenElse(ctx, clause.children[1])
      elif clause.kind == nkStatement and clause.children.len > 0 and
           not clause.children[0].isNil and clause.children[0].kind == nkIdent and
           clause.children[0].name == "if":
        # else-if chain — recurse so nested chains keep working
        genStmt(ctx, clause)
      elif clause.kind == nkBlock:
        genNode(ctx, clause, -1)
      else:
        genThenElse(ctx, clause)
      break

  of "yield":
    ## yield [ * ] [expr] (generator statements from the parser)
    ctx.add("yield")
    var i = 1
    if i < n.children.len and not n.children[i].isNil and
       n.children[i].kind == nkIdent and n.children[i].name == "*":
      ctx.add('*')
      inc i
    if i < n.children.len and not n.children[i].isNil and
       n.children[i].kind != nkEmpty:
      ctx.add(' ')
      genNode(ctx, n.children[i], PrecAssign)

  of "async":
    ## async function f() {...} — parsed as Statement([async, fnNode])
    if n.children.len > 1 and not n.children[1].isNil:
      ctx.add("async ")
      genStmt(ctx, n.children[1])

  of "while":
    ctx.add("while(")
    if n.children.len > 1:
      genNode(ctx, n.children[1], PrecAssign)
    ctx.add(')')
    if n.children.len > 2:
      let body = n.children[2]
      if not body.isNil and body.kind == nkBlock:
        genNode(ctx, body, -1)
      elif not body.isNil and body.kind != nkEmpty:
        genStmt(ctx, body)
        if ctx.result.len > 0 and ctx.result[^1] != ';':
          ctx.add(';')
      else:
        ctx.add(';')

  of "do-while":
    ctx.add("do")
    if n.children.len > 1:
      let body = n.children[1]
      # `while (...)` follows immediately. Non-block bodies need a `;`
      # unless they end in `}` (`do i++; while(x)` but `do f(){}while(x)`).
      if not body.isNil and body.kind == nkBlock:
        genNode(ctx, body, -1)
      elif not body.isNil and body.kind != nkEmpty:
        genStmt(ctx, body)
        if ctx.result.len > 0 and ctx.result[^1] != '}' and
           ctx.result[^1] != ';':
          ctx.add(';')
      else:
        ctx.add(';')
    ctx.add("while(")
    if n.children.len > 2:
      genNode(ctx, n.children[2], PrecAssign)
    ctx.add(')')

  of "for":
    # for-of / for-in carry a marker child ("of" / "in" / "await-of" ...)
    let marker = n.children[1]
    let isForOf = n.children.len >= 4 and not marker.isNil and
      marker.kind == nkIdent and
      marker.name in ["of", "in", "await-of", "await-in"]
    if isForOf:
      ctx.add("for")
      if marker.name.startsWith("await"):
        ctx.add(" await")
      ctx.add('(')
      if not n.children[2].isNil:
        if n.children[2].kind == nkStatement:
          genStmt(ctx, n.children[2])
        else:
          genNode(ctx, n.children[2], PrecAssign)
      ctx.add(if marker.name.endsWith("in"): " in " else: " of ")
      genNode(ctx, n.children[3], PrecAssign)
      ctx.add(')')
      if n.children.len > 4:
        let body = n.children[4]
        if not body.isNil and body.kind == nkBlock:
          genNode(ctx, body, -1)
        elif not body.isNil and body.kind != nkEmpty:
          genStmt(ctx, body)
          if ctx.result.len > 0 and ctx.result[^1] != ';':
            ctx.add(';')
        else:
          ctx.add(';')
    else:
      ctx.add("for(")
      if n.children.len > 1:
        let init = n.children[1]
        if not init.isNil and init.kind == nkStatement:
          genStmt(ctx, init)
        elif not init.isNil and init.kind == nkEmpty:
          discard
        elif not init.isNil:
          genNode(ctx, init, PrecAssign)
      ctx.add(';')
      if n.children.len > 2 and not n.children[2].isNil:
        genNode(ctx, n.children[2], PrecAssign)
      ctx.add(';')
      if n.children.len > 3 and not n.children[3].isNil:
        genNode(ctx, n.children[3], PrecAssign)
      ctx.add(')')
      if n.children.len > 4:
        let body = n.children[4]
        if not body.isNil and body.kind == nkBlock:
          genNode(ctx, body, -1)
        elif not body.isNil and body.kind != nkEmpty:
          genStmt(ctx, body)
          if ctx.result.len > 0 and ctx.result[^1] != ';':
            ctx.add(';')
        else:
          ctx.add(';')

  of "switch":
    ctx.add("switch(")
    if n.children.len > 1:
      genNode(ctx, n.children[1], PrecAssign)
    ctx.add(')')
    if n.children.len > 2:
      let body = n.children[2]
      ctx.add('{')
      var lastCase: Node = nil
      for caseNode in body.children:
        if not caseNode.isNil and caseNode.kind != nkEmpty and
           caseNode.kind != nkInlineComment and
           caseNode.kind != nkDocComment:
          lastCase = caseNode
        if caseNode.kind == nkStatement and caseNode.children.len > 0 and
           not caseNode.children[0].isNil and
           caseNode.children[0].kind == nkIdent:
          let caseKw = caseNode.children[0].name
          case caseKw
          of "case":
            if caseNode.children.len > 1 and ctx.opts.minify and
               returnOperandTight(caseNode.children[1]):
              ctx.add("case")
              genNode(ctx, caseNode.children[1], PrecAssign)
            else:
              ctx.add("case ")
              if caseNode.children.len > 1:
                genNode(ctx, caseNode.children[1], PrecAssign)
            ctx.add(':')
            for i in 2 ..< caseNode.children.len:
              let stmt = caseNode.children[i]
              genStmt(ctx, stmt)
              # Non-block bodies need a terminator before the next clause
              if not stmt.isNil and stmt.kind != nkBlock and
                 ctx.result.len > 0 and ctx.result[^1] != '}':
                ctx.add(';')
          of "default":
            ctx.add("default:")
            for i in 1 ..< caseNode.children.len:
              let stmt = caseNode.children[i]
              genStmt(ctx, stmt)
              if not stmt.isNil and stmt.kind != nkBlock and
                 ctx.result.len > 0 and ctx.result[^1] != '}':
                ctx.add(';')
          else:
            discard
        else:
          genStmt(ctx, caseNode)
      stripSemiBeforeBrace(ctx, lastCase)
      ctx.add('}')

  of "try":
    ## Nested shape from the JS parser:
    ## [try, bodyBlock, exceptClause?, finallyClause?]
    ctx.add("try")
    for i in 1 ..< n.children.len:
      let clause = n.children[i]
      if clause.isNil: continue
      if clause.kind == nkStatement and clause.children.len > 0 and
         not clause.children[0].isNil and clause.children[0].kind == nkIdent:
        let clauseKw = clause.children[0].name
        case clauseKw
        of "except":
          ctx.add("catch")
          if clause.children.len > 2 and not clause.children[1].isNil and
             clause.children[1].kind == nkIdent:
            ctx.add('(')
            genNode(ctx, clause.children[1], PrecAssign)
            ctx.add(')')
          elif clause.children.len > 2 and not clause.children[1].isNil and
               clause.children[1].kind == nkLitString:
            # destructured parameter, kept as raw braces
            ctx.add('(')
            ctx.add(clause.children[1].valStr)
            ctx.add(')')
          if clause.children.len > 2:
            let body = clause.children[^1]
            if not body.isNil and body.kind == nkBlock:
              genNode(ctx, body, -1)
            else:
              ctx.add("{}")
        of "finally":
          if clause.children.len > 1:
            let body = clause.children[^1]
            if not body.isNil and body.kind == nkBlock:
              ctx.add("finally")
              genNode(ctx, body, -1)
        else:
          discard
      elif clause.kind == nkBlock:
        genNode(ctx, clause, -1)
      else:
        genStmt(ctx, clause)

  of "class":
    ctx.add("class")
    if n.children.len > 1 and n.children[1].kind == nkIdent:
      ctx.add(' ')
      ctx.add(n.children[1].name)
    if n.children.len > 2 and n.children[2].kind != nkEmpty:
      ctx.add(" extends ")
      genNode(ctx, n.children[2], PrecMember)
    if n.children.len > 3:
      let body = n.children[3]
      if body.kind == nkBlock:
        ctx.add('{')
        var memberIdx = 0
        let members = body.children
        while memberIdx < members.len:
          let child = members[memberIdx]
          inc memberIdx
          if child.isNil or child.kind in {nkEmpty, nkInlineComment, nkDocComment}:
            continue
          # static { ... } initializer block
          if child.kind == nkStatement and child.children.len > 1 and
             not child.children[0].isNil and child.children[0].kind == nkIdent and
             child.children[0].name == "static-block":
            ctx.add("static")
            genNode(ctx, child.children[1], -1)
            continue
          # Field member: ["field", flagIdents..., key, initializer?]
          if child.kind == nkStatement and child.children.len >= 3 and
             not child.children[0].isNil and child.children[0].kind == nkIdent and
             child.children[0].name == "field":
            var j = 1
            while j < child.children.len - 2:
              let flag = child.children[j]
              if not flag.isNil and flag.kind == nkIdent and
                 (flag.name == "*" or isMethodFlag(flag.name)):
                if flag.name == "*": ctx.add('*')
                else:
                  ctx.add(flag.name)
                  ctx.add(' ')
              inc j
            genMemberKey(ctx, child.children[j])
            inc j
            let init = child.children[j]
            if not init.isNil and init.kind != nkEmpty:
              ctx.add(':')
              genNode(ctx, init, PrecAssign)
            if memberIdx < members.len:
              ctx.add(';')
            continue
          if child.kind != nkColonExpr or child.children.len < 2:
            continue
          let key = child.children[0]
          let val = child.children[1]
          if val.kind == nkFunction and isMethodShorthand(val):
            genMethod(ctx, val, key)
          else:
            # Field (bare `x;` or initialized `x = expr;`)
            genMemberKey(ctx, key)
            if val.kind != nkEmpty:
              ctx.add(':')
              genNode(ctx, val, PrecAssign)
            if memberIdx < members.len:
              ctx.add(';')
        var lastMember: Node = nil
        for j in countdown(members.len - 1, 0):
          if not members[j].isNil and members[j].kind != nkEmpty and
             members[j].kind != nkInlineComment and
             members[j].kind != nkDocComment:
            lastMember = members[j]
            break
        stripSemiBeforeBrace(ctx, lastMember)
        ctx.add('}')

  of "export":
    if ctx.opts.stripExports:
      # Wrapped formats: strip the `export` keyword; declarations emit as-is.
      if n.children.len > 1:
        let inner = n.children[1]
        if inner.kind == nkIdent and inner.name == "default":
          if n.children.len > 2:
            let local = defaultLocalName(n)
            if local != "__default":
              # Named `export default function Foo` / `class Foo`:
              # keep the declaration so importers alias to Foo.
              genNode(ctx, n.children[2], PrecAssign)
            else:
              # export default expr -> var __default = expr;
              ctx.add("var __default=")
              genNode(ctx, n.children[2], PrecAssign)
              ctx.add(';')
        elif inner.kind in {nkFunction, nkStatement}:
          genNode(ctx, inner, PrecAssign)
        # export {a, b} / export * from ... -> nothing (module-boundary only)
      return
    ctx.add("export")
    if n.children.len > 1:
      let inner = n.children[1]
      if inner.kind == nkIdent and inner.name == "default":
        ctx.add(" default ")
        if n.children.len > 2:
          genNode(ctx, n.children[2], PrecAssign)
      elif inner.kind == nkIdentDefs:
        ctx.add(" {")
        genExprList(ctx, inner.children, 0)
        ctx.add("}")
        if n.children.len > 2 and n.children[2].kind == nkLitString:
          ctx.add(" from ")
          genNode(ctx, n.children[2], PrecAssign)
      elif inner.kind == nkPrefix or
           (inner.kind == nkInfix and inner.children.len >= 3 and
            inner.children[0].kind == nkIdent and
            inner.children[0].name == "as"):
        ctx.add(' ')
        genNode(ctx, inner, PrecAssign)
        if n.children.len > 2 and n.children[2].kind == nkLitString:
          ctx.add(" from ")
          genNode(ctx, n.children[2], PrecAssign)
      elif inner.kind == nkIdent and inner.name == "*":
        ctx.add(" *")
        if n.children.len > 2 and n.children[2].kind == nkLitString:
          ctx.add(" from ")
          genNode(ctx, n.children[2], PrecAssign)
      elif inner.kind in {nkFunction, nkStatement}:
        ctx.add(' ')
        genNode(ctx, inner, PrecAssign)
      else:
        ctx.add(' ')
        genNode(ctx, inner, PrecAssign)

  of "label":
    if n.children.len > 1:
      genNode(ctx, n.children[1], -1)
    ctx.add(':')
    if n.children.len > 2:
      genStmt(ctx, n.children[2])

  of "break":
    ctx.add("break")
    if n.children.len > 1:
      ctx.add(' ')
      genNode(ctx, n.children[1], PrecAssign)

  of "continue":
    ctx.add("continue")
    if n.children.len > 1:
      ctx.add(' ')
      genNode(ctx, n.children[1], PrecAssign)

  of "throw":
    ctx.add("throw")
    if n.children.len > 1:
      if ctx.opts.minify and returnOperandTight(n.children[1]):
        genNode(ctx, n.children[1], PrecAssign)
      else:
        ctx.add(' ')
        if needsValueParens(n.children[1]):
          ctx.add('(')
          genNode(ctx, n.children[1], 0)
          ctx.add(')')
        else:
          genNode(ctx, n.children[1], PrecAssign)

  of "debugger":
    ctx.add("debugger")

  of "comma":
    for i in 1 ..< n.children.len:
      if i > 1: ctx.add(',')
      genNode(ctx, n.children[i], PrecAssign)

  of "function":
    genNode(ctx, n.children[1], -1)

  of "computed":
    ctx.add('[')
    if n.children.len > 1:
      genNode(ctx, n.children[1], 0)
    ctx.add(']')

  else:
    genNode(ctx, n, -1)

proc isEmptyishStmt(n: Node): bool {.inline.} =
  n.isNil or n.kind == nkEmpty

proc endsWithEmptyBody(n: Node): bool =
  ## True when `n`'s emission ends with a `;` that IS an empty statement
  ## (a required body) rather than a terminator. Only those keep their `;`
  ## before a closing brace; every other trailing `;` drops (ASI inserts it).
  ## Unknown shapes default to keeping (safe): stripping is purely savings.
  if isEmptyishStmt(n):
    return true
  if n.kind == nkCommentGroup:
    # Comments emit nothing; look through to the wrapped statement.
    if n.children.len > 0:
      return endsWithEmptyBody(n.children[0])
    return true
  if n.kind != nkStatement or n.children.len == 0:
    # Plain expressions, blocks, functions: any trailing `;` terminates.
    return false
  if n.children[0].isNil or n.children[0].kind != nkIdent:
    return true
  let kw = n.children[0].name
  if kw == "if":
    # Final else-side body decides; an absent one leaves the then-body.
    var last: Node = nil
    if n.children.len > 2:
      last = n.children[2]
    var i = 3
    while i < n.children.len:
      let c = n.children[i]
      if not c.isNil and c.kind != nkEmpty:
        last = c
      inc i
    if last.isNil:
      return true
    if last.kind == nkStatement and last.children.len > 0 and
       not last.children[0].isNil and last.children[0].kind == nkIdent and
       (last.children[0].name == "if" or last.children[0].name == "else"):
      return endsWithEmptyBody(last)
    if last.kind == nkBlock:
      return false
    return endsWithEmptyBody(last)
  if kw == "else":
    # Explicit else wrapper ["else", body]: the body decides.
    if n.children.len > 1:
      return endsWithEmptyBody(n.children[1])
    return true
  if kw == "while" or kw == "for" or kw == "with" or kw == "label":
    # Body is always last; a missing one emitted no `;` (strip is a no-op).
    if n.children.len == 0:
      return true
    return endsWithEmptyBody(n.children[^1])
  if kw == "case" or kw == "default":
    # Empty case bodies emit nothing (genStmt is silent on empties), so a
    # trailing `;` may still terminate an `if(x);` body: check the last one.
    var last: Node = nil
    for i in 1 ..< n.children.len:
      if not n.children[i].isNil and n.children[i].kind != nkEmpty:
        last = n.children[i]
    if last.isNil:
      return false
    return endsWithEmptyBody(last)
  if kw in ["var", "let", "const", "return", "throw", "break", "continue",
            "debugger", "comma", "computed", "do-while", "switch", "try",
            "except", "finally", "field", "static-block", "yield", "import",
            "export", "function", "async"]:
    return false
  true

proc stripSemiBeforeBrace(ctx: var GenContext, lastChild: Node) =
  ## Drop a trailing `;` before a closing `}` in minify mode, unless it is
  ## itself an empty statement body (`if(x);}`, `while(x);}` stay intact;
  ## ASI re-inserts every dropped terminator).
  if not ctx.opts.minify:
    return
  if ctx.result.len > 0 and ctx.result[^1] == ';' and
     not endsWithEmptyBody(lastChild):
    ctx.result.setLen(ctx.result.len - 1)

proc restIsEmpty(children: seq[Node], fromIdx: int): bool =
  ## True when every node from `fromIdx` on produces no output
  ## (nil, empty or comment-only).
  for j in fromIdx ..< children.len:
    let rest = children[j]
    if rest.isNil or rest.kind in {nkEmpty, nkInlineComment, nkDocComment}:
      continue
    return false
  true

proc genBlockStmts(ctx: var GenContext, children: seq[Node]) =
  ## Emits a brace-delimited statement list.
  ## - Adjacent declarations sharing a keyword are joined (`let a=1;let b=2`
  ##   becomes `let a=1,b=2`).
  ## - The terminator of the LAST statement of a block is dropped (ASI
  ##   supplies it before `}`). Only when comments are not preserved, since
  ##   `x()//c}` would comment out the brace.
  var i = 0
  while i < children.len:
    let stmt = children[i]
    inc i
    if stmt.isNil: continue

    # Non-block-like statements ALWAYS need their `;` — even when the
    # emitted text happens to end with `}` (e.g. assignments of anonymous
    # functions: `h.value=function(){};`). Only block-like heads
    # (if/for/while/...) may omit it.
    template termSemi() {.dirty.} =
      if not restIsEmpty(children, i):
        ctx.add(';')
      elif ctx.opts.preserveComments:
        ctx.add(';')

    if isDeclStmt(stmt):
      let kwName = stmt.children[0].name
      ctx.add(kwName)
      var first = true
      var cur = stmt
      while true:
        for j in 1 ..< cur.children.len:
          let decl = cur.children[j]
          if decl.isNil or decl.kind == nkEmpty: continue
          if first:
            ctx.add(' ')
            first = false
          else:
            ctx.add(',')
          genNode(ctx, decl, PrecAssign)
        var nxt: Node = nil
        var nxtIdx = i
        # Multi-line sources separate statements with empty placeholders;
        # look past those (never past comments, which must keep their place
        # when preserved) for a joinable same-keyword declaration.
        while nxtIdx < children.len:
          let cand = children[nxtIdx]
          if cand.isNil or cand.kind == nkEmpty:
            inc nxtIdx
            continue
          nxt = cand
          break
        if nxt != nil and isDeclStmt(nxt) and nxt.children.len > 0 and
           not nxt.children[0].isNil and nxt.children[0].name == kwName:
          i = nxtIdx + 1
          cur = nxt
        else:
          break
      if not restIsEmpty(children, i) or ctx.opts.preserveComments:
        ctx.add(';')
      continue

    genStmt(ctx, stmt)
    if stmt.kind == nkStatement:
      let isBlockStmt = stmt.children.len > 0 and stmt.children[0].kind == nkIdent and
        isBlockStmtKw(stmt.children[0].name)
      if not isBlockStmt:
        termSemi()
    elif stmt.kind == nkReturn or stmt.kind == nkImport:
      termSemi()
    elif stmt.kind == nkFunction:
      # Named declarations self-terminate; anonymous ones are expression
      # statements and need a terminator.
      if fnNameless(stmt):
        termSemi()
    elif stmt.kind notin {nkBlock, nkEmpty, nkInlineComment, nkDocComment}:
      termSemi()

proc generateJs*(node: Node, opts: JsGenOptions, sourceFile: string = "", sourceCode: string = ""): tuple[code: string, sourceMapRaw: string] =
  var ctx = GenContext(opts: opts)
  if opts.sourceMap and sourceFile.len > 0:
    ctx.sourceMap = newSourceMap(changeFileExt(splitFile(sourceFile).name, ".js"))
    discard ctx.sourceMap.addSource(sourceFile, sourceCode)
  if opts.mangle:
    ctx.mangler = newMangler()
    ctx.mangler.trackOrig = opts.sourceMap
    for preserved in opts.preserveNames:
      preserveName(ctx.mangler, preserved)
    mangleScopes(ctx.mangler, node, opts.stripExports)
  genNode(ctx, node, -1)
  result.code = ctx.result
  if ctx.sourceMap != nil:
    result.sourceMapRaw = ctx.sourceMap.generate()

proc generateJs*(program: OpenAstProgram, opts: JsGenOptions, sourceFile: string = "", sourceCode: string = ""): tuple[code: string, sourceMapRaw: string] =
  var ctx = GenContext(opts: opts)
  if opts.sourceMap and sourceFile.len > 0:
    ctx.sourceMap = newSourceMap(changeFileExt(splitFile(sourceFile).name, ".js"))
    discard ctx.sourceMap.addSource(sourceFile, sourceCode)
  if opts.mangle:
    ctx.mangler = newMangler()
    ctx.mangler.trackOrig = opts.sourceMap
    for preserved in opts.preserveNames:
      preserveName(ctx.mangler, preserved)
    mangleScopes(ctx.mangler, program.nodes, opts.stripExports)
  ctx.result = newStringOfCap(sourceCode.len + sourceCode.len shr 3)
  # Program level shares the block emission rules (declaration joining,
  # ASI-safe terminators); there is no closing brace at top level but the
  # trailing terminator is dropped all the same.
  genBlockStmts(ctx, program.nodes)
  result.code = ctx.result
  if ctx.sourceMap != nil:
    result.sourceMapRaw = ctx.sourceMap.generate()
