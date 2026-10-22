import std/[unittest, os, strutils, json, sequtils]
import ../src/squeezy/bundle/bundler
import ../src/squeezy/bundle/common
import ../src/squeezy/bundle/js/codgen
import ../src/squeezy/bundle/js/bundler as jsbundler
import ../src/squeezy/bundle/js/resolve as jsresolve
import ../src/squeezy/bundle/sourcemap
import ../src/squeezy/bundle/js/minifier as jsminifier
import ../src/squeezy/bundle/css/bundler as cssbundler

suite "JS code generator":
  test "generates function declaration":
    let code = "function hello(name) { let x = 10; return x + name; }"
    let result = minify(code, "js")
    check result == "function hello(name){let x=10;return x+name}"

  test "preserves operator precedence":
    let code = "const a = 1 + 2 * 3;"
    let result = minify(code, "js")
    check result == "const a=1+2*3"

  test "wraps parens when needed":
    let code = "const a = (1 + 2) * 3;"
    let result = minify(code, "js")
    check result == "const a=(1+2)*3"

  test "generates if/else":
    let code = "if (x > 0) { return x; } else { return -x; }"
    let result = minify(code, "js")
    check result == "if(x>0){return x}else{return -x}"

  test "generates for loop":
    let code = "for (var i = 0; i < 10; i++) { console.log(i); }"
    let result = minify(code, "js")
    check result == "for(var i=0;i<10;i++){console.log(i)}"

  test "generates while loop":
    let code = "var x = 0; while (x < 5) { x++; }"
    let result = minify(code, "js")
    check result == "var x=0;while(x<5){x++}"

  test "generates do-while":
    let code = "do { x++; } while (x < 5);"
    let result = minify(code, "js")
    check result == "do{x++}while(x<5)"

  test "generates object literal":
    let code = "var obj = {name: 'hello', age: 42};"
    let result = minify(code, "js")
    check result == "var obj={name:\"hello\",age:42}"

  test "generates string content":
    let code = "var s = \"hello world\";"
    let result = minify(code, "js")
    check result == "var s=\"hello world\""

  test "generates boolean and null":
    let code = "var a = true, b = false, c = null;"
    let result = minify(code, "js")
    check result == "var a=true,b=false,c=null"

  test "preserves undefined distinctly from null":
    let code = "var u = undefined; if (u === undefined) { u = null; }"
    let result = minify(code, "js")
    check result.contains("undefined")
    check result.contains("===undefined")

  test "parses destructuring defaults":
    check minify("var {a = 1, b} = obj;", "js") == "var {a=1,b}=obj"
    check minify("var {a: x = 2} = obj;", "js") == "var {a:x=2}=obj"
    check minify("function f({a = 1} = {}) { return a; }", "js") ==
      "function f({a=1}={}){return a}"

  test "parses object method defaults and rest":
    check minify("var o = { fetch(u, push = true, cb) { return cb(u); } };",
      "js") == "var o={fetch(u,push=true,cb){return cb(u)}}"
    check minify("var o = { m(...args) { return args; } };", "js") ==
      "var o={m(...args){return args}}"

  test "keeps parens on arrow object bodies":
    check minify("var g = x => ({a: 1});", "js") == "var g=x=>({a:1})"
    check minify("var o = {create: (p) => ({t: 1})};", "js") ==
      "var o={create:p=>({t:1})}"
    check minify("var o = {k: async () => {return 1;}};", "js") ==
      "var o={k:async ()=>{return 1}}"

  test "object with leading comment stays an object":
    let code = "var o = {\n/** doc */\na: 1,\nb: 2\n};"
    check minify(code, "js") == "var o={a:1,b:2}"

  test "generates ternary":
    let code = "var x = a > b ? a : b;"
    let result = minify(code, "js")
    check result == "var x=a>b?a:b"

  test "generates array literal":
    let code = "var arr = [1, 2, 3];"
    let result = minify(code, "js")
    check result == "var arr=[1,2,3]"

  test "generates member access":
    let code = "var x = obj.prop;"
    let result = minify(code, "js")
    check result == "var x=obj.prop"

  test "generates bracket access":
    let code = "var x = obj['key'];"
    let result = minify(code, "js")
    check result == "var x=obj[\"key\"]"

  test "generates function call":
    let code = "console.log('test');"
    let result = minify(code, "js")
    check result == "console.log(\"test\")"

