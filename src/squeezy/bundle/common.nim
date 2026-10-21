# A dead simple JavaScript and CSS validator, bundler and minifier
#
# (c) 2025 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/squeezy

type
  OutputFormat* = enum
    fmtES = "es"        ## ES modules — native import/export preserved
    fmtCJS = "cjs"      ## CommonJS — module.exports / exports
    fmtIIFE = "iife"    ## Browser IIFE — var NAME = (function(exports){ ... })({})
    fmtUMD = "umd"      ## Universal — CJS/AMD/global factory wrapper
    fmtAMD = "amd"      ## AMD — define(['exports'], function(exports){ ... })
    fmtSystem = "system" ## SystemJS — System.register([], function(exports){ ... })

  BundleConfig* = object
    minify*: bool
    mangle*: bool
    bundle*: bool
    validate*: bool
    treeShake*: bool
    preserveComments*: bool
    sourceMap*: bool
    entryPoint*: string
    outputPath*: string
    format*: OutputFormat
      ## Output wrapper format for the bundled JS. Defaults to fmtES.
    moduleName*: string
      ## Global/module name for iife/umd wrappers.
      ## Defaults to the entry file basename when empty.
    externals*: seq[string]
      ## Bare specifiers left untouched (e.g. node builtins or
      ## packages provided by the host). Never resolved.
    nodePaths*: seq[string]
      ## Extra lookup roots checked before walked-up node_modules.

  JsGenOptions* = object
    minify*: bool
    mangle*: bool
    preserveComments*: bool
    sourceMap*: bool
    stripExports*: bool
      ## When true, codegen drops import/export statements and emits
      ## declarations without the `export` keyword (for wrapped formats).
    preserveNames*: seq[string]
      ## Identifiers the mangler must leave untouched, e.g. a bundle
      ## wrapper global (`--name`). Empty by default.

proc defaultConfig*: BundleConfig =
  BundleConfig(minify: true)

proc defaultJsGenOpts*: JsGenOptions =
  JsGenOptions(minify: true)

proc jsGenOptsWithMangle*: JsGenOptions =
  JsGenOptions(minify: true, mangle: true)
