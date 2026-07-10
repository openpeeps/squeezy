import pkg/sweetsyntax
import pkg/sweetsyntax/engine/[ast, parser]
import sweetsyntax/[config, sweetlexer, tokenizer]
import sweetsyntax/languages/js
import pkg/openparser/css

proc validateJs*(code: string): seq[string] =
  try:
    let syntax = getKnownSyntax(KnownSyntax.js)
    var p = compile(syntax.spec)
    jsHandlers(p)
    p.features = {featAsync, featArrowFn, featGenerators, featTemplateLit, featLabeledStmt}
    p.lexer = initLexer(syntax.spec, code)
    p.curr = p.getToken()
    p.next = p.getToken()
    var program = OpenAstProgram()
    while p.curr.kind != tkEOF:
      program.nodes.add(parseStatement(p))
  except OpenAstParsingError as e:
    result.add(e.msg)

proc validateCss*(code: string): seq[string] =
  try:
    let style = parseCss(code)
    let data = loadCssData()
    let results = validateStyleSheet(data, style)
    for r in results:
      if not r.valid:
        for e in r.errors:
          result.add(e.message)
  except:
    result.add("CSS parsing error")

proc validate*(code: string, fileType: string): seq[string] =
  case fileType
  of "js", "jsx", "ts", "tsx", "mjs", "cjs":
    result = validateJs(code)
  of "css":
    result = validateCss(code)
  else:
    result.add("Unknown file type: " & fileType)