suite "CSS minifier":
  test "strips comments":
    let css = """
      /* header comment */
      body { color: red; }
    """
    check minify(css, "css") == "body{color:red;}"

  test "removes zero units":
    let css = "body { margin: 0px; padding: 0em; }"
    check minify(css, "css") == "body{margin:0;padding:0;}"

  test "shortens hex colors":
    let css = """
      .a { color: #FF8800; }
      .b { color: #FFFFFF; }
      .c { color: #123456; }
    """
    let result = minify(css, "css")
    check result.contains("#F80")
    check result.contains("#FFF")
    check result.contains("#123456")

  test "removes trailing zeros":
    let css = "body { font-size: 1.0em; }"
    let result = minify(css, "css")
    check result.contains("1em")

  test "collapses whitespace":
    let css = """
      .container {
        width: 100%;
        margin: 0 auto;
      }
    """
    check minify(css, "css") == ".container{width:100%;margin:0 auto;}"

  test "preserves media queries":
    let css = """
      @media (max-width: 768px) {
        body { width: 100%; }
      }
    """
    let result = minify(css, "css")
    check result.contains("@media")
    check result.contains("(max-width:768px)")

  test "preserves all declarations":
    let css = """
      body { color: red; color: blue; }
    """
    let result = minify(css, "css")
    check result == "body{color:red;color:blue;}"

suite "Validator":
  test "valid JS returns empty":
    check validateJs("const x = 1;").len == 0

  test "invalid JS returns errors":
    let errors = validateJs("const x = ;")
    check errors.len > 0

  test "valid CSS returns empty":
    check validateCss("body { color: red; }").len == 0

suite "JS code generator edge cases":
  test "generates arrow function":
    let code = "var fn = (x) => x * 2;"
    let result = minify(code, "js")
    check result.contains("=>")

  test "generates empty block":
    let code = "if (x) {}"
    let result = minify(code, "js")
    check result == "if(x){}"

  test "generates switch statement":
    let code = """
      switch (x) {
        case 1: break;
        case 2: return x;
        default: break;
      }
    """
    let result = minify(code, "js")
    check result.contains("switch(")
    check result.contains("case 1")
    check result.contains("default:")

  test "generates try/catch":
    let code = """
      try {
        risky();
      } catch (e) {
        handle(e);
      }
    """
    let result = minify(code, "js")
    check result.contains("try{")
    check result.contains("catch(")

  test "generates multiple declarations":
    let code = "var a = 1, b = 2, c = 3;"
    let result = minify(code, "js")
    check result == "var a=1,b=2,c=3"

suite "Bundle metadata":
  test "minify/1 dispatches by extension":
    let js = "var x = 1;"
    let css = "body { color: red; }"
    check minify(js, "js") != js
    check minify(css, "css") != css

  test "unknown extension passes through":
    let txt = "some plain text"
    check minify(txt, "txt") == txt

  test "default config has minify enabled":
    let cfg = defaultConfig()
    check cfg.minify == true

suite "CSS bundler end-to-end":
  test "bundles imported CSS":
    let tmpDir = getTempDir() / "squeezy_test_css"
    createDir(tmpDir)
    writeFile(tmpDir / "base.css", "body{color:red}")
    writeFile(tmpDir / "main.css", "@import 'base.css'; .container{width:100%}")
    let result = cssbundler.bundleCss(tmpDir / "main.css", defaultConfig())
    removeDir(tmpDir)
    check result.contains("body{color:red;}")
    check result.contains(".container{width:100%;}")

