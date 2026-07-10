import std/[unittest, os, strutils]
import squeezy/bundle/bundler
import squeezy/bundle/common
import squeezy/bundle/js/codgen
import squeezy/bundle/js/bundler as jsbundler
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
