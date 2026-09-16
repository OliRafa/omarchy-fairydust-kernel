#!/bin/bash
# Build an Asahi kernel context image for omarchy-atomic. Run on a native aarch64 host.
#
#   ./build.sh                # -> omarchy-fairydust-kernel:44        (fairydust DP-alt branch, 7.1.13)
#   USB4=1 ./build.sh         # -> omarchy-fairydust-kernel:44-usb4   (asahi-wip-7.2 + the 12 fairydust
#                             #    DP-alt commits + Apple USB4/Thunderbolt; DP-alt on 7.2 drivers)
#   ENGINE=podman FEDORA=44 ./build.sh
#   KBRANCH=<branch> KREV=<sha> ./build.sh    # build an arbitrary branch/revision
#
# FROM-scratch image holding only /usr/lib/modules/<kver>/. The USB4 build tags `-usb4` so it never
# overwrites the clean :44 the CI publishes for fairydust HEAD.
set -euo pipefail

FEDORA="${FEDORA:-44}"
ENGINE="${ENGINE:-docker}"
USB4="${USB4:-0}"
KBRANCH="${KBRANCH:-}"
KREV="${KREV:-}"
REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"

# The USB4 variant: asahi-wip-7.2 verbatim + Apple USB4/Thunderbolt enabled. asahi-wip-7.2 already
# carries the newer DP-alt drivers AND a *proper* CD321x DP-alt path (cd321x_typec_update_mode via the
# typec mux) that SUPERSEDES fairydust's tipd HPD hack — so the fairydust DP-alt commits are not
# cherry-picked here (they conflict and would fight 7.2's implementation). This build therefore also
# tests whether 7.2's native DP-alt path drives the monitor without any fairydust hack. Keep the pin
# in sync with .github/workflows/build-usb4.yml.
USB4_BASE_BRANCH="asahi-wip-7.2"
USB4_BASE_KREV="236788cd2602a24c703fe7bdaddaf73ef77d2027"

build_args=(--build-arg FEDORA="$FEDORA")

if [[ $USB4 == 1 ]]; then
  TAG="${TAG:-omarchy-fairydust-kernel:$FEDORA-usb4}"
  KBRANCH="${KBRANCH:-$USB4_BASE_BRANCH}"
  [[ -n $KREV ]] || KREV="$USB4_BASE_KREV"
  build_args+=(--build-arg WITH_USB4=1)
  echo "==> USB4 build: $KBRANCH + Apple Thunderbolt (7.2 native DP-alt, no fairydust cherries)"
else
  TAG="${TAG:-omarchy-fairydust-kernel:$FEDORA}"
  KBRANCH="${KBRANCH:-fairydust}"
fi

build_args+=(--build-arg KBRANCH="$KBRANCH")
[[ -n $KREV ]] && build_args+=(--build-arg KREV="$KREV")

if [[ "$(uname -m)" != "aarch64" && "$(uname -m)" != "arm64" ]]; then
  echo "warning: host is $(uname -m); this kernel must be built on aarch64" >&2
fi

echo "==> $ENGINE build $TAG (Fedora $FEDORA base)"
exec "$ENGINE" build \
  -f "$REPO_ROOT/Containerfile" \
  "${build_args[@]}" \
  -t "$TAG" "$REPO_ROOT"
