import std/[os, strutils]
import squeezy/bundle/common
import squeezy/bundle/js/minifier as jsminifier
import squeezy/minify/inlinejs

proc main() =
  let mode = if paramCount() > 0: paramStr(1) else: "inline"
  let code = stdin.readAll()
  case mode
  of "inline":
    stdout.write(minifyInlineJS(code))
  of "bundle":
    let opts = JsGenOptions(minify: true)
    stdout.write(jsminifier.minifyJs(code, opts).code)
  of "bundle+mangle":
    let opts = JsGenOptions(minify: true, mangle: true)
    stdout.write(jsminifier.minifyJs(code, opts).code)
  else:
    stderr.writeLine("usage: bench_runner <inline|bundle|bundle+mangle>")
    quit(1)

when isMainModule:
  main()
