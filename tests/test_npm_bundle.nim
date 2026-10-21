import std/[unittest, os, strutils]
import squeezy/bundle/bundler
import squeezy/bundle/common
import squeezy/bundle/js/bundler as jsbundler
import squeezy/bundle/js/resolve as jsresolve

let fixtureRoot = currentSourcePath().parentDir() / ".." / "examples" / "npm-bundle"

suite "npm-bundle fixture":
  test "fixture tree exists":
    check dirExists(fixtureRoot)
    check fileExists(fixtureRoot / "src" / "entry.js")
    check dirExists(fixtureRoot / "node_modules" / "pkg-main")

  test "es bundle inlines all fixture deps":
    let result = jsbundler.bundleJs(fixtureRoot / "src" / "entry.js",
      BundleConfig(minify: false))
    check result.contains("outer-main")
    check result.contains("scoped-module")
    check result.contains("exports-root")
    check result.contains("exports-subpath")
    check result.contains("rel")

  test "iife bundle with minify is valid JS":
    let opts = BundleConfig(minify: true, format: fmtIIFE, moduleName: "Fixture")
    let result = jsbundler.bundleJs(fixtureRoot / "src" / "entry.js", opts)
    check validateJs(result).len == 0
    check result.contains("outer-main")
    check not result.contains("import {")

  test "externals are left out":
    var cfg = BundleConfig(minify: false)
    cfg.externals = @["pkg-main"]
    let result = jsbundler.bundleJs(fixtureRoot / "src" / "entry.js", cfg)
    check not result.contains("outer-main")
    check result.contains("from 'pkg-main'")

  test "malformed package.json falls back to index.js":
    let result = jsbundler.bundleJs(fixtureRoot / "src" / "legacy.js",
      BundleConfig(minify: false))
    check result.contains("index-fallback")

  test "nested node_modules shadows outer":
    let result = jsbundler.bundleJs(fixtureRoot / "src" / "nested" / "entry.js",
      BundleConfig(minify: false))
    check result.contains("inner-shadow")
    check not result.contains("outer-main")

  test "resolveSpecifier against the fixture tree":
    let opts = jsresolve.defaultResolveOpts()
    check jsresolve.resolveSpecifier(fixtureRoot / "src" / "entry.js",
      "pkg-exports/feature", opts) ==
      fixtureRoot / "node_modules" / "pkg-exports" / "dist" / "feat.js"
    check jsresolve.resolveSpecifier(fixtureRoot / "src" / "entry.js",
      "fs", opts) == ""

  test "mangle runs bundle-wide on wrapped output":
    let minOnly = BundleConfig(minify: true, format: fmtIIFE,
      moduleName: "Fixture")
    let mangled = BundleConfig(minify: true, mangle: true, format: fmtIIFE,
      moduleName: "Fixture")
    let plain = jsbundler.bundleJs(fixtureRoot / "src" / "helper.js", minOnly)
    let result = jsbundler.bundleJs(fixtureRoot / "src" / "helper.js", mangled)
    check validateJs(result).len == 0
    check result.len < plain.len
    check result.startsWith("var Fixture=")
    check not result.contains("firstCount")
    check not result.contains("combinedTotal")
    check result.contains("exports.totalize=totalize")
