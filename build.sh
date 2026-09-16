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

# The USB4 variant: asahi-wip-7.2 (already carries USB4/Thunderbolt + newer DP-alt drivers) with the
# 12 fairydust DP-alt *activation* commits (oldest-first; devicetree + tipd, no driver C code) cherry-
# picked on top. Keep these three in sync with .github/workflows/build-usb4.yml.
USB4_BASE_BRANCH="asahi-wip-7.2"
USB4_BASE_KREV="236788cd2602a24c703fe7bdaddaf73ef77d2027"
FAIRYDUST_DPALT_CHERRY="296c91ac1fa51a21117524561cd77eaf0c7fe62a 9c16792154f8454ccbc6a28309d57d531ced015a 7eb5629306578387dbee2add2ee4ec00239f723d 7003fe04cb40b6e16ca44726857fac2cba99ec43 bd435201b52785b50b511ae7df87d1f9a8a2714e 6f72fa4b26b42f8a88f1d17f4f0d2d482c1e93a8 eebf132beaf1f0c73b1471fa8f9b1f03aeb5f499 a54f5fe496c3fdee2615e42c8aa4018ed9f7f807 0b0e4af50f8cd1ccbec26265dab4de388a238182 cf8f09832bde2851528598ebbc3c59528348ea23 b4a562f643bba937229e21994069c4ee291c3510 ce9f2eba72c061a50b2d790450e90af3439d8c24"

build_args=(--build-arg FEDORA="$FEDORA")

if [[ $USB4 == 1 ]]; then
  TAG="${TAG:-omarchy-fairydust-kernel:$FEDORA-usb4}"
  KBRANCH="${KBRANCH:-$USB4_BASE_BRANCH}"
  [[ -n $KREV ]] || KREV="$USB4_BASE_KREV"
  build_args+=(--build-arg CHERRY="$FAIRYDUST_DPALT_CHERRY" --build-arg WITH_USB4=1)
  echo "==> USB4 build: $KBRANCH + fairydust DP-alt cherries + Apple Thunderbolt"
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
