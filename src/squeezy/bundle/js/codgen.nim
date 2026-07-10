# A dead simple JavaScript and CSS validator, bundler and minifier
#
# (c) 2025 George Lemon | LGPL-v3 License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/squeezy

import std/[strutils, os]
import sweetsyntax/engine/ast
import ../common
import ../sourcemap
import ./mangler

type
  GenContext = object
    result: string
    genLine, genCol: int
    opts: JsGenOptions
    mangler: Mangler
    sourceMap: SourceMap

proc add(ctx: var GenContext, s: string) =
  ctx.result.add(s)
  if ctx.sourceMap != nil:
    for c in s:
      if c == '\n':
        inc ctx.genLine
        ctx.genCol = 0
      else:
        inc ctx.genCol

proc add(ctx: var GenContext, c: char) =
  ctx.result.add(c)
  if ctx.sourceMap != nil:
    if c == '\n':
      inc ctx.genLine
      ctx.genCol = 0
    else:
      inc ctx.genCol

proc track(ctx: var GenContext, n: Node, addName: bool = false) =
  if ctx.sourceMap != nil and n != nil:
    var nameIdx = -1
    if addName and n.kind == nkIdent:
      let name = n.name
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

proc isRightAssoc(op: string): bool =
  op in RightAssocOps

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
  n.kind == nkBlock and n.children.len > 0 and
    (n.children[0].kind == nkColonExpr or
     (n.children[0].kind == nkCall and n.children[0].children.len > 0 and
      n.children[0].children[0].kind == nkIdent and
      n.children[0].children[0].name == "spread"))

proc genNode(ctx: var GenContext, n: Node, parentPrec: int = -1, parentOp: string = "", isLhs: bool = true)
proc genStmt(ctx: var GenContext, n: Node)
proc genBlockStmts(ctx: var GenContext, children: seq[Node])

proc genExprList(ctx: var GenContext, nodes: seq[Node], startIdx: int = 0) =
  for i in startIdx ..< nodes.len:
    if i > startIdx:
      ctx.add(',')
    genNode(ctx, nodes[i], PrecAssign, "comma")

proc genThenElse(ctx: var GenContext, body: Node) =
  if body.kind == nkBlock:
    genNode(ctx, body, -1)
  else:
    genStmt(ctx, body)

proc genObjLiteral(ctx: var GenContext, n: Node) =
  ctx.add('{')
  for i, child in n.children:
    if i > 0:
      ctx.add(',')
    case child.kind
    of nkColonExpr:
      let key = child.children[0]
      let val = child.children[1]
      if key.kind == nkLitString:
        ctx.add(key.valStr)
      elif key.kind == nkIdent:
        let keyName = key.name
        if val.kind == nkFunction:
          let fnChildren = val.children
          if fnChildren.len >= 3 and fnChildren[0].kind == nkEmpty:
            if keyName.len > 0:
              ctx.add(keyName)
            genNode(ctx, val)
          else:
            ctx.add(keyName)
            ctx.add(':')
            genNode(ctx, val, PrecAssign)
        else:
          ctx.add(keyName)
          ctx.add(':')
          genNode(ctx, val, PrecAssign)
      elif key.kind == nkBracketExpr:
        ctx.add('[')
        genNode(ctx, key.children[0], 0)
        ctx.add(']')
        ctx.add(':')
        genNode(ctx, val, PrecAssign)
      else:
        genNode(ctx, key)
        ctx.add(':')
        genNode(ctx, val, PrecAssign)
    of nkCall:
      if child.children.len > 0 and child.children[0].kind == nkIdent and
         child.children[0].name == "spread":
        ctx.add("...")
        if child.children.len > 1:
          genNode(ctx, child.children[1], PrecAssign)
    of nkFunction:
      genNode(ctx, child)
    else:
      genNode(ctx, child, PrecAssign)
  ctx.add('}')

