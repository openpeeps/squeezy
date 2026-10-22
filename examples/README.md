# examples

Small, hand-written samples for trying out squeezy. Everything here runs
offline — no installs, no network. Build once with `clue build`, then run
the commands below from the repo root.

```
examples/
  sample.js / utils.js    a tiny ES module pair (import/export, classes)
  sample.css / reset.css  a stylesheet that @imports a reset
  sample.min.js(.map)     what the minified JS sample looks like
  sample.min.css          what the minified CSS sample looks like
  npm-bundle/             a fake npm project (see "Bundling npm packages")
```

## JavaScript

`sample.js` is a small demo app: a `greet()` function plus an `App` class.
It imports `formatDate` from the sibling file `utils.js`:

```js
import { formatDate } from './utils.js';
```

`squeezy bundle` follows that import, stitches both files into one, and
prints the result:

```sh
./bin/squeezy bundle examples/sample.js
```

You'll see `utils.js` inlined above `sample.js`, with the `import`
statement resolved away. A few useful variations:

```sh
# write to a file instead of stdout
./bin/squeezy bundle examples/sample.js -o dist/app.js

# shrink it: minify, then mangle local names to single letters
./bin/squeezy bundle examples/sample.js --minify
./bin/squeezy bundle examples/sample.js --minify --mangle

# a single file for a <script> tag: wrap everything in a global
./bin/squeezy bundle examples/sample.js --format=iife --name=Demo --minify -o dist/demo.js

# other module formats: es (default), cjs, umd, amd, system
./bin/squeezy bundle examples/sample.js --format=cjs

# keep a dependency for the host environment instead of inlining it
./bin/squeezy bundle examples/sample.js --external ./utils.js

# keep comments, or ship a source map (source maps need es format)
./bin/squeezy bundle examples/sample.js --preserve-comments
./bin/squeezy bundle examples/sample.js --format=es --sourcemap -o dist/app.js
```

(`bundle` also answers to `js`, and it validates as it goes — syntax
errors are reported with file and line instead of silently passing through.)

## CSS

`sample.css` is a small stylesheet with custom properties, a couple of
components, and a media query. Its first line pulls in `reset.css`:

```css
@import './reset.css';
```

`squeezy css` inlines that import and minifies everything into one file:

```sh
./bin/squeezy css examples/sample.css
```

The reset lands at the top of the output, followed by the rest of the
rules, all on one line. Variations:

```sh
# write to a file instead of stdout
./bin/squeezy css examples/sample.css -o dist/styles.min.css

# keep comments (they're stripped by default)
./bin/squeezy css examples/sample.css --preserve-comments
```

(`css` also answers to `minify`. Compare the output with the checked-in
`sample.min.css` to see exactly what the minifier does.)

## Bundling npm packages

`npm-bundle/` is a fake but fully-wired npm project for exercising the
Node-style resolution: bare specifiers, `node_modules` lookup,
`package.json` fields, externals, and nested shadowing. Its
`node_modules/` is committed on purpose so everything (including
`clue test`) works without network access. No `npm install` needed.

```
npm-bundle/
  package.json            fixture project (private, no external deps)
  src/
    entry.js              main entry: bare, scoped, exports-map, subpath,
                          require(), export-from, relative, null/undefined
    run.js                require-free entry: executes under node, asserting
                          the bundle actually runs (see tests)
    helper.js             relative dep
    legacy.js             imports pkg-broken (malformed package.json)
    nested/entry.js       resolves the shadowing pkg-main below it
  node_modules/
    pkg-main              resolves via `main`; also has a default export
    @scope/pkg-module     scoped package, resolves via `module`
    pkg-exports           resolves via `exports` (`.` and `./feature`)
    pkg-broken            malformed package.json, falls back to index.js
```

Resolved imports are dropped from the output and replaced by aliases
(`import MainDef from 'pkg-main'` becomes `var MainDef = mainDefault`
after the dep chunk; `import * as ns` becomes a namespace object).
Unresolved specifiers (builtins, `--external`, missing files) keep
their import statements in `es` output.

Try it (from the `examples/` directory, with `squeezy` on PATH or
`../bin/squeezy`):

```sh
# ES bundle, everything inlined, imports resolved away
squeezy bundle npm-bundle/src/entry.js

# single-file browser bundle, like the project's rollup output
squeezy bundle npm-bundle/src/entry.js --format=iife --name=Fixture -o npm-bundle/dist/bundle.js --minify

# leave a dep to the host environment
squeezy bundle npm-bundle/src/entry.js --external pkg-main

# malformed package.json falls back to index.js
squeezy bundle npm-bundle/src/legacy.js

# inner node_modules wins over the outer one
squeezy bundle npm-bundle/src/nested/entry.js
```

The same tree is asserted by `tests/test_npm_bundle.nim`, resolving the
fixture directory via `currentSourcePath` so the tests pass regardless of cwd.
