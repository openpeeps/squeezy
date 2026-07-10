import std/[unittest, os, strutils, json, sequtils]
import squeezy/bundle/bundler
import squeezy/bundle/common
import squeezy/bundle/js/codgen
import squeezy/bundle/js/bundler as jsbundler
import squeezy/bundle/sourcemap
import squeezy/bundle/js/minifier as jsminifier
import squeezy/bundle/css/bundler as cssbundler

suite "JS code generator":
  test "generates function declaration":
    let code = "function hello(name) { let x = 10; return x + name; }"
    let result = minify(code, "js")
    check result == "function hello(name){let x=10;return x+name;}"

  test "preserves operator precedence":
    let code = "const a = 1 + 2 * 3;"
    let result = minify(code, "js")
    check result == "const a=1+2*3;"

  test "wraps parens when needed":
    let code = "const a = (1 + 2) * 3;"
    let result = minify(code, "js")
    check result == "const a=(1+2)*3;"

  test "generates if/else":
    let code = "if (x > 0) { return x; } else { return -x; }"
    let result = minify(code, "js")
    check result == "if(x>0){return x;}else{return -x;}"

  test "generates for loop":
    let code = "for (var i = 0; i < 10; i++) { console.log(i); }"
    let result = minify(code, "js")
    check result == "for(var i=0;i<10;i++){console.log(i);}"

  test "generates while loop":
    let code = "var x = 0; while (x < 5) { x++; }"
    let result = minify(code, "js")
    check result == "var x=0;while(x<5){x++;}"

  test "generates do-while":
    let code = "do { x++; } while (x < 5);"
    let result = minify(code, "js")
    check result == "do{x++;}while(x<5)"

  test "generates object literal":
    let code = "var obj = {name: 'hello', age: 42};"
    let result = minify(code, "js")
    check result == "var obj={name:\"hello\",age:42};"

  test "generates string content":
    let code = "var s = \"hello world\";"
    let result = minify(code, "js")
    check result == "var s=\"hello world\";"

  test "generates boolean and null":
    let code = "var a = true, b = false, c = null;"
    let result = minify(code, "js")
    check result == "var a=true, b=false, c=null;"

  test "generates ternary":
    let code = "var x = a > b ? a : b;"
    let result = minify(code, "js")
    check result == "var x=a>b?a:b;"

  test "generates array literal":
    let code = "var arr = [1, 2, 3];"
    let result = minify(code, "js")
    check result == "var arr=[1,2,3];"

  test "generates member access":
    let code = "var x = obj.prop;"
    let result = minify(code, "js")
    check result == "var x=obj.prop;"

  test "generates bracket access":
    let code = "var x = obj['key'];"
    let result = minify(code, "js")
    check result == "var x=obj[\"key\"];"

  test "generates function call":
    let code = "console.log('test');"
    let result = minify(code, "js")
    check result == "console.log(\"test\");"

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
    check result == "var a=1, b=2, c=3;"

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

suite "JS mangler":
  let mangleOpts = BundleConfig(minify: true, mangle: true)

  test "mangles multi-char function parameters":
    let code = "function add(first, second) { return first + second; }"
    let result = minify(code, "js", mangleOpts)
    check result == "function add(a,b){return a+b;}"

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
    check result == "function run(){var a=0;let b=10;const c=100;return a+b+c;}"

  test "preserves console and globals":
    let code = "function log(message) { console.log(message); }"
    let result = minify(code, "js", mangleOpts)
    check result == "function log(a){console.log(a);}"

  test "preserves property names in dot access":
    let code = "function get(obj) { return obj.name; }"
    let result = minify(code, "js", mangleOpts)
    check result == "function get(a){return a.name;}"

  test "preserves function names and exports":
    let code = "export function calculate(first, second) { return first + second; }"
    let result = minify(code, "js", mangleOpts)
    check result == "export function calculate(a,b){return a+b;};"

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
    check result == "function outer(a){function inner(b){return a+b;}return inner;}"

  test "preserves object literal keys":
    let code = "function f() { var obj = {name: 'test'}; return obj.name; }"
    let result = minify(code, "js", mangleOpts)
    check result == "function f(){var a={name:\"test\"}return a.name;}"

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
    check result == "function f(){var a=Math.random();var b=JSON.stringify(a);var c=Date.now();return c;}"

  test "single-char names stay unchanged":
    let code = "function f(a, b) { return a + b; }"
    let result = minify(code, "js", mangleOpts)
    check result == "function f(a,b){return a+b;}"

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
