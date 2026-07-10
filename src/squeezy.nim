# A dead simple JavaScript and CSS validator, bundler and minifier
#
# (c) 2025 George Lemon | LGPL-v3 License
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

  var p = initOptParser()
  for kind, key, val in p.getopt():
    if kind == cmdLongOption:
      case key
      of "mangle": mangle = true
      else: discard

  let cfg = BundleConfig(minify: true, mangle: mangle)

  echo "=== Squeezy Bundler ==="
  if mangle: echo "    (identifier mangling enabled)"
  echo ""

  if fileExists(jsPath):
    let jsMin = minifyFile(jsPath, cfg)
    writeFile("examples/sample.min.js", jsMin)
    echo "[JS]  " & jsPath & " -> examples/sample.min.js"
    echo "      " & $jsMin.len & " bytes (was " & $readFile(jsPath).len & " bytes)"
    echo ""
  else:
    echo "[JS]  " & jsPath & " not found, skipping"
    echo ""

  if fileExists(cssPath):
    let cssMin = minifyFile(cssPath, cfg)
    writeFile("examples/sample.min.css", cssMin)
    echo "[CSS] " & cssPath & " -> examples/sample.min.css"
    echo "      " & $cssMin.len & " bytes (was " & $readFile(cssPath).len & " bytes)"
    echo ""
  else:
    echo "[CSS] " & cssPath & " not found, skipping"
    echo ""

  echo "Done."
