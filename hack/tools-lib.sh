# shellcheck shell=bash
# Shared helpers for hack/fetch-tools.sh and hack/refresh-checksums.sh.

TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_LIST="${TOOLS_DIR}/tools.list"
# shellcheck disable=SC2034  # read by hack/fetch-tools.sh and hack/refresh-checksums.sh
TOOLS_SUMS="${TOOLS_DIR}/tools.sha256"

# arch_vars <amd64|arm64> exports the placeholder values for that architecture.
arch_vars() {
  case "$1" in
    amd64) ARCH=amd64 ARCH_X=x86_64 ARCH_TRIPLE=x86_64 ARCH_X64=x64 ;;
    arm64) ARCH=arm64 ARCH_X=arm64 ARCH_TRIPLE=aarch64 ARCH_X64=arm64 ;;
    *) echo "unsupported architecture: $1" >&2; return 1 ;;
  esac
}

# expand <template> <version> substitutes the {PLACEHOLDER} tokens.
expand() {
  printf '%s' "$1" |
    sed -e "s|{VERSION}|$2|g" \
        -e "s|{ARCH_TRIPLE}|${ARCH_TRIPLE}|g" \
        -e "s|{ARCH_X64}|${ARCH_X64}|g" \
        -e "s|{ARCH_X}|${ARCH_X}|g" \
        -e "s|{ARCH}|${ARCH}|g"
}

# sha256_of <file> works on both GNU coreutils and macOS.
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# tools_entries prints the manifest without comments and blank lines.
tools_entries() {
  grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$TOOLS_LIST"
}