proc genFn(ctx: var GenContext, n: Node) =
  ctx.track(n)
  let children = n.children
  let isArrow = children.len >= 1 and children[0].kind == nkEmpty
  if not isArrow:
    if children.len >= 1 and children[0].kind == nkIdent:
      ctx.add("function")
    if children.len >= 2 and children[1].kind == nkIdent and children[1].name == "*":
      ctx.add('*')
    if children.len >= 3 and children[2].kind == nkIdent:
      ctx.add(' ')
      ctx.add(children[2].name)
    if children.len >= 4 and children[3].kind == nkIdentDefs and
       children[3].children.len > 0:
      ctx.add('<')
      genExprList(ctx, children[3].children, 0)
      ctx.add('>')
    ctx.add('(')
    if children.len >= 5 and children[4].kind == nkIdentDefs:
      genExprList(ctx, children[4].children, 0)
    ctx.add(')')
    let bodyIdx = if children.len >= 7: 6 else: children.len - 1
    if bodyIdx < children.len:
      let body = children[bodyIdx]
      if body.kind == nkBlock:
        ctx.add('{')
        genBlockStmts(ctx, body.children)
        ctx.add('}')
      elif body.kind == nkEmpty:
        discard
      else:
        ctx.add('{')
        genStmt(ctx, body)
        ctx.add('}')
  else:
    let paramsIdx = 1
    let bodyIdx = 2
    if paramsIdx < children.len and children[paramsIdx].kind == nkIdentDefs:
      let params = children[paramsIdx]
      if params.children.len == 1:
        genNode(ctx, params.children[0], PrecAssign)
      else:
        ctx.add('(')
        genExprList(ctx, params.children, 0)
        ctx.add(')')
    ctx.add("=>")
    if bodyIdx < children.len:
      let body = children[bodyIdx]
      if body.kind == nkBlock:
        if body.children.len == 1:
          genStmt(ctx, body.children[0])
        else:
          ctx.add('{')
          genBlockStmts(ctx, body.children)
          ctx.add('}')
      elif body.kind == nkEmpty:
        discard
      else:
        genNode(ctx, body, PrecAssign)

