#!/bin/bash
# Apply the fairydust / DisplayPort-alt-mode config deltas on top of a seed .config.
#
# Run from the root of a checked-out kernel tree that already has a `.config` copied from the
# base image's kernel-16k config. We DO NOT set page size or the Asahi platform options here —
# those come in from the seed config, which is the whole reason we start from it (16K pages are
# mandatory on Apple Silicon). This script only adds the fairydust delta: the USB-C DP alt-mode
# path plus the Rust/GPU options fairydust expects, and it strips module signing (there is no
# Secure Boot on the m1n1/u-boot chain, so an unsigned kernel is fine and simpler).
#
# Source of the delta: bharambetejas/asahi-fairydust-display's build script, reconciled to a
# bootc image build. Keep this list reviewable — it is the only hand-maintained kernel policy.
set -euo pipefail

[[ -f .config ]] || { echo "configure-fairydust-kernel: no .config in $(pwd)"; exit 1; }

cfg() { scripts/config "$@"; }

# Rust + Asahi GPU stack (already on in Fedora's config; asserted here so a config rebase can't
# silently drop them out from under DRM_APPLE).
cfg --enable  RUST
cfg --module  DRM_ASAHI
cfg --enable  RUST_FW_LOADER_ABSTRACTIONS
cfg --enable  RUST_DRM_SCHED
cfg --enable  RUST_DRM_GEM_SHMEM_HELPER
cfg --enable  RUST_DRM_GPUVM
cfg --enable  RUST_APPLE_MAILBOX
cfg --enable  RUST_APPLE_RTKIT

# The fairydust payload: USB-C DisplayPort alt mode + the Apple DRM output driver.
cfg --module  TYPEC_DP_ALTMODE
cfg --module  TYPEC_NVIDIA_ALTMODE
cfg --module  TYPEC_TBT_ALTMODE
cfg --module  DRM_APPLE

# Housekeeping carried from the reference build.
cfg --set-str EFI_SBAT_FILE ""
cfg --disable QRTR_MHI

# No Secure Boot on Apple Silicon — drop module signing so the build needs no keys.
cfg --disable MODULE_SIG
cfg --disable MODULE_SIG_ALL
cfg --disable MODULE_SIG_FORCE
cfg --set-str MODULE_SIG_KEY ""
cfg --set-str SYSTEM_TRUSTED_KEYS ""
cfg --set-str SYSTEM_REVOCATION_KEYS ""

echo "configure-fairydust-kernel: deltas applied"
