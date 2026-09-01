#!/usr/bin/env bash
#
# marlow installer — https://getmarlowai.com
#
#   curl -fsSL https://getmarlowai.com/install.sh | bash
#
# Downloads the latest standalone `marlow` binary for your platform from the
# project's GitHub Releases, verifies its SHA-256, and drops it on your PATH.
# No Node, no Bun, no package manager required.
#
# Environment overrides:
#   MARLOW_INSTALL_DIR   where to install (default: ~/.marlow/bin)
#   MARLOW_VERSION       pin a specific version (default: latest from manifest)
#   MARLOW_DIST_URL      release repository url (default: https://github.com/cod3nest/marlow)
#   GITHUB_TOKEN         only needed while the release repository is private
#
# Pin a version when piping:
#   curl -fsSL https://getmarlowai.com/install.sh | bash -s -- --version 0.1.0

set -euo pipefail

DIST_URL="${MARLOW_DIST_URL:-https://github.com/cod3nest/marlow}"
INSTALL_DIR="${MARLOW_INSTALL_DIR:-$HOME/.marlow/bin}"
VERSION="${MARLOW_VERSION:-}"
BIN_NAME="marlow"
# Release tags are prefixed so the CLI's tags stay distinct from anything else
# the monorepo may tag. Must match CLI_TAG_PREFIX in packages/core/src/org.ts.
TAG_PREFIX="cli-v"

# --- pretty output -----------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RESET=$'\033[0m'
else
  BOLD=''; DIM=''; RED=''; GREEN=''; YELLOW=''; RESET=''
fi
info()  { printf '%s\n' "$*"; }
step()  { printf '%s==>%s %s\n' "$BOLD" "$RESET" "$*"; }
warn()  { printf '%swarning:%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
error() { printf '%serror:%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

# --- args --------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSION="${2:-}"; shift 2 ;;
    --version=*) VERSION="${1#*=}"; shift ;;
    --dir) INSTALL_DIR="${2:-}"; shift 2 ;;
    --dir=*) INSTALL_DIR="${1#*=}"; shift ;;
    -h|--help)
      grep '^#' "$0" 2>/dev/null | sed 's/^# \{0,1\}//' || true
      exit 0 ;;
    *) error "unknown option: $1" ;;
  esac
done

# --- downloader --------------------------------------------------------------
# GITHUB_TOKEN is only consulted while the release repository is private. curl
# is required in that case: a release asset URL answers with a redirect to a
# pre-signed objects host, and curl drops the Authorization header when the
# redirect crosses hosts, where wget forwards it — sending the caller's token
# to a host that already has a signature and does not need it.
TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}"

if command -v curl >/dev/null 2>&1; then
  # macOS ships bash 3.2, where `"${auth[@]}"` on an EMPTY array is an unbound
  # variable under `set -u`. The `+` expansion drops the argument entirely when
  # the array is unset, which is the no-token case — i.e. every public install.
  if [ -n "$TOKEN" ]; then auth=(-H "Authorization: Bearer $TOKEN"); fi
  download() { curl -fsSL ${auth[@]+"${auth[@]}"} "$1"; }
  download_to() { curl -fsSL ${auth[@]+"${auth[@]}"} -o "$2" "$1"; }
elif command -v wget >/dev/null 2>&1; then
  [ -n "$TOKEN" ] && error "a token was supplied but curl is not installed — install curl, or unset GITHUB_TOKEN if the release repository is public"
  download() { wget -qO- "$1"; }
  download_to() { wget -qO "$2" "$1"; }
else
  error "need curl or wget to install marlow"
fi

# --- detect platform ---------------------------------------------------------
os="$(uname -s)"
case "$os" in
  Darwin) os="darwin" ;;
  Linux)  os="linux" ;;
  *) error "unsupported OS: $os. marlow ships native binaries for macOS and Linux." ;;
esac

arch="$(uname -m)"
case "$arch" in
  arm64|aarch64) arch="arm64" ;;
  x86_64|amd64)  arch="x64" ;;
  *) error "unsupported architecture: $arch" ;;
esac

target="${os}-${arch}"

