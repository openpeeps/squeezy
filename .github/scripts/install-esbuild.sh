#!/usr/bin/env bash
# Installs a pinned esbuild binary for the benchmark suite.
# esbuild ships per-platform npm tarballs (no GitHub release binaries),
# each containing a real executable at package/bin/esbuild[.exe], which
# resolves under both POSIX shells and Windows process creation (unlike
# npm's .cmd shims). Runs on all GH runner OSes with bash.
set -euo pipefail

ESBUILD_VERSION="0.25.0"

os="${RUNNER_OS:-$(uname -s)}"
arch="${RUNNER_ARCH:-$(uname -m)}"

case "$os" in
  Linux)   pkg="linux-x64" ;;
  macOS)
    case "$arch" in
      ARM64) pkg="darwin-arm64" ;;
      *)     pkg="darwin-x64" ;;
    esac
    ;;
  Windows) pkg="win32-x64" ;;
  *) echo "ERROR: unsupported OS: $os" >&2; exit 1 ;;
esac

case "$pkg" in
  win32-*) bin="esbuild.exe" ;;
  *)       bin="esbuild" ;;
esac

dest="$HOME/.benchbin"
mkdir -p "$dest"
url="https://registry.npmjs.org/@esbuild/${pkg}/-/${pkg}-${ESBUILD_VERSION}.tgz"
echo ">> downloading $url"
curl -fsSL "$url" -o /tmp/esbuild.tgz
rm -rf /tmp/esbuild-pkg
mkdir -p /tmp/esbuild-pkg
tar xzf /tmp/esbuild.tgz -C /tmp/esbuild-pkg
install -m 0755 "/tmp/esbuild-pkg/package/bin/$bin" "$dest/$bin"
rm -rf /tmp/esbuild.tgz /tmp/esbuild-pkg
echo "$dest" >> "$GITHUB_PATH"
"$dest/$bin" --version
