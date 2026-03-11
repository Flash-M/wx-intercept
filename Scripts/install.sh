#!/usr/bin/env bash
# Scripts/install.sh — wx-intercept installation script
#
# What it does:
#   1. Locates WeChat.app
#   2. Copies WxIntercept.dylib into WeChat's Frameworks directory
#   3. Uses `insert_dylib` to add a LC_LOAD_DYLIB load command to the WeChat
#      binary so the dylib is loaded automatically on every launch
#   4. Re-signs WeChat with an ad-hoc signature (required on Apple Silicon)
#
# Prerequisites:
#   - Xcode Command Line Tools (codesign, lipo)
#   - insert_dylib  (https://github.com/Tyilo/insert_dylib)
#     Install via:  brew install insert_dylib
#                   OR build from source and put on your PATH
#
# Usage:
#   make install
#   — or —
#   bash Scripts/install.sh [/path/to/WeChat.app]

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
DYLIB_NAME="WxIntercept.dylib"
DYLIB_SRC="${DYLIB_SRC:-$(dirname "$0")/../${DYLIB_NAME}}"
WECHAT_APP="${1:-/Applications/WeChat.app}"
FRAMEWORKS_DIR="${WECHAT_APP}/Contents/Frameworks"
MACOS_DIR="${WECHAT_APP}/Contents/MacOS"
WECHAT_BINARY=""

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()  { printf "\033[0;34m[wx-intercept]\033[0m %s\n" "$*"; }
ok()    { printf "\033[0;32m[wx-intercept]\033[0m %s\n" "$*"; }
warn()  { printf "\033[0;33m[wx-intercept]\033[0m WARNING: %s\n" "$*"; }
die()   { printf "\033[0;31m[wx-intercept]\033[0m ERROR: %s\n" "$*" >&2; exit 1; }

require_tool() {
    command -v "$1" >/dev/null 2>&1 || die "'$1' not found. $2"
}

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
info "Starting installation…"

# Check that the dylib has been built
[[ -f "${DYLIB_SRC}" ]] || die "${DYLIB_NAME} not found at '${DYLIB_SRC}'. Run 'make' first."

# Check that WeChat is installed
[[ -d "${WECHAT_APP}" ]] || die "WeChat.app not found at '${WECHAT_APP}'. Pass the correct path as the first argument."

require_tool insert_dylib \
    "Please install it: brew install insert_dylib  or  https://github.com/Tyilo/insert_dylib"
require_tool codesign "Install Xcode Command Line Tools."

# Locate the WeChat binary (handles both single-arch and universal bundles)
if [[ -f "${MACOS_DIR}/WeChat" ]]; then
    WECHAT_BINARY="${MACOS_DIR}/WeChat"
elif [[ -f "${MACOS_DIR}/wechat" ]]; then
    WECHAT_BINARY="${MACOS_DIR}/wechat"
else
    die "Cannot find the WeChat binary inside ${MACOS_DIR}."
fi
info "WeChat binary: ${WECHAT_BINARY}"

# Make sure WeChat is not running
if pgrep -x "WeChat" >/dev/null 2>&1; then
    die "WeChat is currently running. Please quit WeChat before installing."
fi

# ---------------------------------------------------------------------------
# Install dylib
# ---------------------------------------------------------------------------
info "Copying ${DYLIB_NAME} into ${FRAMEWORKS_DIR}…"
mkdir -p "${FRAMEWORKS_DIR}"
cp -f "${DYLIB_SRC}" "${FRAMEWORKS_DIR}/${DYLIB_NAME}"
ok "Copied."

DYLIB_INSTALL_PATH="@executable_path/../Frameworks/${DYLIB_NAME}"

# ---------------------------------------------------------------------------
# Backup original binary (only once)
# ---------------------------------------------------------------------------
BACKUP="${WECHAT_BINARY}.wxi_backup"
if [[ ! -f "${BACKUP}" ]]; then
    info "Backing up original binary to ${BACKUP}…"
    cp -f "${WECHAT_BINARY}" "${BACKUP}"
    ok "Backup created."
else
    warn "Backup already exists at ${BACKUP}. Skipping backup step."
fi

# ---------------------------------------------------------------------------
# Inject load command (only if not already present)
# ---------------------------------------------------------------------------
if otool -L "${WECHAT_BINARY}" 2>/dev/null | grep -q "${DYLIB_NAME}"; then
    warn "Load command for ${DYLIB_NAME} already exists in binary. Skipping injection."
    warn "If you want to re-inject, first run 'make uninstall' then 'make install'."
else
    info "Injecting load command with insert_dylib…"
    # insert_dylib writes the patched binary to the same path when --inplace is used
    if insert_dylib \
        --inplace \
        --strip-codesig \
        --all-yes \
        "${DYLIB_INSTALL_PATH}" \
        "${WECHAT_BINARY}"; then
        ok "Load command injected."
    else
        die "insert_dylib failed. The original binary has not been modified (backup is safe)."
    fi
fi

# ---------------------------------------------------------------------------
# Re-sign (ad-hoc) — required for notarization bypass on Apple Silicon
# ---------------------------------------------------------------------------
info "Re-signing WeChat binary (ad-hoc)…"
codesign --force --deep --sign - "${WECHAT_APP}" 2>/dev/null || \
    codesign --force --sign - "${WECHAT_BINARY}"
ok "Re-signed."

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
ok "Installation complete!"
info "Launch WeChat and verify that message recall interception is active."
info "Recalled messages will appear in-chat and as macOS notifications."
info ""
info "To uninstall:  make uninstall  (or bash Scripts/uninstall.sh)"
