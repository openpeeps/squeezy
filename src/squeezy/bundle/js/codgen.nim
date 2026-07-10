# A dead simple JavaScript and CSS validator, bundler and minifier
#
# (c) 2025 George Lemon | LGPL-v3 License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/squeezy

import std/strutils
import sweetsyntax/engine/ast
import ../common
import ./mangler

type
  GenContext = object
    result: string
    opts: JsGenOptions
    mangler: Mangler

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
      ctx.result.add(',')
    genNode(ctx, nodes[i], PrecAssign, "comma")

proc genThenElse(ctx: var GenContext, body: Node) =
  if body.kind == nkBlock:
    genNode(ctx, body, -1)
  else:
    genStmt(ctx, body)

proc genObjLiteral(ctx: var GenContext, n: Node) =
  ctx.result.add('{')
  for i, child in n.children:
    if i > 0:
      ctx.result.add(',')
    case child.kind
    of nkColonExpr:
      let key = child.children[0]
      let val = child.children[1]
      if key.kind == nkLitString:
        ctx.result.add(key.valStr)
      elif key.kind == nkIdent:
        let keyName = key.name
        if val.kind == nkFunction:
          let fnChildren = val.children
          if fnChildren.len >= 3 and fnChildren[0].kind == nkEmpty:
            if keyName.len > 0:
              ctx.result.add(keyName)
            genNode(ctx, val)
          else:
            ctx.result.add(keyName)
            ctx.result.add(':')
            genNode(ctx, val, PrecAssign)
        else:
          ctx.result.add(keyName)
          ctx.result.add(':')
          genNode(ctx, val, PrecAssign)
      elif key.kind == nkBracketExpr:
        ctx.result.add('[')
        genNode(ctx, key.children[0], 0)
        ctx.result.add(']')
        ctx.result.add(':')
        genNode(ctx, val, PrecAssign)
      else:
        genNode(ctx, key)
        ctx.result.add(':')
        genNode(ctx, val, PrecAssign)
    of nkCall:
      if child.children.len > 0 and child.children[0].kind == nkIdent and
         child.children[0].name == "spread":
        ctx.result.add("...")
        if child.children.len > 1:
          genNode(ctx, child.children[1], PrecAssign)
    of nkFunction:
      genNode(ctx, child)
    else:
      genNode(ctx, child, PrecAssign)
  ctx.result.add('}')

proc genFn(ctx: var GenContext, n: Node) =
  let children = n.children
  let isArrow = children.len >= 1 and children[0].kind == nkEmpty
  if not isArrow:
    if children.len >= 1 and children[0].kind == nkIdent:
      ctx.result.add("function")
    if children.len >= 2 and children[1].kind == nkIdent and children[1].name == "*":
      ctx.result.add('*')
    if children.len >= 3 and children[2].kind == nkIdent:
      ctx.result.add(' ')
      ctx.result.add(children[2].name)
    if children.len >= 4 and children[3].kind == nkIdentDefs and
       children[3].children.len > 0:
      ctx.result.add('<')
      genExprList(ctx, children[3].children, 0)
      ctx.result.add('>')
    ctx.result.add('(')
    if children.len >= 5 and children[4].kind == nkIdentDefs:
      genExprList(ctx, children[4].children, 0)
    ctx.result.add(')')
    let bodyIdx = if children.len >= 7: 6 else: children.len - 1
    if bodyIdx < children.len:
      let body = children[bodyIdx]
      if body.kind == nkBlock:
        ctx.result.add('{')
        genBlockStmts(ctx, body.children)
        ctx.result.add('}')
      elif body.kind == nkEmpty:
        discard
      else:
        ctx.result.add('{')
        genStmt(ctx, body)
        ctx.result.add('}')
  else:
    let paramsIdx = 1
    let bodyIdx = 2
    if paramsIdx < children.len and children[paramsIdx].kind == nkIdentDefs:
      let params = children[paramsIdx]
      if params.children.len == 1:
        genNode(ctx, params.children[0], PrecAssign)
      else:
        ctx.result.add('(')
        genExprList(ctx, params.children, 0)
        ctx.result.add(')')
    ctx.result.add("=>")
    if bodyIdx < children.len:
      let body = children[bodyIdx]
      if body.kind == nkBlock:
        if body.children.len == 1:
          genStmt(ctx, body.children[0])
        else:
          ctx.result.add('{')
          genBlockStmts(ctx, body.children)
          ctx.result.add('}')
      elif body.kind == nkEmpty:
        discard
      else:
        genNode(ctx, body, PrecAssign)

