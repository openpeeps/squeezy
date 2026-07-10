# A dead simple JavaScript and CSS validator, bundler and minifier
#
# (c) 2025 George Lemon | LGPL-v3 License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/squeezy

type
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

  JsGenOptions* = object
    minify*: bool
    mangle*: bool
    preserveComments*: bool

proc defaultConfig*: BundleConfig =
  BundleConfig(minify: true)

proc defaultJsGenOpts*: JsGenOptions =
  JsGenOptions(minify: true)

proc jsGenOptsWithMangle*: JsGenOptions =
  JsGenOptions(minify: true, mangle: true)
