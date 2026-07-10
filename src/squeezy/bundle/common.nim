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
    preserveComments*: bool

proc defaultConfig*: BundleConfig =
  BundleConfig(minify: true)

proc defaultJsGenOpts*: JsGenOptions =
  JsGenOptions(minify: true)