# --- resolve version ---------------------------------------------------------
# `releases/latest/download/<asset>` is GitHub's own alias for whatever release
# is latest, so the manifest is fetched without knowing a tag first. The binary
# is then pulled from its explicit tag rather than the same alias: between the
# two requests a new release can become latest, and taking the binary from the
# alias would install a version this script never verified a checksum for.
if [ -z "$VERSION" ]; then
  step "Fetching latest version"
  manifest_url="$DIST_URL/releases/latest/download/manifest.json"
  manifest="$(download "$manifest_url")" || error "could not reach $manifest_url"
  VERSION="$(printf '%s' "$manifest" \
    | grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' \
    | head -n1 \
    | sed -E 's/.*:[[:space:]]*"([^"]+)".*/\1/')"
  [ -n "$VERSION" ] || error "could not parse version from manifest.json"
fi

file="${BIN_NAME}-${target}"
url="$DIST_URL/releases/download/${TAG_PREFIX}${VERSION}/${file}"

info "${DIM}  platform ${target}${RESET}"
info "${DIM}  version  ${VERSION}${RESET}"
info "${DIM}  source   ${url}${RESET}"

# --- download ----------------------------------------------------------------
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
bin="$tmp/$BIN_NAME"

step "Downloading marlow ${VERSION}"
download_to "$url" "$bin" || error "download failed: $url
  If the release repository is private, export GITHUB_TOKEN with a token that can read it."

# --- verify checksum ---------------------------------------------------------
expected="$(download "${url}.sha256" 2>/dev/null | awk '{print $1}' || true)"
if [ -n "$expected" ]; then
  if command -v sha256sum >/dev/null 2>&1; then
    actual="$(sha256sum "$bin" | awk '{print $1}')"
  elif command -v shasum >/dev/null 2>&1; then
    actual="$(shasum -a 256 "$bin" | awk '{print $1}')"
  else
    actual=""
    warn "no sha256 tool found; skipping checksum verification"
  fi
  if [ -n "$actual" ] && [ "$actual" != "$expected" ]; then
    error "checksum mismatch — expected $expected, got $actual"
  fi
  [ -n "$actual" ] && info "${DIM}  checksum ok${RESET}"
else
  warn "no published checksum; skipping verification"
fi

# --- install -----------------------------------------------------------------
step "Installing to ${INSTALL_DIR}/${BIN_NAME}"
mkdir -p "$INSTALL_DIR"
chmod +x "$bin"
mv -f "$bin" "$INSTALL_DIR/$BIN_NAME"

# --- PATH --------------------------------------------------------------------
on_path=0
case ":$PATH:" in *":$INSTALL_DIR:"*) on_path=1 ;; esac

if [ "$on_path" -eq 0 ]; then
  # Pick the shell rc to extend based on the login shell.
  shell_name="$(basename "${SHELL:-}")"
  case "$shell_name" in
    zsh) rc="$HOME/.zshrc" ;;
    bash)
      # macOS login shells source .bash_profile, not .bashrc.
      rc="$HOME/.bashrc"
      [ "$os" = "darwin" ] && [ -e "$HOME/.bash_profile" ] && rc="$HOME/.bash_profile"
      ;;
    fish) rc="$HOME/.config/fish/config.fish" ;;
    *) rc="$HOME/.profile" ;;
  esac

  line="export PATH=\"$INSTALL_DIR:\$PATH\""
  [ "$shell_name" = "fish" ] && line="fish_add_path $INSTALL_DIR"

  if [ -n "$rc" ] && { [ ! -e "$rc" ] || ! grep -qF "$INSTALL_DIR" "$rc"; }; then
    mkdir -p "$(dirname "$rc")"
    printf '\n# marlow\n%s\n' "$line" >> "$rc"
    info ""
    info "Added ${INSTALL_DIR} to your PATH in ${BOLD}${rc}${RESET}."
    info "Restart your shell or run: ${BOLD}source ${rc}${RESET}"
  else
    info ""
    info "Add ${INSTALL_DIR} to your PATH:"
    info "  ${BOLD}${line}${RESET}"
  fi
fi

# --- done --------------------------------------------------------------------
installed_version="$("$INSTALL_DIR/$BIN_NAME" --version 2>/dev/null || echo "$VERSION")"
info ""
info "${GREEN}✓${RESET} marlow ${installed_version} installed."
info ""
info "Get started:"
info "  ${BOLD}marlow login${RESET}      log in via your browser"
info "  ${BOLD}marlow --help${RESET}     see every command"
info ""
