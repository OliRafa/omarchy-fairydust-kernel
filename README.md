# omarchy-fairydust-kernel

Builds the Asahi Linux **fairydust** kernel — `AsahiLinux/linux`'s experimental branch that adds USB-C **DisplayPort alt-mode** output on Apple Silicon MacBooks — and ships it as a bootc **context image** for [omarchy-atomic](../omarchy-atomic) to swap in.

It contains nothing but the kernel module tree on a `FROM scratch` base:

```
/usr/lib/modules/<kver>/
  vmlinuz          # EFI-ZBOOT image (vmlinuz.efi), or raw Image if ZBOOT is off
  config
  System.map
  dtb/*.dtb        # Apple devicetrees (singular "dtb" — update-m1n1 reads this path)
  kernel/ ...      # stripped modules + modules.dep
/usr/lib/modules/fairydust.kver   # the built version string, for the consumer's swap step
```

Consumed exactly the way omarchy-atomic already consumes the Homebrew image: `FROM <this> AS fairydust` + `COPY --from=fairydust`.

## Status & caveats

- **Experimental / unsupported.** fairydust is a dev branch; the Asahi team offers no support and it may lag mainline. Expect to rebuild when it moves.
- **Tracks HEAD — not reproducible.** Every build clones whatever is newest on the branch. CI rebuilds nightly. If you ever need a frozen image, pin a commit in the `git clone` step (swap `--branch fairydust` for a `git checkout <sha>`) and drop the nightly cron.
- **16K pages are mandatory** on Apple Silicon. The build seeds `.config` from the base image's own `kernel-16k` config (which carries 16K pages and every Asahi platform option) and only layers the DP-alt-mode delta on top. The build **fails hard** if `CONFIG_ARM64_16K_PAGES=y` does not survive `olddefconfig`.
- **No Secure Boot** on the m1n1/u-boot chain, so the kernel is built unsigned — no keys needed.
- **aarch64 only.** Build on Apple Silicon or an arm64 CI runner; there is no cross-compile path here.

## Build locally

```bash
./build.sh                    # -> omarchy-fairydust-kernel:44
ENGINE=podman FEDORA=44 ./build.sh
```

Config policy — the only hand-maintained kernel knobs — lives in [`configure-fairydust-kernel.sh`](configure-fairydust-kernel.sh). It is the fairydust delta lifted from `bharambetejas/asahi-fairydust-display`, reconciled to a container build (we drop that script's `make install` / `update-m1n1` / `grub2-mkconfig` steps — those belong to the consumer, below).

## Consuming it from omarchy-atomic

In `images/core/Containerfile`, add the image as a stage near the top and swap the kernel **before step 3c** (the initramfs rebuild), so 3c regenerates the initramfs against fairydust and step 5's m1n1/DTBS wiring carries it unchanged:

```dockerfile
ARG FDK_IMAGE=ghcr.io/<owner>/omarchy-fairydust-kernel:latest
FROM ${FDK_IMAGE} AS fairydust

# ... FROM ${BASE}:${FEDORA} and existing steps ...

# 3a) Swap the stock kernel-16k for the fairydust build. MUST precede step 3c.
COPY --from=fairydust /usr/lib/modules /usr/lib/modules
RUN set -eux; \
    newkver="$(cat /usr/lib/modules/fairydust.kver)"; \
    # Force-remove the stock kernel-16k RPMs. asahi-platform-metapackage may hold the meta, so
    # this is best-effort; the rm below is the authoritative cleanup.
    rpm -e --nodeps kernel-16k-modules-core kernel-16k-core kernel-16k-modules kernel-16k 2>/dev/null || true; \
    # Delete any leftover module tree that is not the fairydust one, so step 3c's
    # `find … -name vmlinuz | head -1` can only resolve to fairydust.
    for d in /usr/lib/modules/*/; do \
      k="$(basename "$d")"; \
      [ "$k" = "$newkver" ] && continue; \
      [ -e "$d/vmlinuz" ] || continue; \
      echo "removing non-fairydust kernel tree: $k"; rm -rf "$d"; \
    done; \
    depmod -a "$newkver"; \
    rm -f /usr/lib/modules/fairydust.kver; \
    test "$(find /usr/lib/modules -maxdepth 2 -name vmlinuz | wc -l)" = 1
```

Then build the image variant as usual (`./images/build.sh core`). Everything downstream — the composefs initramfs (3c), systemd-boot entries, and `omarchy-apply-m1n1.service` / `DTBS=/usr/lib/modules/$(uname -r)/dtb` (5) — is already kver-agnostic and picks up fairydust automatically.

## Verify on hardware

fairydust's payload is the boot/display path itself, so automated build checks can't confirm it — verify on a real Mac:

1. `file /usr/lib/modules/<kver>/vmlinuz` — confirm it matches the format the base's own vmlinuz uses (EFI-ZBOOT `vmlinuz.efi` on Fedora arm64). If the base ships a differently-formatted image and this one won't boot, that's the first thing to reconcile in the Containerfile's step 4.
2. Boot the image, then check DP-alt: `modinfo typec_displayport` loads, and an external display over USB-C lights up.
3. `bootc status` shows the fairydust image booted, and `uname -r` is the fairydust `<kver>`.
