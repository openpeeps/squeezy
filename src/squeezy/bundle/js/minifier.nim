# A dead simple JavaScript and CSS validator, bundler and minifier
#
# (c) 2025 George Lemon | LGPL-v3 License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/squeezy

import pkg/sweetsyntax
import pkg/sweetsyntax/engine/[ast, parser]
import pkg/sweetsyntax/[config, sweetlexer, tokenizer]
import pkg/sweetsyntax/languages/js

import ../common
import ./codgen

proc parseJsString*(code: string): OpenAstProgram =
  let syntax = getKnownSyntax(KnownSyntax.js)
  var p = compile(syntax.spec)
  jsHandlers(p)
  p.features = {featAsync, featArrowFn, featGenerators, featTemplateLit, featLabeledStmt}
  p.lexer = initLexer(syntax.spec, code)
  p.curr = p.getToken()
  p.next = p.getToken()
  result = OpenAstProgram()
  while p.curr.kind != tkEOF:
    result.nodes.add(parseStatement(p))

proc minifyJs*(code: string, opts: JsGenOptions = defaultJsGenOpts()): string =
  let program = parseJsString(code)
  result = generateJs(program, opts)