proc genNode(ctx: var GenContext, n: Node, parentPrec: int = -1, parentOp: string = "", isLhs: bool = true) =
  if n.isNil:
    return
  case n.kind
  of nkEmpty: discard
  of nkNil: ctx.result.add("null")
  of nkLitBool: ctx.result.add(if n.valBool: "true" else: "false")
  of nkLitInt: ctx.result.add($n.valInt)
  of nkLitFloat:
    let s = $n.valFloat
    ctx.result.add(s)
  of nkLitString:
    let raw = n.valStr
    let inner = if raw.len >= 2 and (raw[0] == '"' or raw[0] == '\''):
      raw[1..^2] else: raw
    ctx.result.add('"')
    for c in inner:
      case c
      of '\n': ctx.result.add("\\n")
      of '\r': ctx.result.add("\\r")
      of '\t': ctx.result.add("\\t")
      of '"': ctx.result.add("\\\"")
      of '\\': ctx.result.add("\\\\")
      else: ctx.result.add(c)
    ctx.result.add('"')
  of nkLitBigInt: ctx.result.add(n.valBigInt & "n")
  of nkIdent:
    let name = if ctx.mangler != nil: ctx.mangler.getMangled(n.name) else: n.name
    ctx.result.add(name)
  of nkVarTy: ctx.result.add(n.name)
  of nkRegex:
    if n.children.len > 0 and n.children[0].kind == nkLitString:
      ctx.result.add(n.children[0].valStr)
  of nkInlineComment:
    if ctx.opts.preserveComments:
      ctx.result.add("//" & n.children[0].valStr)
  of nkDocComment:
    if ctx.opts.preserveComments:
      ctx.result.add("/*" & n.children[0].valStr & "*/")
  of nkPrefix:
    let opName = if n.children.len > 0 and n.children[0].kind == nkIdent: n.children[0].name else: ""
    let operand = if n.children.len > 1: n.children[1] else: nil
    if opName == "spread":
      ctx.result.add("...")
      if not operand.isNil:
        genNode(ctx, operand, PrecAssign)
    elif opName == "await":
      ctx.result.add("await ")
      if not operand.isNil:
        genNode(ctx, operand, PrecPrefix)
    else:
      let addSpace = opName in ["typeof", "void", "delete", "new"]
      ctx.result.add(opName)
      if addSpace and not operand.isNil:
        if operand.kind in {nkLitInt, nkLitFloat, nkLitString, nkLitBool, nkNil}:
          ctx.result.add(' ')
        elif operand.kind == nkPrefix:
          ctx.result.add(' ')
      if not operand.isNil:
        let wrap = operand.kind == nkInfix or (operand.kind == nkCall and opName == "new")
        if wrap:
          ctx.result.add('(')
          genNode(ctx, operand, 0)
          ctx.result.add(')')
        else:
          genNode(ctx, operand, PrecPrefix)
  of nkPostfix:
    if n.children.len >= 2:
      genNode(ctx, n.children[0], PrecPostfix, "", true)
      if n.children[1].kind == nkIdent:
        ctx.result.add(n.children[1].name)
  of nkInfix:
    if n.children.len >= 3 and n.children[0].kind == nkIdent:
      let op = n.children[0].name
      let lhs = n.children[1]
      let rhs = n.children[2]
      let prec = getPrec(op)
      if prec >= 0:
        if op == "=" or op.endsWith("="):
          genNode(ctx, lhs, prec, op, false)
          ctx.result.add(op)
          genNode(ctx, rhs, prec, op, true)
        else:
          let wrapLhs = lhs.kind == nkInfix and lhs.children.len >= 3 and
            lhs.children[0].kind == nkIdent and
            needsParens(getPrec(lhs.children[0].name), prec, op, false)
          let wrapRhs = rhs.kind == nkInfix and rhs.children.len >= 3 and
            rhs.children[0].kind == nkIdent and
            needsParens(getPrec(rhs.children[0].name), prec, op, true)
          if wrapLhs:
            ctx.result.add('(')
            genNode(ctx, lhs, 0)
            ctx.result.add(')')
          else:
            genNode(ctx, lhs, prec, op, false)
          if op == "**":
            ctx.result.add(op)
          else:
            ctx.result.add(op)
          if wrapRhs:
            ctx.result.add('(')
            genNode(ctx, rhs, 0)
            ctx.result.add(')')
          else:
            genNode(ctx, rhs, prec, op, true)
      else:
        genNode(ctx, lhs, PrecAssign)
        if op[0] in {'a'..'z', 'A'..'Z'}:
          ctx.result.add(' ')
          ctx.result.add(op)
          ctx.result.add(' ')
        else:
          ctx.result.add(op)
        genNode(ctx, rhs, PrecAssign)
  of nkDotExpr:
    if n.children.len >= 2:
      genNode(ctx, n.children[0], PrecMember, ".")
      ctx.result.add('.')
      if n.children[1].kind == nkIdent:
        ctx.result.add(n.children[1].name)
      else:
        genNode(ctx, n.children[1], PrecMember)
  of nkBracketExpr:
    if n.children.len >= 2:
      let first = n.children[0]
      if first.kind in {nkIdent, nkDotExpr, nkCall, nkBracketExpr, nkFunction, nkInfix}:
        genNode(ctx, first, PrecMember - 1, "[")
        ctx.result.add('[')
        genExprList(ctx, n.children, 1)
        ctx.result.add(']')
      else:
        ctx.result.add('[')
        genExprList(ctx, n.children, 0)
        ctx.result.add(']')
    elif n.children.len == 1:
      ctx.result.add('[')
      genNode(ctx, n.children[0], 0)
      ctx.result.add(']')
    else:
      ctx.result.add("[]")
  of nkColonExpr:
    if n.children.len >= 2:
      genNode(ctx, n.children[0], PrecAssign)
      ctx.result.add(':')
      genNode(ctx, n.children[1], PrecAssign)
  of nkCall:
    if n.children.len > 0 and n.children[0].kind == nkIdent:
      if n.children[0].name == "ternary":
        if n.children.len >= 4:
          genNode(ctx, n.children[1], PrecCond)
          ctx.result.add('?')
          genNode(ctx, n.children[2], PrecCond)
          ctx.result.add(':')
          genNode(ctx, n.children[3], PrecCond - 1)
        return
      elif n.children[0].name == "spread":
        ctx.result.add("...")
        if n.children.len > 1:
          genNode(ctx, n.children[1], PrecAssign)
        return
    if n.children.len > 0:
      genNode(ctx, n.children[0], PrecCall, "(")
    ctx.result.add('(')
    if n.children.len > 1:
      genExprList(ctx, n.children, 1)
    ctx.result.add(')')
  of nkReturn:
    ctx.result.add("return")
    if n.children.len > 0:
      ctx.result.add(' ')
      genNode(ctx, n.children[0], PrecAssign)
  of nkImport:
    if n.children.len == 0:
      ctx.result.add("import")
    elif n.children.len == 2 and n.children[0].kind == nkEmpty and
         n.children[1].kind == nkLitString:
      ctx.result.add("import ")
      genNode(ctx, n.children[1], PrecAssign)
    elif n.children.len >= 2 and n.children[0].kind == nkEmpty and
         n.children[1].kind == nkIdentDefs:
      ctx.result.add("import {")
      genExprList(ctx, n.children[1].children, 0)
      ctx.result.add("}")
      if n.children.len >= 3 and n.children[2].kind == nkLitString:
        ctx.result.add(" from ")
        genNode(ctx, n.children[2], PrecAssign)
    elif n.children.len >= 2 and n.children[0].kind == nkEmpty and
         (n.children[1].kind == nkPrefix or
          (n.children[1].kind == nkInfix and n.children[1].children.len >= 3 and
           n.children[1].children[0].kind == nkIdent and
           n.children[1].children[0].name == "as")):
      ctx.result.add("import ")
      genNode(ctx, n.children[1], PrecAssign)
      if n.children.len >= 3 and n.children[2].kind == nkLitString:
        ctx.result.add(" from ")
        genNode(ctx, n.children[2], PrecAssign)
    elif n.children.len >= 2 and n.children[0].kind == nkIdent and
         n.children[1].kind == nkLitString:
      ctx.result.add("import ")
      genNode(ctx, n.children[0], PrecAssign)
      ctx.result.add(" from ")
      genNode(ctx, n.children[1], PrecAssign)
    elif n.children.len >= 2 and n.children[0].kind == nkIdent:
      ctx.result.add("import ")
      genNode(ctx, n.children[0], PrecAssign)
      if n.children.len >= 2 and n.children[1].kind == nkIdentDefs:
        ctx.result.add(", {")
        genExprList(ctx, n.children[1].children, 0)
        ctx.result.add("}")
        if n.children.len >= 3 and n.children[2].kind == nkLitString:
          ctx.result.add(" from ")
          genNode(ctx, n.children[2], PrecAssign)
      elif n.children.len >= 2 and
           (n.children[1].kind == nkPrefix or
            (n.children[1].kind == nkInfix and n.children[1].children.len >= 3 and
             n.children[1].children[0].kind == nkIdent and
             n.children[1].children[0].name == "as")):
        ctx.result.add(", ")
        genNode(ctx, n.children[1], PrecAssign)
        if n.children.len >= 3 and n.children[2].kind == nkLitString:
          ctx.result.add(" from ")
          genNode(ctx, n.children[2], PrecAssign)
      else:
        for i in 1 ..< n.children.len:
          ctx.result.add(',')
          ctx.result.add(' ')
          genNode(ctx, n.children[i], PrecAssign)
    else:
      ctx.result.add("import ")
      for i, child in n.children:
        if i > 0: ctx.result.add(',')
        ctx.result.add(' ')
        genNode(ctx, child, PrecAssign)
  of nkInclude:
    ctx.result.add("include")
    if n.children.len > 0:
      ctx.result.add(' ')
      genNode(ctx, n.children[0], PrecAssign)
  of nkFunction:
    genFn(ctx, n)
  of nkVar:
    ctx.result.add("var")
    for i, child in n.children:
      if i > 0: ctx.result.add(',')
      ctx.result.add(' ')
      genNode(ctx, child, PrecAssign)
  of nkBlock:
    if isObjLiteral(n):
      genObjLiteral(ctx, n)
    else:
      ctx.result.add('{')
      genBlockStmts(ctx, n.children)
      ctx.result.add('}')
  of nkStatement:
    genStmt(ctx, n)
  of nkIdentDefs:
    for i, child in n.children:
      if i == 0:
        genNode(ctx, child, PrecAssign)
      elif i == 1 and child.kind != nkEmpty:
        ctx.result.add(':')
        genNode(ctx, child, PrecAssign)
      elif i == 2 and child.kind != nkEmpty:
        ctx.result.add('=')
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
    genNode(ctx, n, -1, "", true)
    return
  if n.children.len == 0:
    return
  let kwNode = n.children[0]
  if kwNode.kind != nkIdent:
    genNode(ctx, n, -1)
    return
  let kw = kwNode.name

  if kw == "var" or kw == "let" or kw == "const":
    ctx.result.add(kw)
    for i in 1 ..< n.children.len:
      if i > 1: ctx.result.add(',')
      ctx.result.add(' ')
      genNode(ctx, n.children[i], PrecAssign)
    return

  if kw == "if":
    ctx.result.add("if(")
    if n.children.len > 1:
      genNode(ctx, n.children[1], PrecAssign)
    ctx.result.add(')')
    if n.children.len > 2:
      genThenElse(ctx, n.children[2])
    var i = 3
    while i < n.children.len:
      let clause = n.children[i]
      i += 1
      if clause.kind == nkBlock or (clause.kind == nkStatement and
         clause.children.len > 0 and clause.children[0].kind == nkIdent and
         clause.children[0].name == "else"):
        ctx.result.add("else")
        let body = if clause.kind == nkBlock: clause
                   elif clause.children.len > 1: clause.children[1]
                   else: Node(kind: nkEmpty)
        genThenElse(ctx, body)
        break
      else:
        ctx.result.add("else if(")
        genNode(ctx, clause, PrecAssign)
        ctx.result.add(')')
        if i < n.children.len:
          genThenElse(ctx, n.children[i])
          i += 1
    return

  if kw == "while":
    ctx.result.add("while(")
    if n.children.len > 1:
      genNode(ctx, n.children[1], PrecAssign)
    ctx.result.add(')')
    if n.children.len > 2:
      let body = n.children[2]
      if body.kind == nkBlock:
        genNode(ctx, body, -1)
      else:
        genStmt(ctx, body)
    return

  if kw == "do-while":
    ctx.result.add("do")
    if n.children.len > 1:
      let body = n.children[1]
      if body.kind == nkBlock:
        genNode(ctx, body, -1)
      else:
        genStmt(ctx, body)
    ctx.result.add("while(")
    if n.children.len > 2:
      genNode(ctx, n.children[2], PrecAssign)
    ctx.result.add(')')
    return

  if kw == "for":
    ctx.result.add("for(")
    if n.children.len > 1:
      let init = n.children[1]
      if init.kind == nkStatement:
        genStmt(ctx, init)
      elif init.kind == nkEmpty:
        discard
      else:
        genNode(ctx, init, PrecAssign)
    ctx.result.add(';')
    if n.children.len > 2:
      genNode(ctx, n.children[2], PrecAssign)
    ctx.result.add(';')
    if n.children.len > 3:
      genNode(ctx, n.children[3], PrecAssign)
    ctx.result.add(')')
    if n.children.len > 4:
      let body = n.children[4]
      if body.kind == nkBlock:
        genNode(ctx, body, -1)
      else:
        genStmt(ctx, body)
    return

  if kw == "switch":
    ctx.result.add("switch(")
    if n.children.len > 1:
      genNode(ctx, n.children[1], PrecAssign)
    ctx.result.add(')')
    if n.children.len > 2:
      let body = n.children[2]
      ctx.result.add('{')
      for caseNode in body.children:
        if caseNode.kind == nkStatement and caseNode.children.len > 0 and
           caseNode.children[0].kind == nkIdent:
          let caseKw = caseNode.children[0].name
          if caseKw == "case":
            ctx.result.add("case ")
            if caseNode.children.len > 1:
              genNode(ctx, caseNode.children[1], PrecAssign)
            ctx.result.add(':')
            for i in 2 ..< caseNode.children.len:
              genStmt(ctx, caseNode.children[i])
          elif caseKw == "default":
            ctx.result.add("default:")
            for i in 1 ..< caseNode.children.len:
              genStmt(ctx, caseNode.children[i])
        else:
          genStmt(ctx, caseNode)
      ctx.result.add('}')
    return

  if kw == "try":
    ctx.result.add("try")
    for i in 1 ..< n.children.len:
      let clause = n.children[i]
      if clause.kind == nkStatement and clause.children.len > 0 and
         clause.children[0].kind == nkIdent:
        let clauseKw = clause.children[0].name
        if clauseKw == "except":
          ctx.result.add("catch")
          if clause.children.len > 2 and clause.children[1].kind == nkIdent:
            ctx.result.add('(')
            genNode(ctx, clause.children[1], PrecAssign)
            ctx.result.add(')')
          elif clause.children.len > 1:
            let catchBody = clause.children[clause.children.len - 1]
            if catchBody.kind != nkBlock:
              ctx.result.add("(...)")
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
    ctx.result.add("class")
    if n.children.len > 1 and n.children[1].kind == nkIdent:
      ctx.result.add(' ')
      ctx.result.add(n.children[1].name)
    if n.children.len > 2 and n.children[2].kind != nkEmpty:
      ctx.result.add(" extends ")
      genNode(ctx, n.children[2], PrecMember)
    if n.children.len > 3:
      let body = n.children[3]
      if body.kind == nkBlock:
        ctx.result.add('{')
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
                  ctx.result.add(key.name)
                  ctx.result.add(':')
                  genNode(ctx, val, PrecAssign)
              else:
                ctx.result.add(key.name)
                if val.kind != nkEmpty:
                  ctx.result.add(':')
                  genNode(ctx, val, PrecAssign)
            elif key.kind == nkLitString:
              ctx.result.add(key.valStr)
              ctx.result.add(':')
              genNode(ctx, val, PrecAssign)
        ctx.result.add('}')
    return

  if kw == "export":
    ctx.result.add("export")
    if n.children.len > 1:
      let inner = n.children[1]
      if inner.kind == nkIdent and inner.name == "default":
        ctx.result.add(" default ")
        if n.children.len > 2:
          genNode(ctx, n.children[2], PrecAssign)
      elif inner.kind == nkIdentDefs:
        ctx.result.add(" {")
        genExprList(ctx, inner.children, 0)
        ctx.result.add("}")
        if n.children.len > 2 and n.children[2].kind == nkLitString:
          ctx.result.add(" from ")
          genNode(ctx, n.children[2], PrecAssign)
      elif inner.kind == nkPrefix or
           (inner.kind == nkInfix and inner.children.len >= 3 and
            inner.children[0].kind == nkIdent and
            inner.children[0].name == "as"):
        ctx.result.add(' ')
        genNode(ctx, inner, PrecAssign)
        if n.children.len > 2 and n.children[2].kind == nkLitString:
          ctx.result.add(" from ")
          genNode(ctx, n.children[2], PrecAssign)
      elif inner.kind == nkIdent and inner.name == "*":
        ctx.result.add(" *")
        if n.children.len > 2 and n.children[2].kind == nkLitString:
          ctx.result.add(" from ")
          genNode(ctx, n.children[2], PrecAssign)
      elif inner.kind in {nkFunction, nkStatement}:
        ctx.result.add(' ')
        genNode(ctx, inner, PrecAssign)
      else:
        ctx.result.add(' ')
        genNode(ctx, inner, PrecAssign)
    return

  if kw == "label":
    if n.children.len > 1:
      genNode(ctx, n.children[1], -1)
    ctx.result.add(':')
    if n.children.len > 2:
      genStmt(ctx, n.children[2])
    return

  if kw == "break":
    ctx.result.add("break")
    if n.children.len > 1:
      ctx.result.add(' ')
      genNode(ctx, n.children[1], PrecAssign)
    return

  if kw == "continue":
    ctx.result.add("continue")
    if n.children.len > 1:
      ctx.result.add(' ')
      genNode(ctx, n.children[1], PrecAssign)
    return

  if kw == "throw":
    ctx.result.add("throw")
    if n.children.len > 1:
      ctx.result.add(' ')
      genNode(ctx, n.children[1], PrecAssign)
    return

  if kw == "debugger":
    ctx.result.add("debugger")
    return

  if kw == "comma":
    for i in 1 ..< n.children.len:
      if i > 1: ctx.result.add(',')
      genNode(ctx, n.children[i], PrecAssign)
    return

  if kw == "function":
    genNode(ctx, n.children[1], -1)
    return

  if kw == "computed":
    ctx.result.add('[')
    if n.children.len > 1:
      genNode(ctx, n.children[1], 0)
    ctx.result.add(']')
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
          ctx.result.add(';')
    elif stmt.kind == nkReturn or stmt.kind == nkImport:
      ctx.result.add(';')
    elif stmt.kind == nkFunction:
      discard
    elif stmt.kind notin {nkBlock, nkEmpty, nkInlineComment, nkDocComment}:
      if ctx.result.len > 0 and ctx.result[^1] != '}':
        ctx.result.add(';')

proc generateJs*(node: Node, opts: JsGenOptions): string =
  var ctx = GenContext(opts: opts)
  if opts.mangle:
    ctx.mangler = newMangler()
    walkAndCollect(ctx.mangler, node)
  genNode(ctx, node, -1)
  ctx.result

proc generateJs*(program: OpenAstProgram, opts: JsGenOptions): string =
  var ctx = GenContext(opts: opts)
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
        ctx.result.add(';')
    elif n.kind == nkReturn or n.kind == nkImport:
      ctx.result.add(';')
    elif n.kind notin {nkBlock, nkEmpty, nkFunction}:
      ctx.result.add(';')
  ctx.result
