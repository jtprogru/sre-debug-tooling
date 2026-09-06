#!/usr/bin/env bash
# Verify that a built image actually carries what it promises. Run inside the
# image with hack/ mounted:
#
#   docker run --rm -v "$PWD/hack:/hack:ro" IMAGE bash /hack/smoke-test.sh slim
set -uo pipefail

variant="${1:-slim}"
manifest=/usr/local/share/sre-debug-tooling/tools.list
failures=0

fail() {
  echo "FAIL: $*" >&2
  failures=$((failures + 1))
}

have() {
  command -v "$1" >/dev/null 2>&1 || fail "$1 is missing"
}

# Binaries that come from apt.
SLIM_BINARIES=(
  bash curl dig ethtool file getent hexdump host htop ip iperf3 iptables
  jq less lsof mtr nc nft nmap nslookup openssl ping pkill ps socat ss
  strace tcpdump tmux tracepath traceroute vi wget xxd conntrack
)
FULL_BINARIES=(
  atop bpftrace fio gdb iftop ioping iostat ipvsadm kcat mount.cifs mount.nfs
  mysql ncdu objdump pidstat psql python3 readelf redis-cli rsync sar ssh tshark
)

echo "== binaries from apt"
for b in "${SLIM_BINARIES[@]}"; do have "$b"; done
if [ "$variant" = "full" ]; then
  for b in "${FULL_BINARIES[@]}"; do have "$b"; done
fi

echo "== pinned release binaries"
if [ ! -r "$manifest" ]; then
  fail "manifest $manifest is missing from the image"
else
  while IFS='|' read -r name entry_variant version _ _; do
    case "$variant:$entry_variant" in
      slim:full) continue ;;
    esac
    if ! command -v "$name" >/dev/null 2>&1; then
      fail "$name is missing"
      continue
    fi
    # Every fetched binary must be built for the architecture we are running on.
    want_machine="$(uname -m)"
    case "$want_machine" in
      x86_64) want_machine="x86-64" ;;
    esac
    if ! file -L "$(command -v "$name")" | grep -qi -- "$want_machine"; then
      fail "$name is not a $(uname -m) binary: $(file -Lb "$(command -v "$name")")"
    fi
    echo "   $name $version ok"
  done < <(grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$manifest")
fi

echo "== behaviour"
# glibc NSS is the whole reason this image is not Alpine: getent must resolve
# through the same path the application does.
getent hosts localhost >/dev/null || fail "getent cannot resolve localhost"
curl -V | grep -q HTTP2 || fail "curl was built without HTTP/2"
openssl version >/dev/null || fail "openssl is broken"
kubectl version --client -o json >/dev/null 2>&1 || fail "kubectl does not run"
[ "$(id -u)" = "1000" ] || fail "default user is $(id -u), expected 1000"
[ -w "$HOME" ] || fail "HOME ($HOME) is not writable"

if [ "$failures" -gt 0 ]; then
  echo "smoke test FAILED: $failures problem(s) in variant '$variant'" >&2
  exit 1
fi
echo "smoke test passed for variant '$variant'"