proc genNode(ctx: var GenContext, n: Node, parentPrec: int = -1, parentOp: string = "", isLhs: bool = true) =
  if n.isNil:
    return
  case n.kind
  of nkEmpty: discard
  of nkNil:
    ctx.track(n)
    ctx.add("null")
  of nkLitBool:
    ctx.track(n)
    ctx.add(if n.valBool: "true" else: "false")
  of nkLitInt:
    ctx.track(n)
    ctx.add($n.valInt)
  of nkLitFloat:
    ctx.track(n)
    let s = $n.valFloat
    ctx.add(s)
  of nkLitString:
    ctx.track(n)
    let raw = n.valStr
    let inner = if raw.len >= 2 and (raw[0] == '"' or raw[0] == '\''):
      raw[1..^2] else: raw
    ctx.add('"')
    for c in inner:
      case c
      of '\n': ctx.add("\\n")
      of '\r': ctx.add("\\r")
      of '\t': ctx.add("\\t")
      of '"': ctx.add("\\\"")
      of '\\': ctx.add("\\\\")
      else: ctx.add(c)
    ctx.add('"')
  of nkLitBigInt:
    ctx.track(n)
    ctx.add(n.valBigInt & "n")
  of nkIdent:
    ctx.track(n, addName=true)
    let name = if ctx.mangler != nil: ctx.mangler.getMangled(n.name) else: n.name
    ctx.add(name)
  of nkVarTy: ctx.add(n.name)
  of nkRegex:
    if n.children.len > 0 and n.children[0].kind == nkLitString:
      ctx.add(n.children[0].valStr)
  of nkInlineComment:
    if ctx.opts.preserveComments:
      ctx.add("//" & n.children[0].valStr)
  of nkDocComment:
    if ctx.opts.preserveComments:
      ctx.add("/*" & n.children[0].valStr & "*/")
  of nkPrefix:
    let opName = if n.children.len > 0 and n.children[0].kind == nkIdent: n.children[0].name else: ""
    let operand = if n.children.len > 1: n.children[1] else: nil
    if opName == "spread":
      ctx.add("...")
      if not operand.isNil:
        genNode(ctx, operand, PrecAssign)
    elif opName == "await":
      ctx.add("await ")
      if not operand.isNil:
        genNode(ctx, operand, PrecPrefix)
    else:
      let addSpace = opName in ["typeof", "void", "delete", "new"]
      ctx.add(opName)
      if addSpace and not operand.isNil:
        if operand.kind in {nkLitInt, nkLitFloat, nkLitString, nkLitBool, nkNil}:
          ctx.add(' ')
        elif operand.kind == nkPrefix:
          ctx.add(' ')
      if not operand.isNil:
        let wrap = operand.kind == nkInfix or (operand.kind == nkCall and opName == "new")
        if wrap:
          ctx.add('(')
          genNode(ctx, operand, 0)
          ctx.add(')')
        else:
          genNode(ctx, operand, PrecPrefix)
  of nkPostfix:
    if n.children.len >= 2:
      genNode(ctx, n.children[0], PrecPostfix, "", true)
      if n.children[1].kind == nkIdent:
        ctx.add(n.children[1].name)
  of nkInfix:
    if n.children.len >= 3 and n.children[0].kind == nkIdent:
      let op = n.children[0].name
      let lhs = n.children[1]
      let rhs = n.children[2]
      let prec = getPrec(op)
      if prec >= 0:
        if op == "=" or op.endsWith("="):
          genNode(ctx, lhs, prec, op, false)
          ctx.add(op)
          genNode(ctx, rhs, prec, op, true)
        else:
          let wrapLhs = lhs.kind == nkInfix and lhs.children.len >= 3 and
            lhs.children[0].kind == nkIdent and
            needsParens(getPrec(lhs.children[0].name), prec, op, false)
          let wrapRhs = rhs.kind == nkInfix and rhs.children.len >= 3 and
            rhs.children[0].kind == nkIdent and
            needsParens(getPrec(rhs.children[0].name), prec, op, true)
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
      genNode(ctx, n.children[0], PrecMember, ".")
      ctx.add('.')
      if n.children[1].kind == nkIdent:
        ctx.add(n.children[1].name)
      else:
        genNode(ctx, n.children[1], PrecMember)
  of nkBracketExpr:
    if n.children.len >= 2:
      let first = n.children[0]
      if first.kind in {nkIdent, nkDotExpr, nkCall, nkBracketExpr, nkFunction, nkInfix}:
        genNode(ctx, first, PrecMember - 1, "[")
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
      ctx.add(':')
      genNode(ctx, n.children[1], PrecAssign)
  of nkCall:
    ctx.track(n)
    if n.children.len > 0 and n.children[0].kind == nkIdent:
      if n.children[0].name == "ternary":
        if n.children.len >= 4:
          genNode(ctx, n.children[1], PrecCond)
          ctx.add('?')
          genNode(ctx, n.children[2], PrecCond)
          ctx.add(':')
          genNode(ctx, n.children[3], PrecCond - 1)
        return
      elif n.children[0].name == "spread":
        ctx.add("...")
        if n.children.len > 1:
          genNode(ctx, n.children[1], PrecAssign)
        return
    if n.children.len > 0:
      genNode(ctx, n.children[0], PrecCall, "(")
    ctx.add('(')
    if n.children.len > 1:
      genExprList(ctx, n.children, 1)
    ctx.add(')')
  of nkReturn:
    ctx.track(n)
    ctx.add("return")
    if n.children.len > 0:
      ctx.add(' ')
      genNode(ctx, n.children[0], PrecAssign)
  of nkImport:
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
      ctx.add(' ')
      genNode(ctx, child, PrecAssign)
  of nkBlock:
    if isObjLiteral(n):
      genObjLiteral(ctx, n)
    else:
      ctx.add('{')
      genBlockStmts(ctx, n.children)
      ctx.add('}')
  of nkStatement:
    genStmt(ctx, n)
  of nkIdentDefs:
    for i, child in n.children:
      if i == 0:
        genNode(ctx, child, PrecAssign)
      elif i == 1 and child.kind != nkEmpty:
        ctx.add(':')
        genNode(ctx, child, PrecAssign)
      elif i == 2 and child.kind != nkEmpty:
        ctx.add('=')
        genNode(ctx, child, PrecAssign)
  of nkClass, nkInterface:
    discard
  else:
    discard

