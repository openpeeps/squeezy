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
  import std/[parseopt, strutils, syncio]

  const versionStr = "0.1.0"

  const
    ansiReset = "\e[0m"
    ansiBoldWhite = "\e[1;37m"
    ansiGrey = "\e[90m"
    ansiRed = "\e[31m"

  proc useColor(): bool =
    getEnv("NO_COLOR") == "" and getEnv("TERM") != "dumb"

  proc paint(s, code: string): string =
    if useColor():
      code & s & ansiReset
    else:
      s

  proc label(s: string): string =
    paint(s, ansiBoldWhite)

  proc grey(s: string): string =
    paint(s, ansiGrey)

  proc errPrefix(): string =
    paint("error:", ansiRed)

  proc warn(msg: string) =
    stderr.writeLine("warning: " & msg)

  proc printHelp() =
    echo grey("A dead simple JavaScript and CSS validator, bundler and minifier")
    echo grey("  (c) OpenPeeps | MIT License")
    echo grey("  Build Version: " & versionStr)
    echo ""
    echo "usage: squeezy <command> [args] [options]"
    echo ""
    echo label("Commands")
    echo "  css <input.css> [-o output]      " & grey("minify CSS, inlines @import")
    echo "  bundle <entry.js> [-o output]    " & grey("bundle JS, resolves imports")
    echo ""
    echo label("CSS options")
    echo "  -o, --out <file>                 " & grey("write to file instead of stdout")
    echo "      --preserve-comments          " & grey("keep comments")
    echo ""
    echo label("Bundle options")
    echo "  -o, --out <file>                 " & grey("write to file instead of stdout")
    echo "      --minify                     " & grey("minify JS output")
    echo "      --mangle                     " & grey("mangle JS identifiers, implies minify")
    echo "      --sourcemap                  " & grey("emit a source map next to output, es format only")
    echo "      --format <fmt>               " & grey("es, cjs, iife, umd, amd, system (default es)")
    echo "      --name <name>                " & grey("module name for iife and umd wrappers")
    echo "      --preserve-comments          " & grey("keep comments")
    echo ""
    echo "  -h, --help                       " & grey("show this help")
    echo "  --version                        " & grey("show version")
    echo ""
    echo grey("aliases: minify for css, js for bundle")
    echo grey("examples:")
    echo grey("  squeezy css styles.css -o styles.min.css")
    echo grey("  squeezy bundle app.js -o bundle.js --minify --mangle")

  proc printCssHelp() =
    echo grey("Minify CSS, inlines @import")
    echo ""
    echo "usage: squeezy css <input.css> [-o output] [options]"
    echo ""
    echo label("Options")
    echo "  -o, --out <file>         " & grey("write to file instead of stdout")
    echo "      --preserve-comments  " & grey("keep comments")
    echo ""
    echo "  -h, --help               " & grey("show this help")

  proc printBundleHelp() =
    echo grey("Bundle JS, resolves imports")
    echo ""
    echo "usage: squeezy bundle <entry.js> [-o output] [options]"
    echo ""
    echo label("Options")
    echo "  -o, --out <file>         " & grey("write to file instead of stdout")
    echo "      --minify             " & grey("minify JS output")
    echo "      --mangle             " & grey("mangle JS identifiers, implies minify")
    echo "      --sourcemap          " & grey("emit a source map next to output, es format only")
    echo "      --format <fmt>       " & grey("es, cjs, iife, umd, amd, system (default es)")
    echo "      --name <name>        " & grey("module name for iife and umd wrappers")
    echo "      --preserve-comments  " & grey("keep comments")
    echo ""
    echo "  -h, --help               " & grey("show this help")

  proc parseFormat(s: string, fmt: var OutputFormat): bool =
    case s.toLowerAscii
    of "es": fmt = fmtES; true
    of "cjs", "commonjs": fmt = fmtCJS; true
    of "iife": fmt = fmtIIFE; true
    of "umd": fmt = fmtUMD; true
    of "amd": fmt = fmtAMD; true
    of "system", "systemjs": fmt = fmtSystem; true
    else: false

  proc isJsExt(ext: string): bool =
    ext in ["js", "jsx", "ts", "tsx", "mjs", "cjs"]

  proc writeOutputFile(path, content: string): bool =
    try:
      let dir = path.parentDir()
      if dir.len > 0 and not dirExists(dir):
        createDir(dir)
      writeFile(path, content)
      result = true
    except IOError as e:
      echo errPrefix() & " " & e.msg
      result = false

  proc doCss(input, output: string, preserveComments: bool): int =
    if not fileExists(input):
      echo errPrefix() & " file not found: " & input
      return 1
    if input.splitFile().ext.toLowerAscii.strip(chars = {'.'}) != "css":
      echo errPrefix() & " css command expects a .css file: " & input
      return 1
    let origCode =
      try:
        readFile(input)
      except IOError as e:
        echo errPrefix() & " " & e.msg
        return 1
    let cfg = BundleConfig(minify: true, preserveComments: preserveComments)
    let code =
      try:
        bundle(input, cfg)
      except CatchableError as e:
        echo errPrefix() & " " & e.msg
        return 1
    if output.len > 0:
      if not writeOutputFile(output, code):
        return 1
      echo "css: " & input & " -> " & output &
        " (" & $code.len & " bytes, was " & $origCode.len & " bytes)"
    else:
      echo code
    return 0

  proc doBundle(entry, output: string, minifyFlag, mangleFlag,
      sourcemapFlag: bool, format: OutputFormat, moduleName: string,
      preserveComments: bool): int =
    if not fileExists(entry):
      echo errPrefix() & " file not found: " & entry
      return 1
    let ext = entry.splitFile().ext.toLowerAscii.strip(chars = {'.'})
    if ext != "css" and not isJsExt(ext):
      echo errPrefix() & " unsupported file type: " & entry &
        " (expected .js or .css)"
      return 1
    let doMinify = minifyFlag or mangleFlag
    var cfg = BundleConfig(minify: doMinify, mangle: mangleFlag,
      sourceMap: sourcemapFlag, format: format, moduleName: moduleName,
      preserveComments: preserveComments)
    if ext == "css" and format != fmtES:
      warn("--format ignored for CSS")
    if sourcemapFlag and ext == "css":
      warn("--sourcemap not supported for CSS, ignoring")
    var code = ""
    var map = ""
    if sourcemapFlag and isJsExt(ext) and format == fmtES:
      # raw bundle first, then a single minify pass so the map
      # covers the whole bundle instead of per-file fragments
      let rawCfg = BundleConfig(minify: false, preserveComments: preserveComments,
        format: fmtES)
      let raw =
        try:
          bundle(entry, rawCfg)
        except CatchableError as e:
          echo errPrefix() & " " & e.msg
          return 1
      let res =
        try:
          minifyWithSourceMap(raw, "js", cfg, extractFilename(entry))
        except CatchableError as e:
          echo errPrefix() & " " & e.msg
          return 1
      code = res.code
      map = res.sourceMapRaw
    else:
      if sourcemapFlag and isJsExt(ext) and format != fmtES:
        warn("--sourcemap only supported with es format, ignoring")
        cfg.sourceMap = false
      code =
        try:
          bundle(entry, cfg)
        except CatchableError as e:
          echo errPrefix() & " " & e.msg
          return 1
    let origLen =
      try:
        readFile(entry).len
      except IOError:
        code.len
    if output.len > 0:
      if not writeOutputFile(output, code):
        return 1
      echo "bundle: " & entry & " -> " & output &
        " (" & $code.len & " bytes, was " & $origLen & " bytes)"
      if map.len > 0:
        if not writeOutputFile(output & ".map", map):
          return 1
        echo "sourcemap: " & output & ".map (" & $map.len & " bytes)"
    else:
      if map.len > 0:
        warn("--sourcemap needs -o, ignoring")
      echo code
    return 0

  proc main(): int =
    var command = ""
    var positionals: seq[string] = @[]
    var output = ""
    var pending = ""
    var minifyFlag = false
    var mangleFlag = false
    var sourcemapFlag = false
    var preserveFlag = false
    var format = fmtES
    var moduleName = ""
    var showHelp = false
    var showVersion = false
    var p = initOptParser(commandLineParams())
    for kind, key, val in p.getopt():
      case kind
      of cmdArgument:
        if pending.len > 0:
          case pending
          of "out":
            output = key
          of "format":
            if not parseFormat(key, format):
              echo errPrefix() & " unknown format: " & key
              echo "  valid formats: es, cjs, iife, umd, amd, system"
              return 1
          of "name":
            moduleName = key
          else:
            discard
          pending = ""
        elif command == "":
          command = key
        else:
          positionals.add(key)
      of cmdLongOption, cmdShortOption:
        if pending.len > 0:
          echo errPrefix() & " option --" & pending & " requires a value"
          return 1
        case key
        of "help", "h":
          showHelp = true
        of "version":
          showVersion = true
        of "o", "out", "output":
          if val.len > 0:
            output = val
          else:
            pending = "out"
        of "minify":
          minifyFlag = val notin ["false", "0"]
        of "mangle":
          mangleFlag = val notin ["false", "0"]
        of "sourcemap", "source-map", "map":
          sourcemapFlag = val notin ["false", "0"]
        of "preserve-comments", "preserveComments", "keep-comments":
          preserveFlag = val notin ["false", "0"]
        of "format":
          if val.len > 0:
            if not parseFormat(val, format):
              echo errPrefix() & " unknown format: " & val
              echo "  valid formats: es, cjs, iife, umd, amd, system"
              return 1
          else:
            pending = "format"
        of "name":
          if val.len > 0:
            moduleName = val
          else:
            pending = "name"
        else:
          echo errPrefix() & " unknown option --" & key
          printHelp()
          return 1
      of cmdEnd:
        discard
    if pending.len > 0:
      echo errPrefix() & " option --" & pending & " requires a value"
      return 1
    if showVersion:
      echo versionStr
      return 0
    if command == "help":
      if positionals.len > 0:
        case positionals[0]
        of "css", "minify":
          printCssHelp()
          return 0
        of "bundle", "js":
          printBundleHelp()
          return 0
        else:
          echo errPrefix() & " unknown command `" & positionals[0] & "`"
          printHelp()
          return 1
      printHelp()
      return 0
    if showHelp:
      case command
      of "", "help":
        printHelp()
      of "css", "minify":
        printCssHelp()
      of "bundle", "js":
        printBundleHelp()
      else:
        printHelp()
      return 0
    if command == "":
      printHelp()
      return 0
    case command
    of "css", "minify":
      # minify a single CSS file, inlining @import
      if positionals.len == 0:
        echo errPrefix() & " input file is required"
        printCssHelp()
        return 1
      if positionals.len > 1:
        echo errPrefix() & " only one input file allowed"
        printCssHelp()
        return 1
      if minifyFlag or mangleFlag or sourcemapFlag or format != fmtES or moduleName.len > 0:
        warn("bundle-only options ignored for css")
      return doCss(positionals[0], output, preserveFlag)
    of "bundle", "js":
      # bundle a JS entry, optionally minified
      if positionals.len == 0:
        echo errPrefix() & " entry file is required"
        printBundleHelp()
        return 1
      if positionals.len > 1:
        echo errPrefix() & " only one entry file allowed"
        printBundleHelp()
        return 1
      return doBundle(positionals[0], output, minifyFlag, mangleFlag,
        sourcemapFlag, format, moduleName, preserveFlag)
    else:
      # default command: a bare file path dispatches by extension,
      # like dfkup running a bare script path
      if positionals.len == 0 and fileExists(command):
        let ext = command.splitFile().ext.toLowerAscii.strip(chars = {'.'})
        if ext == "css":
          return doCss(command, output, preserveFlag)
        if isJsExt(ext):
          return doBundle(command, output, minifyFlag, mangleFlag,
            sourcemapFlag, format, moduleName, preserveFlag)
      echo errPrefix() & " unknown command `" & command & "`"
      printHelp()
      return 1

  quit(main())
