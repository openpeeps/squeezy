import std/[unittest, times]
import ../src/squeezy/minify/[inlinehtml, inlinecss, inlinejs]


suite "squeezy minifier tests":
  test "minify HTML":
    let html = """
      <html>
        <head>
          <style>
            body { font-size: 16px; }
          </style>
          <script>
            // This is a comment
            console.log("Hello, world!");
          </script>
        </head>
        <body>
          <pre>   This   is   preformatted   text.   </pre>
          <p>   This is normal text.   </p>
        </body>
      </html>
    """

    let minifier = HtmlMinifier(preserveComments: false, preserveWhitespace: false)
    let minifiedHtml = minifier.minify(html)
    assert minifiedHtml == """<html><head><style>body{font-size:16px}</style><script>console.log("Hello, world!");</script></head><body><pre>   This   is   preformatted   text.   </pre><p>This is normal text.</p></body></html>"""


  test "minify CSS":
    let css = """
      /* This is a comment */
      body {
        font-size: 16px; /* another comment */
        color: red;
      }
    """
    let minifiedCss = minifyInlineCSS(css)
    assert minifiedCss == """body{font-size:16px;color:red}"""

  test "minify JavaScript":
    let js = """
      // This is a comment
      function greet(name) {
        console.log("Hello, " + name + "!");
      }
    """
    let minifiedJs = minifyInlineJS(js)
    assert minifiedJs == """function greet(name){console.log("Hello, "+name+"!");}"""

suite "squeezy minifier benchmkark tests":
  test "benchmark HTML minification":
    let html = """
      <html>
        <head>
          <style>
            body { font-size: 16px; }
          </style>
          <script>
            // This is a comment
            console.log("Hello, world!");
          </script>
        </head>
        <body>
          <pre>   This   is   preformatted   text.   </pre>
          <p>   This is normal text.   </p>
        </body>
      </html>
    """

    let minifier = HtmlMinifier(preserveComments: false, preserveWhitespace: false)
    let startTime = cpuTime()
    for _ in 1..1000:
      let minifiedHtml = minifier.minify(html)
    let endTime = cpuTime()
    echo "HTML minification benchmark: ", endTime - startTime, " seconds"
  
  test "benchmark CSS minification":
    let css = """
      /* This is a comment */
      body {
        font-size: 16px; /* another comment */
        color: red;
      }
    """
    let startTime = cpuTime()
    for _ in 1..1000:
      let minifiedCss = minifyInlineCSS(css)
    let endTime = cpuTime()
    echo "CSS minification benchmark: ", endTime - startTime, " seconds"

  test "benchmark JavaScript minification":
    let js = """
      // This is a comment
      function greet(name) {
        console.log("Hello, " + name + "!");
      }
    """
    let startTime = cpuTime()
    for _ in 1..1000:
      let minifiedJs = minifyInlineJS(js)
    let endTime = cpuTime()
    echo "JavaScript minification benchmark: ", endTime - startTime, " seconds"