proc genStmt(ctx: var GenContext, n: Node) =
  if n.isNil or n.kind == nkEmpty:
    return
  if n.kind == nkBlock:
    genNode(ctx, n, -1)
    return
  if n.kind != nkStatement:
    ctx.track(n)
    genNode(ctx, n, -1, "", true)
    return
  ctx.track(n)
  if n.children.len == 0:
    return
  let kwNode = n.children[0]
  if kwNode.kind != nkIdent:
    genNode(ctx, n, -1)
    return
  let kw = kwNode.name

  if kw == "var" or kw == "let" or kw == "const":
    ctx.add(kw)
    for i in 1 ..< n.children.len:
      if i > 1: ctx.add(',')
      ctx.add(' ')
      genNode(ctx, n.children[i], PrecAssign)
    return

  if kw == "if":
    ctx.add("if(")
    if n.children.len > 1:
      genNode(ctx, n.children[1], PrecAssign)
    ctx.add(')')
    if n.children.len > 2:
      genThenElse(ctx, n.children[2])
    var i = 3
    while i < n.children.len:
      let clause = n.children[i]
      i += 1
      if clause.kind == nkBlock or (clause.kind == nkStatement and
         clause.children.len > 0 and clause.children[0].kind == nkIdent and
         clause.children[0].name == "else"):
        ctx.add("else")
        let body = if clause.kind == nkBlock: clause
                   elif clause.children.len > 1: clause.children[1]
                   else: Node(kind: nkEmpty)
        genThenElse(ctx, body)
        break
      else:
        ctx.add("else if(")
        genNode(ctx, clause, PrecAssign)
        ctx.add(')')
        if i < n.children.len:
          genThenElse(ctx, n.children[i])
          i += 1
    return

  if kw == "while":
    ctx.add("while(")
    if n.children.len > 1:
      genNode(ctx, n.children[1], PrecAssign)
    ctx.add(')')
    if n.children.len > 2:
      let body = n.children[2]
      if body.kind == nkBlock:
        genNode(ctx, body, -1)
      else:
        genStmt(ctx, body)
    return

  if kw == "do-while":
    ctx.add("do")
    if n.children.len > 1:
      let body = n.children[1]
      if body.kind == nkBlock:
        genNode(ctx, body, -1)
      else:
        genStmt(ctx, body)
    ctx.add("while(")
    if n.children.len > 2:
      genNode(ctx, n.children[2], PrecAssign)
    ctx.add(')')
    return

  if kw == "for":
    ctx.add("for(")
    if n.children.len > 1:
      let init = n.children[1]
      if init.kind == nkStatement:
        genStmt(ctx, init)
      elif init.kind == nkEmpty:
        discard
      else:
        genNode(ctx, init, PrecAssign)
    ctx.add(';')
    if n.children.len > 2:
      genNode(ctx, n.children[2], PrecAssign)
    ctx.add(';')
    if n.children.len > 3:
      genNode(ctx, n.children[3], PrecAssign)
    ctx.add(')')
    if n.children.len > 4:
      let body = n.children[4]
      if body.kind == nkBlock:
        genNode(ctx, body, -1)
      else:
        genStmt(ctx, body)
    return

  if kw == "switch":
    ctx.add("switch(")
    if n.children.len > 1:
      genNode(ctx, n.children[1], PrecAssign)
    ctx.add(')')
    if n.children.len > 2:
      let body = n.children[2]
      ctx.add('{')
      for caseNode in body.children:
        if caseNode.kind == nkStatement and caseNode.children.len > 0 and
           caseNode.children[0].kind == nkIdent:
          let caseKw = caseNode.children[0].name
          if caseKw == "case":
            ctx.add("case ")
            if caseNode.children.len > 1:
              genNode(ctx, caseNode.children[1], PrecAssign)
            ctx.add(':')
            for i in 2 ..< caseNode.children.len:
              genStmt(ctx, caseNode.children[i])
          elif caseKw == "default":
            ctx.add("default:")
            for i in 1 ..< caseNode.children.len:
              genStmt(ctx, caseNode.children[i])
        else:
          genStmt(ctx, caseNode)
      ctx.add('}')
    return

  if kw == "try":
    ctx.add("try")
    for i in 1 ..< n.children.len:
      let clause = n.children[i]
      if clause.kind == nkStatement and clause.children.len > 0 and
         clause.children[0].kind == nkIdent:
        let clauseKw = clause.children[0].name
        if clauseKw == "except":
          ctx.add("catch")
          if clause.children.len > 2 and clause.children[1].kind == nkIdent:
            ctx.add('(')
            genNode(ctx, clause.children[1], PrecAssign)
            ctx.add(')')
          elif clause.children.len > 1:
            let catchBody = clause.children[clause.children.len - 1]
            if catchBody.kind != nkBlock:
              ctx.add("(...)")
        if clause.children.len > 0:
          let body = clause.children[clause.children.len - 1]
          if body.kind == nkBlock:
            genNode(ctx, body, -1)
          else:
            genStmt(ctx, body)
      elif clause.kind == nkBlock:
        genNode(ctx, clause, -1)
      else:
        genStmt(ctx, clause)
    return

  if kw == "class":
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
        for child in body.children:
          if child.kind == nkColonExpr:
            let key = child.children[0]
            let val = child.children[1]
            if key.kind == nkIdent:
              if val.kind == nkFunction:
                let fnName = if val.children.len > 2 and val.children[2].kind == nkIdent:
                  val.children[2].name else: ""
                if fnName == "" or fnName == key.name:
                  genNode(ctx, val)
                else:
                  ctx.add(key.name)
                  ctx.add(':')
                  genNode(ctx, val, PrecAssign)
              else:
                ctx.add(key.name)
                if val.kind != nkEmpty:
                  ctx.add(':')
                  genNode(ctx, val, PrecAssign)
            elif key.kind == nkLitString:
              ctx.add(key.valStr)
              ctx.add(':')
              genNode(ctx, val, PrecAssign)
        ctx.add('}')
    return

  if kw == "export":
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
    return

  if kw == "label":
    if n.children.len > 1:
      genNode(ctx, n.children[1], -1)
    ctx.add(':')
    if n.children.len > 2:
      genStmt(ctx, n.children[2])
    return

  if kw == "break":
    ctx.add("break")
    if n.children.len > 1:
      ctx.add(' ')
      genNode(ctx, n.children[1], PrecAssign)
    return

  if kw == "continue":
    ctx.add("continue")
    if n.children.len > 1:
      ctx.add(' ')
      genNode(ctx, n.children[1], PrecAssign)
    return

  if kw == "throw":
    ctx.add("throw")
    if n.children.len > 1:
      ctx.add(' ')
      genNode(ctx, n.children[1], PrecAssign)
    return

  if kw == "debugger":
    ctx.add("debugger")
    return

  if kw == "comma":
    for i in 1 ..< n.children.len:
      if i > 1: ctx.add(',')
      genNode(ctx, n.children[i], PrecAssign)
    return

  if kw == "function":
    genNode(ctx, n.children[1], -1)
    return

  if kw == "computed":
    ctx.add('[')
    if n.children.len > 1:
      genNode(ctx, n.children[1], 0)
    ctx.add(']')
    return

  genNode(ctx, n, -1)

