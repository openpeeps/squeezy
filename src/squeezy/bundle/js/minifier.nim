# A dead simple JavaScript and CSS validator, bundler and minifier
#
# (c) 2025 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/squeezy

import pkg/sweetsyntax
import pkg/sweetsyntax/engine/[ast, parser]
import pkg/sweetsyntax/[sweetlexer, tokenizer]
import pkg/sweetsyntax/languages/js
import pkg/sweetsyntax/languages/prepared/js

import ../common
import ./codgen

var
  cachedParser: GenericParser
  parserReady: bool

proc getJsParser(): ptr GenericParser =
  if not parserReady:
    cachedParser.applyPrecompiled(jsInitData)
    jsHandlers(cachedParser)
    parserReady = true
  result = addr(cachedParser)

proc parseJsString*(code: string): OpenAstProgram =
  let p = getJsParser()
  p[].lexer = initLexer(jsInitData, code)
  p[].curr = p[].getToken()
  p[].next = p[].getToken()
  result = OpenAstProgram()
  result.nodes = newSeqOfCap[Node](code.len shr 5)
  while p[].curr.kind != tkEOF:
    let stmt = parseStatement(p[])
    if not stmt.isNil:
      result.nodes.add(stmt)

proc minifyJs*(code: string, opts: JsGenOptions = defaultJsGenOpts(), sourceFile: string = ""): tuple[code: string, sourceMapRaw: string] =
  let program = parseJsString(code)
  result = generateJs(program, opts, sourceFile, code)

proc minifyJsProgram*(program: OpenAstProgram, opts: JsGenOptions = defaultJsGenOpts()): tuple[code: string, sourceMapRaw: string] =
  ## Codegen for an already-parsed (possibly rewritten, e.g. by the
  ## bundler) program. No source map: rewritten nodes carry no positions.
  result = generateJs(program, opts)
