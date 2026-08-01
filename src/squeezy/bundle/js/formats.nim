# A dead simple JavaScript and CSS validator, bundler and minifier
#
# (c) 2025 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/squeezy

## Rollup-style output wrappers for the bundled JS.
## The inner `code` is expected to be already minified; wrappers are compact
## by construction so no additional minification pass is required.

import ../common
import ./exports

proc emitExports(exports: seq[ExportEntry]): string =
  ## Emit `exports.<name>=<local>;` lines. Default exports are surfaced as
  ## `exports.default=__default;`.
  result = ""
  for e in exports:
    result.add("exports.")
    result.add(e.exportedName)
    result.add("=")
    result.add(e.localName)
    result.add(";")

proc wrapBundle*(code: string, format: OutputFormat,
                 moduleName: string = "", exports: seq[ExportEntry] = @[]): string =
  ## Wrap the concatenated bundle `code` in the requested output format.
  let exportLines = emitExports(exports)

  case format
  of fmtES:
    result = code
  of fmtCJS:
    result = "'use strict';"
    result.add(code)
    if exportLines.len > 0:
      result.add(exportLines)
    result.add("module.exports=exports;")
  of fmtIIFE:
    let name = if moduleName.len > 0: "var " & moduleName & "=" else: ""
    result = name & "(function(exports){'use strict';"
    result.add(code)
    if exportLines.len > 0:
      result.add(exportLines)
    result.add("return exports;})({});")
  of fmtUMD:
    if moduleName.len == 0:
      result = "(function(global,factory){typeof exports==='object'&&typeof module!=='undefined'?factory(exports):typeof define==='function'&&define.amd?define(['exports'],factory):(global=typeof globalThis!=='undefined'?globalThis:global||self,factory(global));})(this,(function(exports){'use strict';"
    else:
      result = "(function(global,factory){typeof exports==='object'&&typeof module!=='undefined'?factory(exports):typeof define==='function'&&define.amd?define(['exports'],factory):(global=typeof globalThis!=='undefined'?globalThis:global||self,factory(global." & moduleName & "={}));})(this,(function(exports){'use strict';"
    result.add(code)
    if exportLines.len > 0:
      result.add(exportLines)
    result.add("return exports;}));")
  of fmtAMD:
    result = "define(['exports'],(function(exports){'use strict';"
    result.add(code)
    if exportLines.len > 0:
      result.add(exportLines)
    result.add("return exports;}));")
  of fmtSystem:
    result = "System.register([],(function(exports){'use strict';return{execute:(function(){"
    result.add(code)
    if exportLines.len > 0:
      result.add(exportLines)
    result.add("})};}));")
