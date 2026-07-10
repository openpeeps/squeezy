# A dead simple JavaScript and CSS validator, bundler and minifier
#
# (c) 2025 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/squeezy

import std/[os, strutils]
import pkg/openparser/css
import ../common

proc bundleCss*(entryPoint: string, opts: BundleConfig): string =
  var visited: seq[string]
  var allCss: seq[string]

  proc processFile(path: string) =
    let absPath = path.absolutePath()
    if absPath in visited: return
    visited.add(absPath)
    let code = readFile(path)
    var policy = defaultPolicy()
    if not opts.preserveComments:
      policy.allowComments = false
    let stylesheet = parseCss(code, policy)
    for node in stylesheet.nodes:
      if node.kind == cssAtRule and node.atName == "import":
        let prelude = node.prelude.strip()
        var importPath = prelude
        if (importPath.startsWith("url(") or importPath.startsWith("url(")) and importPath.endsWith(")"):
          importPath = importPath[4..^2].strip().strip(chars = {'"', '\''})
        elif (importPath.startsWith("\"") or importPath.startsWith("'")) and
             (importPath.endsWith("\"") or importPath.endsWith("'")):
          importPath = importPath[1..^2]
        let resolved = path.parentDir() / importPath
        if resolved.len > 0 and fileExists(resolved):
          processFile(resolved)
      else:
        allCss.add(toString(node, 0, CSSOpts(minify: opts.minify, preserveComments: opts.preserveComments)))

  processFile(entryPoint)
  result = allCss.join(if opts.minify: "" else: "\n")
