# Local kernel patches

Cherry-picks carried on top of the fairydust branch that are **not** in it upstream. They are applied
only when the image is built with `--build-arg APPLY_PATCHES=1` (the `PATCHES=1 ./build.sh` shortcut);
the default build and the CI-published `:latest`/`:44` do **not** include them, so the production
kernel tracks fairydust verbatim.

Applied in filename order with `git apply` (step 2b of the `Containerfile`). The build fails loudly if
a patch no longer applies, in which case re-validate against the current branch or drop the patch.

## Current patches — AsahiLinux/linux PR #622

"drm/apple, phy: apple: Fix external display hotplug on DP alt mode"
<https://github.com/AsahiLinux/linux/pull/622> (base branch: `fairydust`)

- `0001-drm-apple-complete-swaps-before-modeset.patch`
  commit `8890ede6c7ff51d03fb8abd5c06ad43b10238a0a` — complete swaps the DCP discards while
  `valid_mode` is false, so a hotplug no longer blocks every commit ~10s in `flip_done`.
- `0002-phy-apple-atc-park-pipe-handler.patch`
  commit `d7df0a30ada086aa67892f262ba9b16f59d81fac` — park the PIPE handler before the Type-C mux
  switch, so a hotplugged DP link trains instead of falling back to USB2-only.

Why carried locally: the PR was **closed unmerged** — not for being wrong (tested working on an M2
Air) but because it was developed with LLM assistance, which the Asahi Generative AI Policy forbids
(the patches keep their `Assisted-by:` trailers). It targets exactly the DP-alt hotplug/wake failures
seen on M1 (t8103): `valid_mode:0` + swallowed swaps, and the atcphy pipehandler race that tears the
link down on replug.

Validated to apply cleanly against fairydust `ce9f2eba72c061a50b2d790450e90af3439d8c24` (2026-09-16);
`build.sh` pins `KREV` to that revision for a patched build so `git apply` is guaranteed to land. If a
fairydust force-push has GC'd that SHA, override `KREV=<new tip>` and re-check that the patches still
apply.
