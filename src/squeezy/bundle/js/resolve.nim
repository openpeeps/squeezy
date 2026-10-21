# A dead simple JavaScript and CSS validator, bundler and minifier
#
# (c) 2025 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/squeezy

## Node-style module resolution for the JS bundler.
## Resolves relative paths and bare specifiers via `node_modules`
## lookup with `package.json` `exports` / `main` field support.

import std/[os, strutils, tables]
import pkg/openparser/json

type
  ResolveOpts* = object
    extensions*: seq[string]
      ## File extensions probed when the specifier has none.
    mainFields*: seq[string]
      ## `package.json` fields consulted in order (after `exports`).
    conditions*: seq[string]
      ## `exports`-map condition names matched in order.
    nodePaths*: seq[string]
      ## Extra lookup roots, checked before walked-up `node_modules`.
    externals*: seq[string]
      ## Bare specifiers left untouched (never resolved).

proc defaultResolveOpts*(): ResolveOpts =
  ResolveOpts(
    extensions: @[".js", ".jsx", ".ts", ".tsx", ".mjs", ".cjs"],
    mainFields: @["module", "main"],
    conditions: @["import", "node", "default"],
    nodePaths: @[],
    externals: @[]
  )

const nodeBuiltins = [
  "assert", "async_hooks", "buffer", "child_process", "cluster", "console",
  "constants", "crypto", "dgram", "diagnostics_channel", "dns", "domain",
  "events", "fs", "http", "http2", "https", "inspector", "module", "net",
  "os", "path", "perf_hooks", "process", "punycode", "querystring",
  "readline", "repl", "stream", "string_decoder", "sys", "timers",
  "tls", "trace_events", "tty", "url", "util", "v8", "vm", "wasi",
  "worker_threads", "zlib"
]

proc stripQuotes*(s: string): string =
  ## Drop one pair of surrounding quotes. Sweetsyntax keeps the source
  ## quotes in `nkLitString.valStr`, so `'pkg'` arrives with quotes.
  if s.len >= 2:
    let f = s[0]
    if (f == '"' or f == '\'' or f == '`') and s[^1] == f:
      return s[1..^2]
  result = s

proc isBuiltinSpecifier*(specifier: string): bool =
  if specifier.startsWith("node:"):
    return true
  for b in nodeBuiltins:
    if specifier == b or specifier.startsWith(b & "/"):
      return true
  return false

proc isRelativeSpecifier*(specifier: string): bool =
  specifier.startsWith("./") or specifier.startsWith("../") or
    specifier == "." or specifier == ".." or
    specifier.startsWith("/") or os.isAbsolute(specifier)

proc splitPkgSpecifier*(specifier: string): tuple[name, subPath: string] =
  ## Split `pkg/sub` into (`pkg`, `./sub`); `@scope/pkg/sub` keeps
  ## the first two segments as the name.
  let parts = specifier.split('/')
  if specifier.startsWith("@") and parts.len >= 2:
    result.name = parts[0] & "/" & parts[1]
    if parts.len > 2:
      result.subPath = "./" & parts[2..^1].join("/")
  else:
    result.name = parts[0]
    if parts.len > 1:
      result.subPath = "./" & parts[1..^1].join("/")

var pkgCache: Table[string, JsonNode]

proc readPackageJson*(dir: string): JsonNode =
  ## Read and cache `dir/package.json` via openparser/json.
  ## Returns nil when missing or unparsable.
  let canonical =
    try: dir.absolutePath()
    except CatchableError: dir
  if pkgCache.hasKey(canonical):
    return pkgCache[canonical]
  let path = canonical / "package.json"
  if not fileExists(path):
    pkgCache[canonical] = nil
    return nil
  try:
    result = fromJsonFile(path)
    pkgCache[canonical] = result
  except CatchableError:
    pkgCache[canonical] = nil
    result = nil

proc probeFile(path: string, extensions: seq[string]): string =
  if fileExists(path):
    return path
  for ext in extensions:
    let candidate = path & ext
    if fileExists(candidate):
      return candidate
  return ""

proc resolveDirEntry(dir: string, opts: ResolveOpts): string

