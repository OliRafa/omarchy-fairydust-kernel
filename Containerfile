# omarchy-fairydust-kernel — an Asahi Apple-Silicon kernel as a bootc CONTEXT IMAGE.
#
# Default build: AsahiLinux/linux's experimental `fairydust` branch (USB-C DisplayPort alt-mode,
# 7.1.13). It ships ONLY the kernel module tree (/usr/lib/modules/<kver>/{vmlinuz,dtb,...}) on a
# `FROM scratch` base — nothing else. omarchy-atomic's core Containerfile consumes it exactly like
# it consumes the Homebrew image: `FROM <this> AS fairydust` + `COPY --from=fairydust`, then removes
# the stock kernel-16k. See README.md for the consumer snippet.
#
# It can also build ANY branch (KBRANCH) with optional cherry-picks (CHERRY) and Apple USB4/TB
# enabled (WITH_USB4). That is how the `-usb4` variant is built: asahi-wip-7.2 (which already carries
# USB4/Thunderbolt AND newer DP-alt drivers than 7.1.13 fairydust) + the 12 fairydust DP-alt
# *activation* commits (devicetree + tipd, no driver C code) cherry-picked on top. See build.sh.
#
# Build natively on aarch64 (Apple Silicon or an arm64 CI runner) — no cross-compilation here.

ARG BASE=quay.io/fedora-asahi-remix-atomic-desktops/base-atomic
ARG FEDORA=44

FROM ${BASE}:${FEDORA} AS kbuild

# 1) Toolchain. Kernel + Rust (the Asahi GPU abstractions need it) + arm64 build deps.
#    dwarves(pahole) is required for BTF; clang/bindgen for the Rust bindings.
RUN dnf -y install \
      gcc make flex bison bc openssl-devel elfutils-libelf-devel dwarves \
      ncurses-devel perl python3 diffutils findutils xz gzip cpio tar git-core \
      rust rust-src rustfmt clang llvm bindgen-cli \
 && dnf clean all

# 2) Source. KBRANCH selects the branch to build; KREV pins an exact revision for reproducibility.
#    A shallow clone is enough — we never need full history. Empty KREV takes the branch tip.
ARG KGIT=https://github.com/AsahiLinux/linux.git
ARG KBRANCH=fairydust
ARG KREV=
WORKDIR /build
RUN set -eux; \
    git clone --branch "$KBRANCH" --single-branch --depth 1 "$KGIT" linux; \
    if [ -n "$KREV" ] && [ "$(git -C linux rev-parse HEAD)" != "$KREV" ]; then \
      git -C linux fetch --depth 1 origin "$KREV"; \
      git -C linux checkout -q "$KREV"; \
    fi; \
    echo "building $KBRANCH at $(git -C linux rev-parse HEAD)"

# 2b) Optionally cherry-pick commits on top of the checked-out branch. This reconstructs the fairydust
#     DP-alt *activation* (its 12 devicetree + tipd commits — no driver C code) on top of a NEWER base
#     than fairydust itself, e.g. asahi-wip-7.2, which already carries the newer DP-alt drivers AND the
#     USB4/Thunderbolt host driver that 7.1.13 fairydust lacks. CHERRY is a space-separated list of
#     SHAs reachable from CHERRY_FROM (fetched shallowly). Empty (the default, and the CI :latest
#     build) cherry-picks nothing. A conflict fails the build here, in minutes, before the compile.
ARG CHERRY=
ARG CHERRY_FROM=fairydust
WORKDIR /build/linux
RUN set -eux; \
    if [ -n "$CHERRY" ]; then \
      git config user.email build@omarchy.local; git config user.name "omarchy-build"; \
      git fetch --depth 50 origin "$CHERRY_FROM"; \
      echo "cherry-picking onto $(git rev-parse --short HEAD): $CHERRY"; \
      git cherry-pick -x $CHERRY \
        || { echo "cherry-pick FAILED — commits do not apply cleanly to $KBRANCH"; git cherry-pick --abort 2>/dev/null || true; exit 1; }; \
      echo "cherry-picked $(set -- $CHERRY; echo $#) commit(s) onto $KBRANCH"; \
    else \
      echo "CHERRY empty — building $KBRANCH verbatim"; \
    fi

# 3) Config: seed from the base image's own kernel-16k config, then apply the fairydust DP-alt deltas
#    (and, with WITH_USB4=1, the Apple USB4/Thunderbolt options CONFIG_USB4 + CONFIG_USB4_APPLE_SOC).
#    Seeding from the shipped config carries 16K pages + every Asahi platform option forward untouched;
#    we only add deltas. Fail hard if 16K pages did not survive olddefconfig — a 4K kernel will not
#    boot correctly on Apple Silicon (IOMMU alignment).
ARG WITH_USB4=0
WORKDIR /build/linux
COPY configure-fairydust-kernel.sh /tmp/configure-fairydust-kernel.sh
RUN set -eux; \
    base_cfg="$(find /usr/lib/modules -maxdepth 2 -name config | head -1)"; \
    [ -n "$base_cfg" ] || { echo "no base kernel-16k config found under /usr/lib/modules"; exit 1; }; \
    echo "seeding .config from $base_cfg"; \
    cp "$base_cfg" .config; \
    bash /tmp/configure-fairydust-kernel.sh; \
    if [ "$WITH_USB4" = 1 ]; then \
      echo "enabling Apple USB4 / Thunderbolt (USB4 + USB4_APPLE_SOC)"; \
      scripts/config --module USB4 --module USB4_APPLE_SOC; \
    fi; \
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
#    /kstage/usr (the usr-merged module root) so the shipped tree has correct modules.dep.
#    fairydust.kver hands the consumer the version string so its swap step never has to guess.
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
    echo "staged kernel $kver"

# 6) Ship ONLY the staged kernel tree. `FROM scratch` keeps this a pure context image.
FROM scratch
COPY --from=kbuild /kstage/ /
