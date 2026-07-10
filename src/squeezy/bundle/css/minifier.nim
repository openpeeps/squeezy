import std/[strutils, sequtils]
import pkg/openparser/css
import ../common

proc shortenHexColor(hex: string): string =
  if hex.len == 6:
    if hex[0] == hex[1] and hex[2] == hex[3] and hex[4] == hex[5]:
      return hex[0..0] & hex[2..2] & hex[4..4]
  result = hex

proc optimizeCssAst(style: var CssStyleSheet)

proc optimizeCssNode(node: var CssNode)

proc optimizeCssValue(val: var CssValue)

proc optimizeCssValue(val: var CssValue) =
  case val.kind
  of cvkDimension:
    if val.dimValue == "0" or val.dimFloat == 0.0:
      if val.dimUnit notin ["s", "ms", "deg", "rad", "grad", "turn", "hz", "khz", "dpi", "dpcm", "dppx"]:
        val = CssValue(kind: cvkNumber, numValue: "0", numFloat: 0.0)
    else:
      if '.' in val.dimValue and val.dimValue.endsWith('0'):
        var trimmed = val.dimValue
        while trimmed.len > 1 and trimmed[^1] == '0':
          trimmed.setLen(trimmed.len - 1)
        if trimmed[^1] == '.':
          trimmed.setLen(trimmed.len - 1)
        if trimmed.len > 0:
          val.dimValue = trimmed
  of cvkNumber:
    if '.' in val.numValue and val.numValue.endsWith('0'):
      var trimmed = val.numValue
      while trimmed.len > 1 and trimmed[^1] == '0':
        trimmed.setLen(trimmed.len - 1)
      if trimmed[^1] == '.':
        trimmed.setLen(trimmed.len - 1)
      if trimmed.len > 0:
        val.numValue = trimmed
  of cvkPercentage:
    if val.pctValue == "0" or val.pctFloat == 0.0:
      val.pctValue = "0%"
    else:
      if '.' in val.pctValue and val.pctValue.endsWith('0'):
        var trimmed = val.pctValue
        while trimmed.len > 1 and trimmed[^1] == '0':
          trimmed.setLen(trimmed.len - 1)
        if trimmed[^1] == '.':
          trimmed.setLen(trimmed.len - 1)
        if trimmed.len > 0:
          val.pctValue = trimmed
  of cvkHash:
    val.hashValue = shortenHexColor(val.hashValue)
  of cvkFunction:
    for i in 0 ..< val.args.len:
      optimizeCssValue(val.args[i])
  of cvkBlock:
    for i in 0 ..< val.blockValues.len:
      optimizeCssValue(val.blockValues[i])
  else: discard

proc optimizeCssNode(node: var CssNode) =
  case node.kind
  of cssRuleSet:
    for decl in node.declarations.mitems:
      if decl.kind == cssDeclaration:
        for val in decl.valueComponents.mitems:
          optimizeCssValue(val)
        decl.rawValue = serializeComponentList(decl.valueComponents)
        if decl.property == "background" or decl.property == "background-color":
          if decl.rawValue.len > 0:
            discard
    if node.declarations.len == 0:
      node = CssNode(kind: cssComment, text: "")
  of cssAtRule:
    for child in node.atRules.mitems:
      optimizeCssNode(child)
  else: discard

proc optimizeCssAst(style: var CssStyleSheet) =
  for i in 0 ..< style.nodes.len:
    optimizeCssNode(style.nodes[i])
  style.nodes = style.nodes.filterIt(not (it.kind == cssComment and it.text == ""))

proc minifyCss*(code: string, opts: BundleConfig = defaultConfig()): string =
  var policy = defaultPolicy()
  policy.allowComments = not opts.minify
  var style = parseCss(code, policy)
  if opts.minify:
    optimizeCssAst(style)
  for node in style.nodes:
    result.add(toString(node, 0, CSSOpts(minify: opts.minify, preserveComments: opts.preserveComments)))
