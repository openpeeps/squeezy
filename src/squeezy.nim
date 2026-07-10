# A dead simple JavaScript and CSS validator, bundler and minifier
#
# (c) 2025 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/squeezy

import ./squeezy/minify/[inlinehtml, inlinecss, inlinejs]
export inlinehtml, inlinecss, inlinejs

import std/os
import ./squeezy/bundle/bundler
export bundler

when isMainModule:
  import std/parseopt

  let jsPath = "examples/sample.js"
  let cssPath = "examples/sample.css"
  var mangle = false
  var sourcemap = false

  var p = initOptParser()
  for kind, key, val in p.getopt():
    if kind == cmdLongOption:
      case key
      of "mangle": mangle = true
      of "sourcemap": sourcemap = true
      else: discard

  let cfg = BundleConfig(minify: true, mangle: mangle, sourceMap: sourcemap)

  echo "=== Squeezy Bundler ==="
  if mangle: echo "    (identifier mangling enabled)"
  if sourcemap: echo "    (source maps enabled)"
  echo ""

  if fileExists(jsPath):
    let res = minifyFile(jsPath, cfg)
    writeFile("examples/sample.min.js", res.code)
    echo "[JS]  " & jsPath & " -> examples/sample.min.js"
    echo "      " & $res.code.len & " bytes (was " & $readFile(jsPath).len & " bytes)"
    if sourcemap and res.sourceMapRaw.len > 0:
      writeFile("examples/sample.min.js.map", res.sourceMapRaw)
      echo "      source map -> examples/sample.min.js.map (" & $res.sourceMapRaw.len & " bytes)"
    echo ""
  else:
    echo "[JS]  " & jsPath & " not found, skipping"
    echo ""

  if fileExists(cssPath):
    let cssResult = minifyWithSourceMap(readFile(cssPath), "css", cfg, "sample.css")
    let cssMin = cssResult.code
    writeFile("examples/sample.min.css", cssMin)
    echo "[CSS] " & cssPath & " -> examples/sample.min.css"
    echo "      " & $cssMin.len & " bytes (was " & $readFile(cssPath).len & " bytes)"
    echo ""
  else:
    echo "[CSS] " & cssPath & " not found, skipping"
    echo ""

  echo "Done."