suite "JS bundler end-to-end":
  test "bundles imported modules":
    let tmpDir = getTempDir() / "squeezy_test_js"
    createDir(tmpDir)
    writeFile(tmpDir / "utils.js", "function add(a,b){return a+b}")
    writeFile(tmpDir / "main.js", "import utils; console.log(add(1,2))")
    let result = jsbundler.bundleJs(tmpDir / "main.js", defaultConfig())
    removeDir(tmpDir)
    check result.len > 0

suite "JS bundle output formats":
  let tmpDir = getTempDir() / "squeezy_test_formats"
  createDir(tmpDir)
  writeFile(tmpDir / "utils.js", "export function add(a,b){return a+b}")
  writeFile(tmpDir / "main.js", "import {add} from './utils.js'; export function mul(a,b){return a*b}")

  test "es format drops resolved imports and inlines deps":
    let opts = BundleConfig(minify: true, format: fmtES)
    let result = jsbundler.bundleJs(tmpDir / "main.js", opts)
    check not result.contains("from './utils.js'")
    check result.contains("export function add")
    check result.contains("export function mul")

  test "cjs wrapper":
    let opts = BundleConfig(minify: true, format: fmtCJS)
    let result = jsbundler.bundleJs(tmpDir / "main.js", opts)
    check result.startsWith("'use strict';")
    check result.contains("exports.mul=mul;")
    check result.endsWith("module.exports=exports;")

  test "iife wrapper with module name":
    let opts = BundleConfig(minify: true, format: fmtIIFE, moduleName: "UI")
    let result = jsbundler.bundleJs(tmpDir / "main.js", opts)
    check result.contains("var UI=(function(exports)")
    check result.contains("exports.mul=mul;")
    check result.endsWith("return exports;})({});")

  test "iife wrapper defaults module name to entry basename":
    let opts = BundleConfig(minify: true, format: fmtIIFE)
    let result = jsbundler.bundleJs(tmpDir / "main.js", opts)
    check result.contains("var main=(function(exports)")

  test "umd wrapper with module name":
    let opts = BundleConfig(minify: true, format: fmtUMD, moduleName: "UI")
    let result = jsbundler.bundleJs(tmpDir / "main.js", opts)
    check result.contains("global.UI={}")
    check result.contains("typeof exports==='object'")
    check result.endsWith("return exports;}));")

  test "amd wrapper":
    let opts = BundleConfig(minify: true, format: fmtAMD)
    let result = jsbundler.bundleJs(tmpDir / "main.js", opts)
    check result.startsWith("define(['exports']")
    check result.contains("exports.mul=mul;")
    check result.endsWith("return exports;}));")

  test "system wrapper":
    let opts = BundleConfig(minify: true, format: fmtSystem)
    let result = jsbundler.bundleJs(tmpDir / "main.js", opts)
    check result.startsWith("System.register([],")
    check result.contains("exports.mul=mul;")
    check result.endsWith("})};}));")

  test "wrapped formats strip import/export statements":
    let opts = BundleConfig(minify: true, format: fmtIIFE, moduleName: "UI")
    let result = jsbundler.bundleJs(tmpDir / "main.js", opts)
    check not result.contains("import {add}")
    check not result.contains("export function mul")

  removeDir(tmpDir)

