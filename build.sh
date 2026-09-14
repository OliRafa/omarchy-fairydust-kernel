#!/bin/bash
# Build the fairydust kernel context image. Run on a native aarch64 (Apple Silicon) host.
#
#   ./build.sh                       # -> omarchy-fairydust-kernel:44
#   ENGINE=podman FEDORA=44 ./build.sh
#
# The result is a FROM-scratch image holding only /usr/lib/modules/<kver>/. Inspect it with:
#   $ENGINE run --rm --entrypoint '' omarchy-fairydust-kernel:44 true   # (nothing to run; scratch)
# or just export and list:
#   $ENGINE create ... && $ENGINE export ... | tar t | grep vmlinuz
set -euo pipefail

FEDORA="${FEDORA:-44}"
ENGINE="${ENGINE:-docker}"
REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
TAG="${TAG:-omarchy-fairydust-kernel:$FEDORA}"

if [[ "$(uname -m)" != "aarch64" && "$(uname -m)" != "arm64" ]]; then
  echo "warning: host is $(uname -m); the fairydust kernel must be built on aarch64" >&2
fi

echo "==> $ENGINE build $TAG (fairydust HEAD, Fedora $FEDORA base)"
exec "$ENGINE" build \
  -f "$REPO_ROOT/Containerfile" \
  --build-arg FEDORA="$FEDORA" \
  -t "$TAG" "$REPO_ROOT"