proc resolveTarget(pkgDir: string, target: JsonNode,
    opts: ResolveOpts): string =
  ## Resolve one `exports`-map target value to a file path.
  case target.kind
  of JString:
    let t = target.getStr()
    if t.startsWith("./") or t.startsWith("../"):
      let base = pkgDir / t
      result = probeFile(base, opts.extensions)
      if result.len == 0 and dirExists(base):
        result = resolveDirEntry(base, opts)
    elif t.startsWith("/") or os.isAbsolute(t):
      result = probeFile(t, opts.extensions)
  of JArray:
    for item in target.elems:
      result = resolveTarget(pkgDir, item, opts)
      if result.len > 0:
        return result
  of JObject:
    for cond in opts.conditions:
      if target.hasKey(cond):
        result = resolveTarget(pkgDir, target[cond], opts)
        if result.len > 0:
          return result
  else:
    discard

proc resolveExportsMap(pkgDir: string, exports: JsonNode, subPath: string,
    opts: ResolveOpts): string =
  ## Resolve against the `exports` field for `.` or `./sub` keys.
  ## Supports string targets, conditional objects, and fallback arrays.
  let key = if subPath.len == 0: "." else: subPath
  case exports.kind
  of JString, JArray:
    if key == ".":
      result = resolveTarget(pkgDir, exports, opts)
  of JObject:
    if exports.hasKey(key):
      result = resolveTarget(pkgDir, exports[key], opts)
    elif key != "." and exports.hasKey("./" & key.strip(chars = {'.', '/'})):
      # tolerate callers passing `sub` instead of `./sub`
      result = resolveTarget(pkgDir,
        exports["./" & key.strip(chars = {'.', '/'})], opts)
  else:
    discard

proc resolveDirEntry(dir: string, opts: ResolveOpts): string =
  ## Resolve a directory: `package.json` entry fields, else `index.*`.
  let pkg = readPackageJson(dir)
  if not pkg.isNil and pkg.kind == JObject:
    if pkg.hasKey("exports"):
      try:
        result = resolveExportsMap(dir, pkg["exports"], "", opts)
        if result.len > 0:
          return result
      except CatchableError:
        discard
    for field in opts.mainFields:
      if pkg.hasKey(field):
        try:
          let v = pkg[field]
          if v.kind == JString:
            let base = dir / v.getStr()
            result = probeFile(base, opts.extensions)
            if result.len == 0 and dirExists(base):
              result = resolveDirEntry(base, opts)
            if result.len > 0:
              return result
        except CatchableError:
          discard
  for ext in opts.extensions:
    let candidate = dir / ("index" & ext)
    if fileExists(candidate):
      return candidate
  return ""

proc resolveBare(importerDir: string, pkgName, subPath: string,
    opts: ResolveOpts): string =
  var extra: seq[string] = @[]
  for np in opts.nodePaths:
    extra.add(np / pkgName)
  var dir = importerDir.absolutePath()
  while true:
    var candidates = extra
    candidates.add(dir / "node_modules" / pkgName)
    extra = @[] # extra roots only checked once, at the innermost level
    for pkgDir in candidates:
      if dirExists(pkgDir):
        if subPath.len > 0:
          let pkg = readPackageJson(pkgDir)
          if not pkg.isNil and pkg.kind == JObject and pkg.hasKey("exports"):
            try:
              result = resolveExportsMap(pkgDir, pkg["exports"], subPath, opts)
              if result.len > 0:
                return result
            except CatchableError:
              discard
          let base = pkgDir / subPath
          result = probeFile(base, opts.extensions)
          if result.len == 0 and dirExists(base):
            result = resolveDirEntry(base, opts)
          if result.len > 0:
            return result
        else:
          result = resolveDirEntry(pkgDir, opts)
          if result.len > 0:
            return result
    let parent = dir.parentDir()
    if parent == dir or parent.len == 0:
      break
    dir = parent
  return ""

proc resolveSpecifier*(importer: string, specifier: string,
    opts: ResolveOpts = defaultResolveOpts()): string =
  ## Resolve `specifier` imported from `importer` to a file path.
  ## Returns "" when external, builtin, or unresolvable.
  ## Surrounding quotes are tolerated (sweetsyntax keeps them in valStr).
  let spec = stripQuotes(specifier)
  if spec.len == 0:
    return ""
  if spec in opts.externals or isBuiltinSpecifier(spec):
    return ""
  if isRelativeSpecifier(spec):
    let base =
      if os.isAbsolute(spec): spec
      else: importer.parentDir() / spec
    result = probeFile(base, opts.extensions)
    if result.len == 0 and dirExists(base):
      result = resolveDirEntry(base, opts)
    return result
  let (name, subPath) = splitPkgSpecifier(spec)
  if name.len == 0:
    return ""
  result = resolveBare(importer.parentDir(), name, subPath, opts)
