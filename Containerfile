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
ARG KGIT=https://github.com/AsahiLinux/linux.git
WORKDIR /build
RUN git clone --branch fairydust --single-branch --depth 1 "$KGIT" linux

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

# 4) Build, then stage a kver-addressed module tree at its real path under /kstage.
#    vmlinuz: prefer arch/arm64/boot/vmlinuz.efi (the EFI-ZBOOT self-decompressing image with an
#    EFI stub — what Fedora arm64 ships and what systemd-boot needs on this UEFI/m1n1 chain). Fall
#    back to the raw Image only if ZBOOT is off. DTBs go in dtb/ (singular) because omarchy-atomic
#    step 5 points update-m1n1 at /usr/lib/modules/<kver>/dtb. depmod runs against /kstage so the
#    shipped tree has correct modules.dep. fairydust.kver hands the consumer the version string so
#    its swap step never has to guess.
RUN set -eux; \
    make -j"$(nproc)"; \
    kver="$(make -s kernelrelease)"; \
    dst="/kstage/usr/lib/modules/$kver"; \
    make INSTALL_MOD_PATH=/kstage/usr INSTALL_MOD_STRIP=1 modules_install; \
    if [ -f arch/arm64/boot/vmlinuz.efi ]; then img=arch/arm64/boot/vmlinuz.efi; \
    else img=arch/arm64/boot/Image; fi; \
    echo "shipping vmlinuz from $img"; \
    install -Dm644 "$img" "$dst/vmlinuz"; \
    install -Dm644 .config "$dst/config"; \
    install -Dm644 System.map "$dst/System.map"; \
    install -d "$dst/dtb"; \
    install -m644 arch/arm64/boot/dts/apple/*.dtb "$dst/dtb/"; \
    depmod -b /kstage "$kver"; \
    printf '%s\n' "$kver" > /kstage/usr/lib/modules/fairydust.kver; \
    echo "staged fairydust kernel $kver"

# 5) Ship ONLY the staged kernel tree. `FROM scratch` keeps this a pure context image.
FROM scratch
COPY --from=kbuild /kstage/ /
