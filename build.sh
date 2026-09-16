#!/bin/bash
# Build the fairydust kernel context image. Run on a native aarch64 (Apple Silicon) host.
#
#   ./build.sh                       # -> omarchy-fairydust-kernel:44        (fairydust HEAD, no patches)
#   PATCHES=1 ./build.sh             # -> omarchy-fairydust-kernel:44-dp622  (HEAD + patches/*.patch)
#   ENGINE=podman FEDORA=44 ./build.sh
#   KREV=<sha> ./build.sh            # pin an exact fairydust revision
#
# The result is a FROM-scratch image holding only /usr/lib/modules/<kver>/. Inspect it with:
#   $ENGINE create ... && $ENGINE export ... | tar t | grep vmlinuz
#
# PATCHES=1 layers the local patches under patches/ (see patches/README.md) on top of the branch and
# tags the image `-dp622` so it never overwrites the clean :44 the CI publishes; it also pins KREV to
# the revision those patches were validated against so `git apply` is guaranteed to land.
set -euo pipefail

FEDORA="${FEDORA:-44}"
ENGINE="${ENGINE:-docker}"
PATCHES="${PATCHES:-0}"
KREV="${KREV:-}"
REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"

# Revision the carried patches were validated against (patches/README.md). A patched build pins to it
# by default so `git apply` lands; override KREV=... to try another tip.
PATCHES_BASE_KREV="ce9f2eba72c061a50b2d790450e90af3439d8c24"

build_args=(--build-arg FEDORA="$FEDORA")

if [[ $PATCHES == 1 ]]; then
  TAG="${TAG:-omarchy-fairydust-kernel:$FEDORA-dp622}"
  [[ -n $KREV ]] || KREV="$PATCHES_BASE_KREV"
  build_args+=(--build-arg APPLY_PATCHES=1)
  echo "==> patched TEST build: patches/*.patch on fairydust ${KREV:0:12}"
else
  TAG="${TAG:-omarchy-fairydust-kernel:$FEDORA}"
fi

[[ -n $KREV ]] && build_args+=(--build-arg KREV="$KREV")

if [[ "$(uname -m)" != "aarch64" && "$(uname -m)" != "arm64" ]]; then
  echo "warning: host is $(uname -m); the fairydust kernel must be built on aarch64" >&2
fi

echo "==> $ENGINE build $TAG (Fedora $FEDORA base)"
exec "$ENGINE" build \
  -f "$REPO_ROOT/Containerfile" \
  "${build_args[@]}" \
  -t "$TAG" "$REPO_ROOT"
