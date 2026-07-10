# A dead simple HTML, CSS and JS minifier.
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
  let jsPath = "examples/sample.js"
  let cssPath = "examples/sample.css"

  echo "=== Squeezy Bundler ==="
  echo ""

  if fileExists(jsPath):
    let jsMin = minifyFile(jsPath)
    writeFile("examples/sample.min.js", jsMin)
    echo "[JS]  " & jsPath & " -> examples/sample.min.js"
    echo "      " & $jsMin.len & " bytes (was " & $readFile(jsPath).len & " bytes)"
    echo ""
  else:
    echo "[JS]  " & jsPath & " not found, skipping"
    echo ""

  if fileExists(cssPath):
    let cssMin = minifyFile(cssPath)
    writeFile("examples/sample.min.css", cssMin)
    echo "[CSS] " & cssPath & " -> examples/sample.min.css"
    echo "      " & $cssMin.len & " bytes (was " & $readFile(cssPath).len & " bytes)"
    echo ""
  else:
    echo "[CSS] " & cssPath & " not found, skipping"
    echo ""

  echo "Done."
