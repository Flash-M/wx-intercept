#!/usr/bin/env bash
# Scripts/uninstall.sh — wx-intercept uninstallation script
#
# Restores the original WeChat binary from the backup created during install
# and removes the injected dylib from WeChat's Frameworks directory.
#
# Usage:
#   make uninstall
#   — or —
#   bash Scripts/uninstall.sh [/path/to/WeChat.app]

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
DYLIB_NAME="WxIntercept.dylib"
WECHAT_APP="${1:-/Applications/WeChat.app}"
FRAMEWORKS_DIR="${WECHAT_APP}/Contents/Frameworks"
MACOS_DIR="${WECHAT_APP}/Contents/MacOS"
WECHAT_BINARY=""

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info() { printf "\033[0;34m[wx-intercept]\033[0m %s\n" "$*"; }
ok()   { printf "\033[0;32m[wx-intercept]\033[0m %s\n" "$*"; }
warn() { printf "\033[0;33m[wx-intercept]\033[0m WARNING: %s\n" "$*"; }
die()  { printf "\033[0;31m[wx-intercept]\033[0m ERROR: %s\n" "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
info "Starting uninstallation…"

[[ -d "${WECHAT_APP}" ]] || die "WeChat.app not found at '${WECHAT_APP}'."

if pgrep -x "WeChat" >/dev/null 2>&1; then
    die "WeChat is currently running. Please quit WeChat before uninstalling."
fi

# Locate WeChat binary
if [[ -f "${MACOS_DIR}/WeChat" ]]; then
    WECHAT_BINARY="${MACOS_DIR}/WeChat"
elif [[ -f "${MACOS_DIR}/wechat" ]]; then
    WECHAT_BINARY="${MACOS_DIR}/wechat"
else
    die "Cannot find the WeChat binary inside ${MACOS_DIR}."
fi

# ---------------------------------------------------------------------------
# Restore from backup
# ---------------------------------------------------------------------------
BACKUP="${WECHAT_BINARY}.wxi_backup"
if [[ -f "${BACKUP}" ]]; then
    info "Restoring original binary from backup…"
    cp -f "${BACKUP}" "${WECHAT_BINARY}"
    rm -f "${BACKUP}"
    ok "Original binary restored."
else
    warn "No backup found at '${BACKUP}'."
    warn "The WeChat binary may still contain the injected load command."
    warn "If WeChat behaves unexpectedly, reinstall WeChat from the Mac App Store."
fi

# ---------------------------------------------------------------------------
# Remove injected dylib
# ---------------------------------------------------------------------------
DYLIB_PATH="${FRAMEWORKS_DIR}/${DYLIB_NAME}"
if [[ -f "${DYLIB_PATH}" ]]; then
    info "Removing ${DYLIB_NAME} from ${FRAMEWORKS_DIR}…"
    rm -f "${DYLIB_PATH}"
    ok "Dylib removed."
else
    warn "${DYLIB_NAME} not found in Frameworks (already removed?)."
fi

# ---------------------------------------------------------------------------
# Re-sign the restored binary
# ---------------------------------------------------------------------------
if command -v codesign >/dev/null 2>&1; then
    info "Re-signing restored WeChat binary (ad-hoc)…"
    codesign --force --deep --sign - "${WECHAT_APP}" 2>/dev/null || \
        codesign --force --sign - "${WECHAT_BINARY}"
    ok "Re-signed."
else
    warn "codesign not found — the binary may fail Gatekeeper checks."
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
ok "Uninstallation complete. WeChat has been restored to its original state."
