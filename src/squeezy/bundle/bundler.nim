# A dead simple JavaScript and CSS validator, bundler and minifier
#
# (c) 2025 George Lemon | LGPL-v3 License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/squeezy

import std/[os, strutils]
import ./common
import ./js/[minifier as jsminifier, bundler as jsbundler]
import ./css/[minifier as cssminifier, bundler as cssbundler]
import ./validator
export common, validateJs, validateCss, validate

type
  MinifyResult* = object
    code*: string
    sourceMapRaw*: string

proc minify*(code: string, ext: string, opts: BundleConfig = defaultConfig()): string =
  case ext
  of "js", "jsx", "ts", "tsx", "mjs", "cjs":
    let jsOpts = JsGenOptions(minify: opts.minify, mangle: opts.mangle, preserveComments: opts.preserveComments, sourceMap: opts.sourceMap)
    result = jsminifier.minifyJs(code, jsOpts).code
  of "css":
    result = cssminifier.minifyCss(code, opts)
  else:
    result = code

proc minifyWithSourceMap*(code: string, ext: string, opts: BundleConfig = defaultConfig(), sourceFile: string = ""): MinifyResult =
  case ext
  of "js", "jsx", "ts", "tsx", "mjs", "cjs":
    let jsOpts = JsGenOptions(minify: opts.minify, mangle: opts.mangle, preserveComments: opts.preserveComments, sourceMap: opts.sourceMap)
    let res = jsminifier.minifyJs(code, jsOpts, sourceFile)
    result = MinifyResult(code: res.code, sourceMapRaw: res.sourceMapRaw)
  of "css":
    result = MinifyResult(code: cssminifier.minifyCss(code, opts))
  else:
    result = MinifyResult(code: code)

proc bundle*(entryPoint: string, opts: BundleConfig = defaultConfig()): string =
  let ext = entryPoint.splitFile().ext.strip(chars = {'.'})
  case ext
  of "js", "jsx", "ts", "tsx", "mjs", "cjs":
    result = jsbundler.bundleJs(entryPoint, opts)
  of "css":
    result = cssbundler.bundleCss(entryPoint, opts)
  else:
    result = readFile(entryPoint)

proc minifyFile*(path: string, opts: BundleConfig = defaultConfig()): MinifyResult =
  let code = readFile(path)
  let ext = path.splitFile().ext.strip(chars = {'.'})
  result = minifyWithSourceMap(code, ext, opts, extractFilename(path))

proc minifyAndBundle*(entryPoint: string, outputPath: string, opts: BundleConfig = defaultConfig()): string =
  result = bundle(entryPoint, opts)
  if outputPath.len > 0:
    writeFile(outputPath, result)
