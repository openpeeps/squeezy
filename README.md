<p align="center">
  <img src="https://raw.githubusercontent.com/openpeeps/squeezy/main/.github/squeezy2.png" alt="Squeezy Logo" width="120" height="120"><br>
  A dead simple JavaScript and CSS validator, bundler and minifier
</p>

<p align="center">
  <code>nimble install squeezy</code> / <code>clue install squeezy --build</code>
</p>

<p align="center">
  <a href="https://openpeeps.github.io/squeezy">API reference</a><br>
  <img src="https://github.com/openpeeps/squeezy/workflows/test/badge.svg" alt="Github Actions">  <img src="https://github.com/openpeeps/squeezy/workflows/docs/badge.svg" alt="Github Actions">
</p>

## 😍 Key Features
- High-performance minifier built with Nim lang 👑
- Validate, Bundle and minify CSS and JavaScript assets
- CLI with `css` and `bundle` commands (stdlib only, no dependencies)
- Node-style resolution: bare specifiers, `node_modules`, `package.json` (`exports`/`main`/`module`), `--external`
- Source map generation for JavaScript
- Identifier mangling for JavaScript
- Inline Minifier for HTML / CSS / JavaScript (fastest, no parsing, no validation)
- Built on top of [pkg/sweetsyntax](https://github.com/openpeeps/sweetsyntax) & [pkg/openparser/css](https://github.com/openpeeps/openparser)

## Examples
Check in the [examples directory](https://github.com/openpeeps/squeezy/tree/main/examples) and the [unit tests](https://github.com/openpeeps/squeezy/tree/main/tests)

### CLI

```
A dead simple JavaScript and CSS validator, bundler and minifier
  (c) OpenPeeps | MIT License
  Build Version: 0.1.0

usage: squeezy <command> [args] [options]

Commands
  css <input.css> [-o output]      minify CSS, inlines @import
  bundle <entry.js> [-o output]    bundle JS, resolves imports

CSS options
  -o, --out <file>                 write to file instead of stdout
      --preserve-comments          keep comments

Bundle options
  -o, --out <file>                 write to file instead of stdout
      --minify                     minify JS output
      --mangle                     mangle JS identifiers, implies minify
      --sourcemap                  emit a source map next to output, es format only
      --format <fmt>               es, cjs, iife, umd, amd, system (default es)
      --name <name>                module name for iife and umd wrappers
      --preserve-comments          keep comments
      --external <a,b>             leave these bare imports untouched
      --node-path <dir>            extra node_modules lookup dir

  -h, --help                       show this help
  --version                        show version

aliases: minify for css, js for bundle
examples:
  squeezy css styles.css -o styles.min.css
  squeezy bundle app.js -o bundle.js --minify --mangle
```

### Examples
```sh
# minify CSS (@import gets inlined)
squeezy css styles.css -o styles.min.css

# bundle JS, with optional minification
squeezy bundle app.js -o bundle.js --minify --mangle

# other bundle options
squeezy bundle app.js -o bundle.js --format=iife --name=MyLib --sourcemap
squeezy bundle app.js -o bundle.js --external react,react-dom --node-path ./shared
squeezy --help
```


### Roadmap
- Fix module graph: follow `export ... from` re-exports, then dynamic `import()` / `require()` (done)
- `check` command wiring up the existing validator
- CSS correctness: conditional `@import`, `url()` rebasing, then CSS source maps
- Decide `treeShake`: implement (with bundle-wide mangling) or remove the flag
- Bare-specifier / `node_modules` resolution (done: `exports`/`main`/`module` fields, scoped packages, `--external`, `--node-path`, `NODE_PATH`)
- JS source maps for wrapped formats
- CLI: `html` command, stdin input, `--watch` mode
- Close the esbuild size gap, measured against the existing bench


## Benchmarks

Comparing Squeezy vs ESBuild (on d3.js library ~ 20k lines)
```
[Suite] Benchmark
  [OK] dependencies available

  Output sizes:

    Original:              587043 bytes
    squeezy-inline:        420081 bytes
    squeezy-bundle:        410815 bytes
    squeezy-bundle+mangle: 294480 bytes
    esbuild:               281796 bytes
  [OK] output size comparison + save

  mean over 5 runs:
    squeezy-inline:        8.1 ms
    squeezy-bundle:        55.2 ms
    squeezy-bundle+mangle: 132.2 ms
    esbuild:               52.3 ms
  stages over 3 runs (parse/codegen/mangle):
    parse:               48.5 ms
    codegen:             6.3 ms
    codegen+mangle:      81.0 ms
  [OK] timing benchmark
```

### ❤ Contributions & Support
- 🐛 Found a bug? [Create a new Issue](https://github.com/openpeeps/squeezy/issues)
- 👋 Wanna help? [Fork it!](https://github.com/openpeeps/squeezy/fork)

### 🎩 License
MIT license. [Made by Humans from OpenPeeps](https://github.com/openpeeps).<br>
Copyright OpenPeeps & Contributors &mdash; All rights reserved.
