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
- Source map generation for JavaScript
- Identifier mangling for JavaScript
- Inline Minifier for HTML / CSS / JavaScript (fastest, no parsing, no validation)
- Built on top of [pkg/sweetsyntax](https://github.com/openpeeps/sweetsyntax) & [pkg/openparser/css](https://github.com/openpeeps/openparser)

## Examples
Check in the [examples directory](https://github.com/openpeeps/squeezy/tree/main/examples) and the [unit tests](https://github.com/openpeeps/squeezy/tree/main/tests)


### Roadmap
..


## Benchmarks

Comparing Squeezy vs ESBuild (on d3.js library ~ 20k lines)
```
  [OK] dependencies available
  [OK] build bench runner

  Output sizes:

    Original:              587043 bytes
    squeezy-inline:        420082 bytes
    squeezy-bundle:        391851 bytes
    squeezy-bundle+mangle: 338729 bytes
    esbuild:               281878 bytes
  [OK] output size comparison + save

  squeezy-inline:
    Time (mean ± σ):      14.7 ms ±   3.8 ms    [User: 10.9 ms, System: 2.3 ms]
    Range (min … max):    12.9 ms …  58.6 ms    168 runs
  squeezy-bundle:
    Time (mean ± σ):      96.7 ms ±   0.5 ms    [User: 88.4 ms, System: 6.7 ms]
    Range (min … max):    95.7 ms …  97.6 ms    29 runs
  squeezy-bundle+mangle:
    Time (mean ± σ):     101.3 ms ±   0.6 ms    [User: 93.1 ms, System: 6.7 ms]
    Range (min … max):    99.9 ms … 102.5 ms    28 runs
  esbuild:
    Time (mean ± σ):      53.5 ms ±   0.6 ms    [User: 44.1 ms, System: 10.4 ms]
    Range (min … max):    52.6 ms …  55.2 ms    52 runs
  [OK] hyperfine benchmark
```

### ❤ Contributions & Support
- 🐛 Found a bug? [Create a new Issue](https://github.com/openpeeps/squeezy/issues)
- 👋 Wanna help? [Fork it!](https://github.com/openpeeps/squeezy/fork)

|  |  |
|---|---|
| <a href="https://opencode.ai/go?ref=BHMEEK48QX"><img src="https://github.com/openpeeps/pistachio/blob/main/.github/opencode.png" alt="OpenCode"></a> | Switch to **Open-Source LLMs** via OpenCode GO, choosing from a variety of powerful models such as DeepSeek, Qwen, Kimi, GLM-5, MiniMax, MiMo. 🍕 [Use our referral link to get started!](https://opencode.ai/go?ref=BHMEEK48QX)|

### 🎩 License
MIT license. [Made by Humans from OpenPeeps](https://github.com/openpeeps).<br>
Copyright OpenPeeps & Contributors &mdash; All rights reserved.
