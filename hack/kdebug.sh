#!/usr/bin/env bash
# Thin wrapper around `kubectl debug` so the flags you need at 3am are not
# something you have to remember.
#
#   kdebug.sh pod  <namespace> <pod> [container]   attach an ephemeral container
#   kdebug.sh net  <namespace> <pod> [container]   same, but root + NET_ADMIN/NET_RAW
#   kdebug.sh node <node>                          privileged pod on a node
#   kdebug.sh run  [namespace]                     throwaway standalone pod
#
# Environment:
#   DEBUG_IMAGE    image to use (default: ghcr.io/jtprogru/sre-debug-tooling:latest)
#   DEBUG_PROFILE  kubectl debug profile (default: general)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${DEBUG_IMAGE:-ghcr.io/jtprogru/sre-debug-tooling:latest}"
PROFILE="${DEBUG_PROFILE:-general}"

usage() {
  awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"
  exit "${1:-1}"
}

case "${1:-}" in
  pod|net)
    mode="$1"; shift
    ns="${1:?namespace required}"; pod="${2:?pod required}"; container="${3:-}"
    args=(debug --namespace "$ns" "$pod" --stdin --tty --image "$IMAGE" --profile "$PROFILE")
    # Without --target the ephemeral container sees its own PID namespace and
    # its own filesystem. The pod network is shared either way.
    [ -n "$container" ] && args+=(--target "$container")
    # The image runs as uid 1000, so the netadmin profile alone hands you
    # capabilities you cannot use. The custom spec puts you back at uid 0.
    [ "$mode" = "net" ] && args+=(--custom "${HERE}/deploy/profile-netadmin.yaml")
    exec kubectl "${args[@]}" -- bash
    ;;
  node)
    shift
    node="${1:?node required}"
    exec kubectl debug "node/${node}" --stdin --tty --image "$IMAGE" --profile sysadmin -- bash
    ;;
  run)
    shift
    ns="${1:-default}"
    exec kubectl run "debug-$(date +%s)" --namespace "$ns" --rm --stdin --tty \
      --image "$IMAGE" --restart Never -- bash
    ;;
  -h|--help)
    usage 0
    ;;
  *)
    usage 1
    ;;
esac