suite "JS mangler":
  let mangleOpts = BundleConfig(minify: true, mangle: true)

  test "mangles multi-char function parameters":
    let code = "function add(first, second) { return first + second; }"
    let result = minify(code, "js", mangleOpts)
    check result == "function add(a,b){return a+b}"

  test "mangles local variables":
    let code = """
      function run() {
        var total = 0;
        let count = 10;
        const limit = 100;
        return total + count + limit;
      }
    """
    let result = minify(code, "js", mangleOpts)
    check result == "function run(){var a=0;let b=10;const c=100;return a+b+c}"

  test "preserves console and globals":
    let code = "function log(message) { console.log(message); }"
    let result = minify(code, "js", mangleOpts)
    check result == "function log(a){console.log(a)}"

  test "preserves property names in dot access":
    let code = "function get(obj) { return obj.name; }"
    let result = minify(code, "js", mangleOpts)
    check result == "function get(a){return a.name}"

  test "preserves function names and exports":
    let code = "export function calculate(first, second) { return first + second; }"
    let result = minify(code, "js", mangleOpts)
    check result == "export function calculate(a,b){return a+b}"

  test "mangles for-loop variable":
    let code = "function f() { for (var index = 0; index < 10; index++) {} }"
    let result = minify(code, "js", mangleOpts)
    check result == "function f(){for(var a=0;a<10;a++){}}"

  test "mangles nested function scopes":
    let code = """
      function outer(value) {
        function inner(other) {
          return value + other;
        }
        return inner;
      }
    """
    let result = minify(code, "js", mangleOpts)
    check result == "function outer(a){function inner(b){return a+b}return inner}"

  test "preserves object literal keys":
    let code = "function f() { var obj = {name: 'test'}; return obj.name; }"
    let result = minify(code, "js", mangleOpts)
    check result == "function f(){var a={name:\"test\"};return a.name}"

  test "preserves known API globals":
    let code = """
      function f() {
        var x = Math.random();
        var y = JSON.stringify(x);
        var z = Date.now();
        return z;
      }
    """
    let result = minify(code, "js", mangleOpts)
    check result == "function f(){var a=Math.random();var b=JSON.stringify(a);var c=Date.now();return c}"

  test "single-char names stay unchanged":
    let code = "function f(a, b) { return a + b; }"
    let result = minify(code, "js", mangleOpts)
    check result == "function f(a,b){return a+b}"

  test "mangle produces shorter output":
    let plain = BundleConfig(minify: true, mangle: false)
    let code = "function process(firstParam, secondParam) { const result = firstParam + secondParam; return result; }"
    let plainResult = minify(code, "js", plain)
    let mangledResult = minify(code, "js", mangleOpts)
    check mangledResult.len < plainResult.len
    check "firstParam" notin mangledResult

suite "Source map":
  let sm = newSourceMap("output.js")
  discard sm.addSource("input.js", "function greet(name) {\n  return name;\n}")
  discard sm.addName("name")

  test "encodeVLQ roundtrip":
    for v in [0, 1, -1, 15, -15, 127, -128, 1000, -1000]:
      let encoded = encodeVLQ(v)
      check encoded.len > 0

  test "addMapping and generate produce valid JSON":
    let sm = newSourceMap("out.js")
    discard sm.addSource("src.js", "var x = 1;")
    sm.addMapping(0, 0, 0, 0, 0)
    sm.addMapping(0, 4, 0, 4, 0)
    let result = sm.generate()
    let parsed = parseJson(result)
    check parsed["version"].getInt() == 3
    check parsed["file"].getStr() == "out.js"
    check parsed["sources"][0].getStr() == "src.js"
    check parsed["mappings"].getStr().len > 0

  test "sourcesContent preserved":
    let sm = newSourceMap("out.js")
    discard sm.addSource("test.js", "let a = 1;")
    let result = sm.generate()
    let parsed = parseJson(result)
    check parsed["sourcesContent"][0].getStr() == "let a = 1;"

  test "generateJs returns source map when opts.sourceMap is set":
    let code = "function greet(name) { return name; }"
    let opts = JsGenOptions(minify: true, sourceMap: true)
    let res = generateJs(jsminifier.parseJsString(code), opts, "test.js", code)
    check res.code.len > 0
    check res.sourceMapRaw.len > 0
    let parsed = parseJson(res.sourceMapRaw)
    check parsed["version"].getInt() == 3
    check parsed["file"].getStr() == "test.js"
    check parsed["sources"][0].getStr() == "test.js"
    let names = parsed["names"].elems.mapIt(it.getStr())
    check "name" in names

  test "minifyWithSourceMap returns source map":
    let code = "function greet(name) { return name; }"
    let opts = BundleConfig(minify: true, sourceMap: true)
    let res = minifyWithSourceMap(code, "js", opts, "test.js")
    check res.code.len > 0
    check res.sourceMapRaw.len > 0
    let parsed = parseJson(res.sourceMapRaw)
    check parsed["version"].getInt() == 3

  test "minifyWithSourceMap sourceMap disabled returns empty map":
    let code = "function greet(name) { return name; }"
    let opts = BundleConfig(minify: true, sourceMap: false)
    let res = minifyWithSourceMap(code, "js", opts, "test.js")
    check res.code.len > 0
    check res.sourceMapRaw.len == 0

  test "sourceMap with mangling includes original names":
    let code = "function greet(first, second) { return first + second; }"
    let opts = JsGenOptions(minify: true, mangle: true, sourceMap: true)
    let res = generateJs(jsminifier.parseJsString(code), opts, "test.js", code)
    check res.code.len > 0
    check res.sourceMapRaw.len > 0
    let parsed = parseJson(res.sourceMapRaw)
    let names = parsed["names"].elems.mapIt(it.getStr())
    check "first" in names
    check "second" in names

