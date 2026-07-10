import std/[os, strutils]
import ./common
import ./js/[minifier as jsminifier, bundler as jsbundler]
import ./css/[minifier as cssminifier, bundler as cssbundler]
import ./validator
export common, validateJs, validateCss, validate

proc minify*(code: string, ext: string, opts: BundleConfig = defaultConfig()): string =
  case ext
  of "js", "jsx", "ts", "tsx", "mjs", "cjs":
    result = jsminifier.minifyJs(code)
  of "css":
    result = cssminifier.minifyCss(code, opts)
  else:
    result = code

proc bundle*(entryPoint: string, opts: BundleConfig = defaultConfig()): string =
  let ext = entryPoint.splitFile().ext.strip(chars = {'.'})
  case ext
  of "js", "jsx", "ts", "tsx", "mjs", "cjs":
    result = jsbundler.bundleJs(entryPoint, opts)
  of "css":
    result = cssbundler.bundleCss(entryPoint, opts)
  else:
    result = readFile(entryPoint)

proc minifyFile*(path: string, opts: BundleConfig = defaultConfig()): string =
  let code = readFile(path)
  let ext = path.splitFile().ext.strip(chars = {'.'})
  result = minify(code, ext, opts)

proc minifyAndBundle*(entryPoint: string, outputPath: string, opts: BundleConfig = defaultConfig()): string =
  result = bundle(entryPoint, opts)
  if outputPath.len > 0:
    writeFile(outputPath, result)