proc genBlockStmts(ctx: var GenContext, children: seq[Node]) =
  for stmt in children:
    if stmt.isNil: continue
    genStmt(ctx, stmt)
    if stmt.kind == nkStatement:
      let isBlockStmt = stmt.children.len > 0 and stmt.children[0].kind == nkIdent and
        stmt.children[0].name in ["if", "for", "while", "do-while", "switch", "try",
                                  "class", "function", "label"]
      if not isBlockStmt:
        if ctx.result.len > 0 and ctx.result[^1] != '}':
          ctx.add(';')
    elif stmt.kind == nkReturn or stmt.kind == nkImport:
      ctx.add(';')
    elif stmt.kind == nkFunction:
      discard
    elif stmt.kind notin {nkBlock, nkEmpty, nkInlineComment, nkDocComment}:
      if ctx.result.len > 0 and ctx.result[^1] != '}':
        ctx.add(';')

proc generateJs*(node: Node, opts: JsGenOptions, sourceFile: string = "", sourceCode: string = ""): tuple[code: string, sourceMapRaw: string] =
  var ctx = GenContext(opts: opts)
  if opts.sourceMap and sourceFile.len > 0:
    ctx.sourceMap = newSourceMap(changeFileExt(splitFile(sourceFile).name, ".js"))
    discard ctx.sourceMap.addSource(sourceFile, sourceCode)
  if opts.mangle:
    ctx.mangler = newMangler()
    walkAndCollect(ctx.mangler, node)
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
    for n in program.nodes:
      if not n.isNil:
        walkAndCollect(ctx.mangler, n)
  for n in program.nodes:
    if n.isNil: continue
    genStmt(ctx, n)
    if n.kind == nkStatement:
      let isBlockStmt = n.children.len > 0 and n.children[0].kind == nkIdent and
        n.children[0].name in ["if", "for", "while", "do-while", "switch", "try",
                                "class", "function"]
      if not isBlockStmt:
        ctx.add(';')
    elif n.kind == nkReturn or n.kind == nkImport:
      ctx.add(';')
    elif n.kind notin {nkBlock, nkEmpty, nkFunction}:
      ctx.add(';')
  result.code = ctx.result
  if ctx.sourceMap != nil:
    result.sourceMapRaw = ctx.sourceMap.generate()
