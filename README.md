<p align="center">
  <img src="https://raw.githubusercontent.com/openpeeps/squeezy/main/.github/squeezy2.png" alt="Squeezy Logo" width="120" height="120"><br>
  A dead simple JavaScript and CSS validator, bundler and minifier
</p>

<p align="center">
  <code>nimble install squeezy</code>
</p>

<p align="center">
  <a href="https://openpeeps.github.io/squeezy">API reference</a><br>
  <img src="https://github.com/openpeeps/squeezy/workflows/test/badge.svg" alt="Github Actions">  <img src="https://github.com/openpeeps/squeezy/workflows/docs/badge.svg" alt="Github Actions">
</p>

## 😍 Key Features
- High-performance minifier built with Nim lang 👑
- Validate, Bundle and minify CSS and JavaScript assets
- CLI with `css` and `bundle` commands (stdlib only, no dependencies)
- Source map generation for JavaScript
- Identifier mangling for JavaScript
- Inline Minifier for HTML / CSS / JavaScript (fastest, no parsing, no validation)
- Built on top of [pkg/sweetsyntax](https://github.com/openpeeps/sweetsyntax) & [pkg/openparser/css](https://github.com/openpeeps/openparser)

## Examples
Check in the [examples directory](https://github.com/openpeeps/squeezy/tree/main/examples) and the [unit tests](https://github.com/openpeeps/squeezy/tree/main/tests)

### CLI
```sh
# build the binary with clue
clue build

# minify CSS (@import gets inlined)
squeezy css styles.css -o styles.min.css

# bundle JS, with optional minification
squeezy bundle app.js -o bundle.js --minify --mangle

# other bundle options
squeezy bundle app.js -o bundle.js --format=iife --name=MyLib --sourcemap
squeezy --help
```


### Roadmap
..


## Benchmarks

Comparing Squeezy vs ESBuild (on d3.js library ~ 20k lines)
```
  [OK] dependencies available
  [OK] build bench runner

  Output sizes:

    Original:              587043 bytes
    squeezy-inline:        420081 bytes
    squeezy-bundle:        413739 bytes
    squeezy-bundle+mangle: 360824 bytes
    esbuild:               281878 bytes
  [OK] output size comparison + save

  squeezy-inline:
    Time (mean ± σ):      13.5 ms ±   0.8 ms    [User: 10.3 ms, System: 2.1 ms]
    Range (min … max):    11.9 ms …  17.3 ms    156 runs
  squeezy-bundle:
    Time (mean ± σ):      93.7 ms ±   5.1 ms    [User: 84.0 ms, System: 7.8 ms]
    Range (min … max):    88.6 ms … 111.4 ms    31 runs
  squeezy-bundle+mangle:
    Time (mean ± σ):     102.0 ms ±   6.8 ms    [User: 91.5 ms, System: 8.7 ms]
    Range (min … max):    95.2 ms … 127.7 ms    27 runs
  esbuild:
    Time (mean ± σ):      63.9 ms ±   4.0 ms    [User: 50.8 ms, System: 14.5 ms]
    Range (min … max):    58.9 ms …  77.5 ms    39 runs
  [OK] hyperfine benchmark
```

### ❤ Contributions & Support
- 🐛 Found a bug? [Create a new Issue](https://github.com/openpeeps/squeezy/issues)
- 👋 Wanna help? [Fork it!](https://github.com/openpeeps/squeezy/fork)

### 🎩 License
MIT license. [Made by Humans from OpenPeeps](https://github.com/openpeeps).<br>
Copyright OpenPeeps & Contributors &mdash; All rights reserved.
