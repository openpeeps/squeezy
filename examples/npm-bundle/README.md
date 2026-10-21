# npm-bundle fixture

An offline npm-style project for exercising squeezy's `bundle` command:
bare specifiers, `node_modules` lookup, `package.json` fields, externals,
and nested shadowing. `node_modules/` is committed on purpose so everything
(including `clue test`) works without network access. No `npm install` needed.

```
npm-bundle/
  package.json            fixture project (private, no external deps)
  src/
    entry.js              main entry: bare, scoped, exports-map, subpath,
                          require(), export-from, relative, null/undefined
    helper.js             relative dep
    legacy.js             imports pkg-broken (malformed package.json)
    nested/entry.js       resolves the shadowing pkg-main below it
  node_modules/
    pkg-main              resolves via `main`
    @scope/pkg-module     scoped package, resolves via `module`
    pkg-exports           resolves via `exports` (`.` and `./feature`)
    pkg-broken            malformed package.json, falls back to index.js
```

Try it (from this directory, with `squeezy` on PATH or `../../bin/squeezy`):

```sh
# ES bundle, everything inlined, imports preserved
squeezy bundle src/entry.js

# single-file browser bundle, like the project's rollup output
squeezy bundle src/entry.js --format=iife --name=Fixture -o dist/bundle.js --minify

# leave a dep to the host environment
squeezy bundle src/entry.js --external pkg-main

# malformed package.json falls back to index.js
squeezy bundle src/legacy.js

# inner node_modules wins over the outer one
squeezy bundle src/nested/entry.js
```

The same tree is asserted by `tests/test_npm_bundle.nim`, resolving this
directory via `currentSourcePath` so the tests pass regardless of cwd.