suite "Node module resolution":
  proc makeNodeTree(): string =
    result = getTempDir() / "squeezy_test_node"
    if dirExists(result):
      removeDir(result)
    createDir(result / "src")
    # pkg-a: main field
    createDir(result / "node_modules" / "pkg-a")
    writeFile(result / "node_modules" / "pkg-a" / "package.json",
      """{"name": "pkg-a", "version": "1.0.0", "main": "lib.js"}""")
    writeFile(result / "node_modules" / "pkg-a" / "lib.js",
      "export const a = 42;")
    # @scope/pkg-b: module field
    createDir(result / "node_modules" / "@scope" / "pkg-b")
    writeFile(result / "node_modules" / "@scope" / "pkg-b" / "package.json",
      """{"name": "@scope/pkg-b", "version": "1.0.0", "module": "esm.js"}""")
    writeFile(result / "node_modules" / "@scope" / "pkg-b" / "esm.js",
      "export const b = 7;")
    # pkg-c: exports map with root and subpath
    createDir(result / "node_modules" / "pkg-c" / "dist")
    writeFile(result / "node_modules" / "pkg-c" / "package.json",
      """{"name": "pkg-c", "version": "1.0.0", "exports": {".": "./dist/index.js", "./feature": "./dist/feat.js"}}""")
    writeFile(result / "node_modules" / "pkg-c" / "dist" / "index.js",
      "export const c = 1;")
    writeFile(result / "node_modules" / "pkg-c" / "dist" / "feat.js",
      "export const feat = 2;")
    # pkg-broken: malformed package.json, index.js fallback
    createDir(result / "node_modules" / "pkg-broken")
    writeFile(result / "node_modules" / "pkg-broken" / "package.json",
      "{not valid json")
    writeFile(result / "node_modules" / "pkg-broken" / "index.js",
      "export const broken = 3;")

  test "resolveSpecifier finds main field":
    let root = makeNodeTree()
    let r = jsresolve.resolveSpecifier(root / "src" / "entry.js", "pkg-a",
      jsresolve.defaultResolveOpts())
    removeDir(root)
    check r == root / "node_modules" / "pkg-a" / "lib.js"

  test "resolveSpecifier finds exports map root and subpath":
    let root = makeNodeTree()
    let opts = jsresolve.defaultResolveOpts()
    let main = jsresolve.resolveSpecifier(root / "src" / "entry.js", "pkg-c", opts)
    let sub = jsresolve.resolveSpecifier(root / "src" / "entry.js",
      "pkg-c/feature", opts)
    removeDir(root)
    check main == root / "node_modules" / "pkg-c" / "dist" / "index.js"
    check sub == root / "node_modules" / "pkg-c" / "dist" / "feat.js"

  test "resolveSpecifier skips builtins and misses unknown":
    let opts = jsresolve.defaultResolveOpts()
    check jsresolve.resolveSpecifier("entry.js", "fs", opts) == ""
    check jsresolve.resolveSpecifier("entry.js", "node:path", opts) == ""
    check jsresolve.resolveSpecifier("entry.js", "no-such-pkg-xyz", opts) == ""

  test "bundleJs inlines bare, scoped, and exports-map deps":
    let root = makeNodeTree()
    writeFile(root / "src" / "entry.js",
      "import { a } from 'pkg-a';\nimport { b } from '@scope/pkg-b';\n" &
      "import { c } from 'pkg-c';\nimport { feat } from 'pkg-c/feature';\n" &
      "console.log(a, b, c, feat);")
    let result = jsbundler.bundleJs(root / "src" / "entry.js",
      BundleConfig(minify: false))
    removeDir(root)
    check result.contains("export const a=42")
    check result.contains("export const b=7")
    check result.contains("export const c=1")
    check result.contains("export const feat=2")

  test "bundleJs discovers require, dynamic import, and export from":
    let root = makeNodeTree()
    writeFile(root / "src" / "entry.js",
      "const c = require('pkg-c');\nconst d = import('pkg-a');\n" &
      "export { b } from '@scope/pkg-b';\nconsole.log(c, d, b);")
    let result = jsbundler.bundleJs(root / "src" / "entry.js",
      BundleConfig(minify: false))
    removeDir(root)
    check result.contains("export const c = 1;")
    check result.contains("export const a = 42;")
    check result.contains("export const b = 7;")

  test "bundleJs honors externals and skips builtins":
    let root = makeNodeTree()
    writeFile(root / "src" / "entry.js",
      "import { a } from 'pkg-a';\nimport fs from 'fs';\nconsole.log(a);")
    var cfg = BundleConfig(minify: false)
    cfg.externals = @["pkg-a"]
    let result = jsbundler.bundleJs(root / "src" / "entry.js", cfg)
    removeDir(root)
    check not result.contains("export const a = 42;")
    check result.contains("import { a } from 'pkg-a';")

  test "bundleJs falls back to index.js on malformed package.json":
    let root = makeNodeTree()
    writeFile(root / "src" / "entry.js",
      "import { broken } from 'pkg-broken';\nconsole.log(broken);")
    let result = jsbundler.bundleJs(root / "src" / "entry.js",
      BundleConfig(minify: false))
    removeDir(root)
    check result.contains("export const broken=3")

  test "nested node_modules shadows outer":
    let root = makeNodeTree()
    createDir(root / "src" / "nested" / "node_modules" / "pkg-a")
    writeFile(root / "src" / "nested" / "node_modules" / "pkg-a" / "package.json",
      """{"name": "pkg-a", "version": "2.0.0", "main": "shadow.js"}""")
    writeFile(root / "src" / "nested" / "node_modules" / "pkg-a" / "shadow.js",
      "export const a = 99;")
    writeFile(root / "src" / "nested" / "entry.js",
      "import { a } from 'pkg-a';\nconsole.log(a);")
    let result = jsbundler.bundleJs(root / "src" / "nested" / "entry.js",
      BundleConfig(minify: false))
    removeDir(root)
    check result.contains("export const a=99")
    check not result.contains("export const a=42")

  test "bundleJs tolerates null and undefined literals":
    let root = makeNodeTree()
    writeFile(root / "src" / "entry.js",
      "import { a } from 'pkg-a';\nconst v = null;\nlet u = undefined;\n" &
      "const c = require('pkg-c');\n" &
      "if (v === null || u === undefined) { console.log(a, c); }")
    let result = jsbundler.bundleJs(root / "src" / "entry.js",
      BundleConfig(minify: false))
    removeDir(root)
    check result.contains("export const a")
    check result.contains("export const c")
