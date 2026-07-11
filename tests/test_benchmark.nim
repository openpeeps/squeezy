import std/[unittest, os, strutils, osproc]
import squeezy/minify/inlinejs

const
  dataFile = "tests/data/d3.js"
  runnerBin = "tests/bench_runner"

let sweetsyntaxPath* = "/Users/georgelemon/Development/packages/sweetsyntax/src"
let openparserPath* = "/Users/georgelemon/Development/packages/openparser/src"

proc checkDependencies: string =
  if not fileExists(dataFile):
    return "data file not found: " & dataFile
  if execCmdEx("which hyperfine").exitCode != 0:
    return "hyperfine not found in PATH"
  if execCmdEx("which esbuild").exitCode != 0:
    return "esbuild not found in PATH"
  ""

proc buildRunner: string =
  let cmd = "nim c -d:release --path:src --path:" &
    quoteShell(sweetsyntaxPath) & " --path:" &
    quoteShell(openparserPath) & " -o:" & runnerBin &
    " tests/bench_runner.nim 2>&1"
  let (outp, code) = execCmdEx(cmd)
  if code != 0:
    return "build failed:\n" & outp
  ""

proc runTool(cmd: string): tuple[output: string, exitCode: int] =
  result = execCmdEx(cmd)

proc runWithHyperfine(label, cmd: string): string =
  let hfcmd = "hyperfine -w 3 --min-runs 5 " &
    "-n " & quoteShell(label) & " " & quoteShell(cmd) & " 2>&1"
  let (outp, code) = execCmdEx(hfcmd)
  if code == -11:
    result = "CRASHED (SIGSEGV - stack overflow in recursive AST walk)"
  elif code != 0:
    result = "FAILED (exit " & $code & ")"
  else:
    for line in outp.splitLines:
      if line.strip.startsWith("Time") or
         line.strip.startsWith("Range"):
        result.add(line.strip & "\n")

suite "Benchmark":
  test "dependencies available":
    let err = checkDependencies()
    check err.len == 0
    if err.len > 0:
      skip()

  test "build bench runner":
    let err = buildRunner()
    check err.len == 0
    if err.len > 0:
      skip()

  test "output size comparison + save":
    let code = readFile(dataFile)
    let runner = "./" & runnerBin
    let outDir = "tests/data"

    let (inlineOut, inlineCode) = runTool(runner & " inline < " & dataFile)
    check inlineCode == 0
    writeFile(outDir & "/d3_squeezy_inline.js", inlineOut)

    let (bundleOut, bundleCode) = runTool(runner & " bundle < " & dataFile)
    if bundleCode == 0:
      writeFile(outDir & "/d3_squeezy_bundle.js", bundleOut)

    let (mangleOut, mangleCode) = runTool(runner & " bundle+mangle < " & dataFile)
    if mangleCode == 0:
      writeFile(outDir & "/d3_squeezy_bundle+mangle.js", mangleOut)

    let (esbOut, esbCode) = runTool("esbuild --minify " & dataFile)
    check esbCode == 0
    writeFile(outDir & "/d3_esbuild.js", esbOut)

    echo "\n  Output sizes:\n"
    echo "    Original:              " & $code.len & " bytes"
    echo "    squeezy-inline:        " & $inlineOut.len & " bytes"
    if bundleCode == 0:
      echo "    squeezy-bundle:        " & $bundleOut.len & " bytes"
    else:
      echo "    squeezy-bundle:        FAILED"
    if mangleCode == 0:
      echo "    squeezy-bundle+mangle: " & $mangleOut.len & " bytes"
    else:
      echo "    squeezy-bundle+mangle: FAILED"
    echo "    esbuild:               " & $esbOut.len & " bytes"

  test "hyperfine benchmark":
    let runner = "./" & runnerBin
    echo ""
    let r1 = runWithHyperfine("squeezy-inline", runner & " inline < " & dataFile)
    echo "  squeezy-inline:"
    for l in r1.splitLines:
      if l.len > 0: echo "    " & l

    let r2 = runWithHyperfine("squeezy-bundle", runner & " bundle < " & dataFile)
    echo "  squeezy-bundle:"
    for l in r2.splitLines:
      if l.len > 0: echo "    " & l

    let r3 = runWithHyperfine("squeezy-bundle+mangle", runner & " bundle+mangle < " & dataFile)
    echo "  squeezy-bundle+mangle:"
    for l in r3.splitLines:
      if l.len > 0: echo "    " & l

    let r4 = runWithHyperfine("esbuild", "esbuild --minify " & dataFile)
    echo "  esbuild:"
    for l in r4.splitLines:
      if l.len > 0: echo "    " & l

    check true
