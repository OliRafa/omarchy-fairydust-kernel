# omarchy-fairydust-kernel — the Asahi "fairydust" kernel as a bootc CONTEXT IMAGE.
#
# fairydust is AsahiLinux/linux's experimental branch that adds USB-C DisplayPort alt-mode
# output on Apple Silicon MacBooks. It is dev-only and unsupported upstream. This image builds
# it and ships ONLY the kernel module tree (/usr/lib/modules/<kver>/{vmlinuz,dtb,...}) on a
# `FROM scratch` base — nothing else. omarchy-atomic's core Containerfile consumes it exactly
# like it consumes the Homebrew image: `FROM <this> AS fairydust` + `COPY --from=fairydust`,
# then removes the stock kernel-16k. See README.md for the consumer snippet.
#
# Tracks fairydust HEAD by design: each build clones whatever is newest, so it is NOT
# reproducible. The CI workflow rebuilds nightly. Build natively on aarch64 (Apple Silicon or an
# arm64 CI runner) — this is not set up for cross-compilation.

ARG BASE=quay.io/fedora-asahi-remix-atomic-desktops/base-atomic
ARG FEDORA=44

FROM ${BASE}:${FEDORA} AS kbuild

# 1) Toolchain. Kernel + Rust (fairydust needs the Rust GPU abstractions) + arm64 build deps.
#    dwarves(pahole) is required for BTF; clang/bindgen for the Rust bindings.
RUN dnf -y install \
      gcc make flex bison bc openssl-devel elfutils-libelf-devel dwarves \
      ncurses-devel perl python3 diffutils findutils xz gzip cpio tar git-core \
      rust rust-src rustfmt clang llvm bindgen-cli \
 && dnf clean all

# 2) Source: fairydust HEAD. Shallow single-branch clone — we never need history.
#    KREV pins the exact revision the CI gate resolved, so the image's revision label matches what
#    actually compiled even if the branch advances mid-run. Empty (e.g. a local ./build.sh) just
#    takes the branch tip — still "track HEAD".
ARG KGIT=https://github.com/AsahiLinux/linux.git
ARG KREV=
WORKDIR /build
RUN set -eux; \
    git clone --branch fairydust --single-branch --depth 1 "$KGIT" linux; \
    if [ -n "$KREV" ] && [ "$(git -C linux rev-parse HEAD)" != "$KREV" ]; then \
      git -C linux fetch --depth 1 origin "$KREV"; \
      git -C linux checkout -q "$KREV"; \
    fi; \
    echo "building fairydust at $(git -C linux rev-parse HEAD)"

# 2b) Optional local patches on top of fairydust HEAD (e.g. cherry-picks of fixes not yet in the
#     branch — see patches/README.md). OFF by default so the published image tracks the branch
#     verbatim and the CI workflow (which never sets this) keeps shipping a clean :latest/:44. Turn
#     it on for a private test image with `--build-arg APPLY_PATCHES=1` (the PATCHES=1 ./build.sh
#     shortcut, which also pins KREV to the patches' validated base). Applied with `git apply`, so a
#     branch that has drifted past the patches fails the build loudly instead of miscompiling.
ARG APPLY_PATCHES=0
WORKDIR /build/linux
COPY patches/ /tmp/kpatches/
RUN set -eux; \
    if [ "$APPLY_PATCHES" = 1 ]; then \
      applied=0; \
      for p in /tmp/kpatches/*.patch; do \
        [ -e "$p" ] || { echo "APPLY_PATCHES=1 but patches/ has no *.patch"; exit 1; }; \
        echo "applying $(basename "$p")"; \
        git apply --verbose "$p" \
          || { echo "FAILED to apply $(basename "$p") — fairydust HEAD drifted past it; pin KREV to the patches' base (patches/README.md)"; exit 1; }; \
        applied=$((applied + 1)); \
      done; \
      echo "applied $applied local patch(es) on top of fairydust HEAD"; \
    else \
      echo "APPLY_PATCHES=0 — building fairydust HEAD verbatim, no local patches"; \
    fi

# 3) Config: seed from the base image's own kernel-16k config, then apply the fairydust deltas.
#    Seeding from the shipped config is what carries 16K pages and every Asahi platform option
#    forward untouched — we only add the DP-alt-mode delta on top. Fail hard if 16K pages did not
#    survive olddefconfig: a 4K kernel will not boot correctly on Apple Silicon (IOMMU alignment).
WORKDIR /build/linux
COPY configure-fairydust-kernel.sh /tmp/configure-fairydust-kernel.sh
RUN set -eux; \
    base_cfg="$(find /usr/lib/modules -maxdepth 2 -name config | head -1)"; \
    [ -n "$base_cfg" ] || { echo "no base kernel-16k config found under /usr/lib/modules"; exit 1; }; \
    echo "seeding .config from $base_cfg"; \
    cp "$base_cfg" .config; \
    bash /tmp/configure-fairydust-kernel.sh; \
    make olddefconfig; \
    make rustavailable; \
    make olddefconfig; \
    grep -q '^CONFIG_ARM64_16K_PAGES=y' .config \
      || { echo "16K pages not enabled after olddefconfig — refusing to build a 4K kernel"; exit 1; }

# 4) Compile. Kept as its own layer — the expensive, stable step — so a tweak to the staging
#    step below reuses this from the build cache instead of recompiling the whole kernel.
RUN make -j"$(nproc)"

# 5) Stage a kver-addressed module tree at its real path under /kstage.
#    vmlinuz: prefer arch/arm64/boot/vmlinuz.efi (the EFI-ZBOOT self-decompressing image with an
#    EFI stub — what Fedora arm64 ships and what systemd-boot needs on this UEFI/m1n1 chain). Fall
#    back to the raw Image only if ZBOOT is off. DTBs go in dtb/apple/ (the vendor subdir Fedora's
#    kernel-16k uses and that update-m1n1 globs — DTBS=/usr/lib/modules/<kver>/dtb, then apple/*.dtb;
#    a flat dtb/ makes update-m1n1 find nothing and skip the devicetree). depmod runs against
#    /kstage/usr (the
#    usr-merged module root) so the shipped tree has correct modules.dep. fairydust.kver hands the
#    consumer the version string so its swap step never has to guess.
RUN set -eux; \
    kver="$(make -s kernelrelease)"; \
    dst="/kstage/usr/lib/modules/$kver"; \
    make INSTALL_MOD_PATH=/kstage/usr INSTALL_MOD_STRIP=1 modules_install; \
    if [ -f arch/arm64/boot/vmlinuz.efi ]; then img=arch/arm64/boot/vmlinuz.efi; \
    else img=arch/arm64/boot/Image; fi; \
    echo "shipping vmlinuz from $img"; \
    install -Dm644 "$img" "$dst/vmlinuz"; \
    install -Dm644 .config "$dst/config"; \
    install -Dm644 System.map "$dst/System.map"; \
    install -d "$dst/dtb/apple"; \
    install -m644 arch/arm64/boot/dts/apple/*.dtb "$dst/dtb/apple/"; \
    depmod -b /kstage/usr "$kver"; \
    printf '%s\n' "$kver" > /kstage/usr/lib/modules/fairydust.kver; \
    echo "staged fairydust kernel $kver"

# 6) Ship ONLY the staged kernel tree. `FROM scratch` keeps this a pure context image.
FROM scratch
COPY --from=kbuild /kstage/ /
