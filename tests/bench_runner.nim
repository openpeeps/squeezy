import std/os
import squeezy/bundle/common
import squeezy/bundle/js/minifier as jsminifier
import squeezy/minify/inlinejs

proc minifyInline*(code: string): string =
  ## Old character-level minifier, no parsing.
  minifyInlineJS(code)

proc minifyBundle*(code: string): string =
  ## Full parse + codegen minifier.
  let opts = JsGenOptions(minify: true)
  jsminifier.minifyJs(code, opts).code

proc minifyBundleMangle*(code: string): string =
  ## Full minifier with bundle-wide mangling.
  let opts = JsGenOptions(minify: true, mangle: true)
  jsminifier.minifyJs(code, opts).code

proc main() =
  let mode = if paramCount() > 0: paramStr(1) else: "inline"
  let code = stdin.readAll()
  case mode
  of "inline":
    stdout.write(minifyInline(code))
  of "bundle":
    stdout.write(minifyBundle(code))
  of "bundle+mangle":
    stdout.write(minifyBundleMangle(code))
  else:
    stderr.writeLine("usage: bench_runner <inline|bundle|bundle+mangle>")
    quit(1)

when isMainModule:
  main()
