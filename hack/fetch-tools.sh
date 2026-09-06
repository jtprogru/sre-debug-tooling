#!/usr/bin/env bash
# Download the pinned release binaries for one image variant, verify their
# sha256 and install them into a destination directory.
#
# Usage: fetch-tools.sh <slim|full> <amd64|arm64> <dest-dir>
set -euo pipefail

# shellcheck source=hack/tools-lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/tools-lib.sh"

variant="${1:?usage: fetch-tools.sh <slim|full> <amd64|arm64> <dest-dir>}"
target_arch="${2:?usage: fetch-tools.sh <slim|full> <amd64|arm64> <dest-dir>}"
dest="${3:?usage: fetch-tools.sh <slim|full> <amd64|arm64> <dest-dir>}"

arch_vars "$target_arch"
mkdir -p "$dest"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# expected_sum <name> <arch> prints the pinned checksum or fails.
expected_sum() {
  awk -v n="$1" -v a="$2" '$1 == n && $2 == a { print $3; found = 1 } END { exit !found }' "$TOOLS_SUMS"
}

while IFS='|' read -r name entry_variant version url kind; do
  [ "$entry_variant" = "$variant" ] || continue

  url="$(expand "$url" "$version")"
  if ! want="$(expected_sum "$name" "$ARCH")"; then
    echo "no sha256 pinned for ${name}/${ARCH} - run 'make refresh-checksums'" >&2
    exit 1
  fi

  echo ">> ${name} ${version} (${ARCH})"
  file="${tmp}/$(basename "$url")"
  curl --fail --silent --show-error --location \
       --retry 3 --retry-delay 2 --max-time 600 \
       --output "$file" "$url"

  got="$(sha256_of "$file")"
  if [ "$got" != "$want" ]; then
    echo "checksum mismatch for ${name}/${ARCH}: want ${want}, got ${got}" >&2
    echo "if you bumped the version in hack/tools.list, run 'make refresh-checksums'" >&2
    exit 1
  fi

  case "$kind" in
    raw)
      install -m 0755 "$file" "${dest}/${name}"
      ;;
    tar)
      unpack="${tmp}/unpack-${name}"
      mkdir -p "$unpack"
      tar -xzf "$file" -C "$unpack"
      src="$(find "$unpack" -type f -name "$name" -print -quit)"
      if [ -z "$src" ]; then
        echo "binary '${name}' not found inside $(basename "$url")" >&2
        exit 1
      fi
      install -m 0755 "$src" "${dest}/${name}"
      rm -rf "$unpack"
      ;;
    *)
      echo "unknown kind '${kind}' for ${name}" >&2
      exit 1
      ;;
  esac
  rm -f "$file"
done < <(tools_entries)
