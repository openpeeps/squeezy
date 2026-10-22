import std/[unittest, os, strutils, osproc, times]
import bench_runner
import squeezy/bundle/common
import squeezy/bundle/js/minifier as jsmin
import sweetsyntax/engine/ast

# Benchmark corpus: d3.js v7.9.0 (unminified, ~20k lines), fetched from CDN
# on first run and cached under tests/data (gitignored). Cached copy wins
# so the suite stays offline-friendly once downloaded.
const corpusUrl = "https://cdnjs.cloudflare.com/ajax/libs/d3/7.9.0/d3.js"

let
  dataFile = currentSourcePath().parentDir() / "data" / "d3.js"
  outDir = currentSourcePath().parentDir() / "data"

proc ensureCorpus(): string =
  ## Returns "" when the corpus is ready, else a human-readable reason.
  if fileExists(dataFile):
    return ""
  try:
    createDir(outDir)
  except OSError as e:
    return "cannot create " & outDir & ": " & e.msg
  # curl ships on every GH runner OS (and macOS/Linux dev machines);
  # shelling out avoids linking OpenSSL into the test binary for one URL.
  let (o, c) = execCmdEx("curl -fsSL " & quoteShell(corpusUrl) &
    " -o " & quoteShell(dataFile))
  if c != 0:
    try:
      removeFile(dataFile)
    except OSError:
      discard
    return "corpus download failed (exit " & $c & "): " & o.strip()
  try:
    if getFileSize(dataFile) < 500_000:
      removeFile(dataFile)
      return "corpus download looks truncated, removed; retry test run"
  except OSError as e:
    return "cannot verify " & dataFile & ": " & e.msg
  ""

proc esbuildBin(): string =
  findExe("esbuild")

proc checkDependencies(): string =
  result = ensureCorpus()
  if result.len > 0:
    return result
  if not fileExists(dataFile):
    return "data file not found: " & dataFile
  if esbuildBin().len == 0:
    return "esbuild not found in PATH"
  result = ""

suite "Benchmark":
  test "dependencies available":
    check checkDependencies().len == 0

  test "output size comparison + save":
    check checkDependencies().len == 0
    let code = readFile(dataFile)

    let inlineOut = minifyInline(code)
    writeFile(outDir / "d3_squeezy_inline.js", inlineOut)

    # The parse-based modes may fail on syntax the grammar does not cover
    # yet; report that instead of masking it, like the old exit-code check.
    var bundleOut, mangleOut = ""
    try:
      bundleOut = minifyBundle(code)
      writeFile(outDir / "d3_squeezy_bundle.js", bundleOut)
    except CatchableError as e:
      echo "    squeezy-bundle:        FAILED (" & e.msg.splitLines()[0] & ")"
    try:
      mangleOut = minifyBundleMangle(code)
      writeFile(outDir / "d3_squeezy_bundle+mangle.js", mangleOut)
    except CatchableError as e:
      echo "    squeezy-bundle+mangle: FAILED (" & e.msg.splitLines()[0] & ")"

    let (esbOut, esbCode) = execCmdEx(
      esbuildBin() & " --minify " & quoteShell(dataFile))
    check esbCode == 0
    writeFile(outDir / "d3_esbuild.js", esbOut)

    check inlineOut.len > 0
    check esbOut.len > 0
    check inlineOut.len < code.len
    check esbOut.len < code.len

    echo "\n  Output sizes:\n"
    echo "    Original:              " & $code.len & " bytes"
    echo "    squeezy-inline:        " & $inlineOut.len & " bytes"
    if bundleOut.len > 0:
      echo "    squeezy-bundle:        " & $bundleOut.len & " bytes"
    else:
      echo "    squeezy-bundle:        FAILED"
    if mangleOut.len > 0:
      echo "    squeezy-bundle+mangle: " & $mangleOut.len & " bytes"
    else:
      echo "    squeezy-bundle+mangle: FAILED"
    echo "    esbuild:               " & $esbOut.len & " bytes"

  test "timing benchmark":
    check checkDependencies().len == 0
    let code = readFile(dataFile)
    const runs = 5

    proc meanMs(fn: proc(): string {.closure.}): float =
      var total = 0.0
      for i in 1 .. runs:
        let t0 = epochTime()
        let s = fn()
        total += epochTime() - t0
        doAssert s.len > 0
      total / runs * 1000.0

    echo ""
    echo "  mean over " & $runs & " runs:"
    echo "    squeezy-inline:        " &
      formatFloat(meanMs(proc(): string = minifyInline(code)),
        ffDecimal, 1) & " ms"
    echo "    squeezy-bundle:        " &
      formatFloat(meanMs(proc(): string = minifyBundle(code)),
        ffDecimal, 1) & " ms"
    echo "    squeezy-bundle+mangle: " &
      formatFloat(meanMs(proc(): string = minifyBundleMangle(code)),
        ffDecimal, 1) & " ms"

    let esb = esbuildBin()
    var esbTotal = 0.0
    for i in 1 .. runs:
      let t0 = epochTime()
      let (o, c) = execCmdEx(esb & " --minify " & quoteShell(dataFile))
      esbTotal += epochTime() - t0
      check c == 0
      check o.len > 0
    echo "    esbuild:               " &
      formatFloat(esbTotal / runs * 1000.0, ffDecimal, 1) & " ms"

    # Stage breakdown: parse vs codegen vs mangle-collect, so future
    # speed work targets the right stage. Fewer runs: stages are stable
    # and this keeps CI time down (debug builds are ~8x slower).
    const stageRuns = 3
    var tParse = 0.0
    var prog: OpenAstProgram
    for i in 1 .. stageRuns:
      let t0 = epochTime()
      prog = jsmin.parseJsString(code)
      tParse += epochTime() - t0
    doAssert prog.nodes.len > 0
    let plainOpts = JsGenOptions(minify: true)
    var tCodegen = 0.0
    for i in 1 .. stageRuns:
      let t0 = epochTime()
      let s = jsmin.minifyJsProgram(prog, plainOpts).code
      tCodegen += epochTime() - t0
      doAssert s.len > 0
    let mangleOpts = JsGenOptions(minify: true, mangle: true)
    var tMangle = 0.0
    for i in 1 .. stageRuns:
      let t0 = epochTime()
      let s = jsmin.minifyJsProgram(prog, mangleOpts).code
      tMangle += epochTime() - t0
      doAssert s.len > 0
    echo "  stages over " & $stageRuns & " runs (parse/codegen/mangle):"
    echo "    parse:               " &
      formatFloat(tParse / stageRuns * 1000.0, ffDecimal, 1) & " ms"
    echo "    codegen:             " &
      formatFloat(tCodegen / stageRuns * 1000.0, ffDecimal, 1) & " ms"
    echo "    codegen+mangle:      " &
      formatFloat(tMangle / stageRuns * 1000.0, ffDecimal, 1) & " ms"
