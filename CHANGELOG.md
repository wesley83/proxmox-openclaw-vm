# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Version numbers track `SCRIPT_VERSION` in `openclaw-vm.sh`.

## [1.3.2] - 2026-09-05

Follow-up to the v1.3.1 hardware findings. Asked whether the missing free-space
check had been *removed* at some point, so the history was audited: it had not.
It never existed in this script (9 commits, no removals), and it is absent from
`proxmox-bun-vm` too, so it was not inherited and dropped in the derivation —
it was a gap, not a regression. Comparing the two scripts' full check
inventories, this one has 83 guards to the parent's 50, and every parent check
has an equal-or-stronger equivalent here.

That reframed the question usefully: rather than hunting for removed checks,
audit for *other gaps of the same class* — failures that happen expensively
late but are cheaply detectable up front. Two more turned up.

### Added

- **Host memory advisory.** The script already warned when `--cores` exceeded
  the node's CPU threads, but never compared `--memory` against available host
  RAM — an asymmetry, and the more damaging of the two, since memory the node
  does not have makes `qm start` fail outright or pushes it into swap. Reads
  `MemAvailable` from `/proc/meminfo`; warn-only, matching the cores precedent,
  because overcommit and ballooning are legitimate on a homelab node.
- **Image staging space advisory.** The cloud image is downloaded to `/tmp` on
  the node before import. On a typical Proxmox install `/` is a modest LV while
  `local-lvm` takes the rest, so a ~700 MB image can fill it — and the existing
  guard reports `Download failed: <url>`, which reads as a network problem and
  sends you debugging the wrong thing. Warns when the staging filesystem has
  under 2 G, via POSIX `df -Pk`.

### Changed

- **The image staging directory now honors `TMPDIR`** (`mktemp
  "${TMPDIR:-/tmp}/..."`, previously a hardcoded `/tmp`). This exists so the
  advisory above can offer a real remedy rather than just naming the problem;
  default behavior is unchanged.

Both advisories are fail-soft: an unreadable `/proc/meminfo` or unparseable
`df` output skips the check rather than blocking a run. Verified on real Linux
(values parse correctly) and against forced low/healthy/unreadable inputs.

## [1.3.1] - 2026-09-05

Findings from the first v1.3.0 run on real hardware (PVE 7, pve2). The run
failed at disk import because the node's `local-lvm` thin pool was out of data
space — an environmental problem, not a script defect. Everything up to that
point worked, including v1.3.0's new code, and cleanup destroyed the VM and
removed the downloaded image correctly. But the failure exposed two real gaps.

### Fixed

- **The script emitted an undocumented exit code.** `qm importdisk` was
  unguarded, so under `set -e` its own status propagated — the failed run
  exited `5`, while the README documents `0`/`1`/`2`. Seven other `qm` calls
  could leak a status the same way. The cleanup trap now normalizes any
  unexpected status to `1`, or `2` when the VM was deliberately kept, while
  preserving the deliberate signal codes `130`/`143`. Verified across raw
  statuses 0/1/2/5/77/130/143, and SIGINT/SIGTERM behavior confirmed unchanged
  from before the edit.
- **`qm importdisk` is now guarded** with an error that names the likely cause
  rather than leaving the operator with a raw LVM message: it points at
  `pvesm status --content images` and `lvs -o ...,data_percent,metadata_percent`
  and suggests `--storage <id>`.

### Added

- **Free-space advisory before the download.** The script already checked that
  the target storage is active and images-capable, with a comment explaining
  that the point was to avoid failing "at qm importdisk, AFTER the download and
  VM creation" — but it never checked free space, which is exactly how the run
  above burned a ~600 MB download plus a VM create/destroy cycle before
  failing. It now reads the `Available` column (already documented in a comment
  at the top of that section, previously unused) and warns when the storage
  reports under ~10 G, adding an `lvs` hint under 4 G.

  Deliberately **warn-only, and fail-soft**: thin pools are overprovisioned by
  design, so a low "available" figure is not reliably fatal, and an unparseable
  row skips the advisory rather than blocking a run that would have worked.
  Same posture as `get_latest_lts()`. Verified against realistic `pvesm status`
  output for a full pool, a healthy pool, an inactive row, and a missing
  storage.
- Troubleshooting entry for `Cannot create new thin volume` /
  `thin pool ... reached threshold`, including the metadata-exhaustion variant
  that fails the same way while data space still looks fine.
- Exit-code table now documents `130`/`143` and states the normalization
  guarantee. Requirements table now lists the ~10 G free-space expectation.

### Notes

- Ubuntu LTS auto-detection resolved to `resolute` and its cloud image
  downloaded and verified normally, so the pre-release-codename risk documented
  under Known Limitations did not materialize on this run.
- The KiB unit assumption for `pvesm status` columns could not be verified
  without a Proxmox host. Because the check is warn-only, a wrong assumption
  would produce a spurious warning rather than a blocked run; the next hardware
  run will confirm it.

## [1.3.0] - 2026-09-05

Compatibility pass against OpenClaw 2026.9.1 (this repo was built against
2026.7.1-2). The provisioning path needed nothing: Node version requirements,
NodeSource majors, the apt package list, and the `cmake` native-module
rationale were all reconfirmed against a live 2026.9.1 install. The defect was
somewhere nobody had re-read — the instructions the script prints *after*
provisioning.

**Not re-run on Proxmox hardware.** Verified against a live OpenClaw 2026.9.1
install, by rendering the summary block with stub values, and by host-side dry
runs of argument parsing and the guest script's argument plumbing. The last
hardware run was v1.1.0 in July 2026.

### Fixed

- **The script's closing instructions contradicted its own README, and led
  operators into a guaranteed failure.** They told you to pass
  `--gateway-bind lan` and then open `http://<vm-ip>:18789` — the one URL that
  can *never* authenticate a browser, because the Control UI mints a WebCrypto
  device identity that only exists in a secure context (HTTPS or localhost).
  The README was rewritten around this in v1.2.0 and given four working access
  paths; the script's own output was never brought in line. It now drops
  `--gateway-bind`, keeps the gateway on its loopback default, and prints a
  real step 4 with the SSH-tunnel command inline. The stale "you chose a LAN
  bind" security note — the operator never chose anything, there is no bind
  flag — is replaced with an accurate loopback + token-auth one.
- **The `--gateway-bind`/`--gateway-token` onboarding bug is resolved
  upstream.** Confirmed broken live in 2026.7.1-2 (silently ignored by the
  default onboarding flow); re-tested against 2026.9.1 (non-interactive run,
  both flags, root and non-root) and both now land correctly in
  `openclaw.json`. README step 2 and the step 3 token check are reworded from
  an unconditional "this is always broken" claim to version-aware framing. The
  sync command stays, because it is harmless and idempotent either way — and
  because `--openclaw-version` now lets you pin a release that still has the
  bug.
- **Resource-sizing figures were stale and misordered.** OpenClaw's installed
  package roughly doubled since 2026.7.1-2 (measured: 520 M alone on 2026.9.1,
  against a 778 M *combined* Node+OpenClaw figure from 2026.7.1-2). Each row
  now names the version it was measured against, and the rows are ordered so
  the cross-reference between them reads correctly.
- Corrected a comment claiming an "8-package install" (it is 10) and a stale
  footprint comment citing OpenClaw at 83.4 MiB.

### Added

- **`--openclaw-version <ver>`** — pin OpenClaw to an npm version or dist-tag
  for reproducible builds. Defaults to `latest`, so existing behavior is
  unchanged. Threaded to the guest as a third positional argument to the
  provisioning script, since that script lives in a *quoted* heredoc where host
  variables cannot expand. Validated by an anchored regex whose leading
  alphanumeric requirement is the injection barrier — it rejects `-`/`--` (npm
  flag injection) and `@`/`/` (package-spec substitution such as
  `github:owner/repo`) before the value ever reaches the runcmd YAML. The
  requested version is echoed in the startup banner and the summary.
- Adopted OpenClaw 2026.9.1 commands that supersede hand-rolled workarounds,
  all verified live: `gateway auth-token --show` (read the live token instead
  of blind-setting it), `gateway status --require-rpc` (exits non-zero when the
  probe fails, so it works in a `&&` chain), `dashboard --no-open` (prints the
  Control UI URL with the token rather than hand-assembling a `#token=`
  fragment), `gateway probe --ssh` (separates "tunnel broken" from "token
  wrong"), `doctor --lint` (a new Troubleshooting entry, with `--json` and
  `--fix`), and `gateway diagnostics export`.
- Onboarding's `--skip-ui` flag documented as the supported way past the
  first-chat step, replacing the previous "press Ctrl+C" advice.

### Changed

- **Removed the two onboarding screenshots.** They were captured on 2026.7.1-2
  and could not be re-verified: the 2026.9.1 re-check ran `--non-interactive`
  with every prompt skipped, which bypasses that sequence entirely, and the
  release added `--tui`/`--classic`/`--modern`/`--skip-ui`, implying the wizard
  changed. Step 2 now describes the flow's shape in text and says plainly that
  wording varies by release. The Control UI failure screenshot is **kept** —
  that failure mode was re-confirmed present in 2026.9.1.

### Verified unchanged against 2026.9.1

- The Control UI secure-context requirement — the string `control ui requires
  device identity (use HTTPS or localhost secure context)` and cause
  `control-ui-insecure-auth` are both still in the dist bundle. Options A–D
  remain necessary.
- The non-root gateway log path (`/tmp/openclaw-<uid>/openclaw-<date>.log`)
  used in Troubleshooting. A root-only variant without the uid suffix briefly
  looked like a regression; it does not apply to the non-root user this script
  creates.
- `koffi`, a new native dependency, ships the same
  per-platform-prebuild-with-source-fallback pattern as `@lydell/node-pty` and
  `sqlite-vec` — the `cmake` this script already installs covers the fallback,
  so the package list is unchanged.

### Deliberately not done

- Running `openclaw doctor --lint` during provisioning. Tested and rejected: at
  that point onboarding has not run, so doctor reports `Gateway auth is off or
  missing a token`, `gateway.mode is unset`, and `Gateway is only bound to
  loopback` — all three being exactly the state this script intends to leave
  behind. Wiring that into the summary would cry wolf on every successful run.
  Doctor is documented in Troubleshooting instead, where it runs after
  onboarding and its findings mean something.

## [1.2.1] - 2026-07-29

### Added

- **Option D — nginx + self-signed TLS** as a fourth Control UI access path
  in the README, alongside the SSH tunnel, Tailscale Serve, and Cloudflare
  Tunnel options from 1.2.0. Adopted after a comparative review of four
  other Proxmox+OpenClaw installer projects; one of them solves the Control
  UI's secure-context requirement by terminating a self-signed cert with
  nginx in front of the loopback-bound gateway, giving a permanent
  `https://<vm-ip>/` with no client-side tunnel to maintain. Applied our
  own hardening standard rather than copying it as-is: the reference
  implementation never `chmod`s the generated TLS private key (relies on
  default umask); ours sets `600` explicitly, and carries the same
  "this script doesn't firewall it for you" caution already given for
  `bind=lan`, since a LAN-wide HTTPS port is the same exposure class.

## [1.2.0] - 2026-07-29

`openclaw-vm.sh` itself is unchanged since this release shipped — every entry
below comes from actually running the script and completing OpenClaw
onboarding end to end on real Proxmox hardware (PVE 7, `local-lvm` + a
directory snippet storage), plus a 19-agent adversarial re-review of the code.

### Fixed

- **Critical: signal-trap resume bug.** `trap cleanup EXIT INT TERM` never
  called `exit`, so in bash the handler ran and the script *resumed*.
  Ctrl-C during the wait loop destroyed the VM, then the script silently
  kept polling the now-destroyed VM to completion and exited 2 — the code
  documented to mean "VM kept for inspection" — for a VM it had just
  destroyed. Fixed with the canonical split-trap form
  (`trap cleanup EXIT; trap 'exit 130' INT; trap 'exit 143' TERM`);
  verified live under a real SIGINT (old pattern completes all loop
  iterations and exits 0; new pattern stops immediately and exits 130).
- **`--gateway-bind` silently ignored during onboarding.** The default
  guided `openclaw onboard` flow only honors `--gateway-bind` under
  `--flow quickstart`/`--flow manual`. Every gateway installed via this
  script's documented command came up `bind=loopback` regardless of what
  was passed — confirmed live, and `gateway install` (what
  `--install-daemon` runs) has no `--bind` flag at all.
- **`--gateway-token` silently ignored during onboarding**, same failure
  class. Onboarding minted its own random token that didn't match the
  pre-generated `~/.openclaw/gateway-token` file, and `config get` redacts
  secrets so there was no way to read the real one back. Step 3 now makes
  the file token authoritative via `openclaw config set gateway.auth.token`.
- **Leading zeros parsed as octal.** `--memory 010000` passed the 2048 MB
  floor as octal `4096` while `qm` would allocate decimal `10000`;
  `--swap 0G` passed validation, skipped the disable branch (exact string
  match on bare `"0"`), and silently produced no swapfile while claiming
  one. All numeric flags now reject leading zeros.
- **YAML boolean/null injection via `--user`.** Usernames like `no`, `off`,
  `null` pass the Linux-username regex but YAML 1.1 loads them as
  booleans/`None` when unquoted in the generated user-data, silently
  attaching the account and SSH keys to a non-string. Reproduced with
  PyYAML; fixed by quoting the `name`/`password` scalars.
- **User/group assumption.** `install -o "$VM_USER" -g "$VM_USER"` assumed
  the primary group matches the username; `no_user_group` or a pre-existing
  account breaks that and aborted provisioning with
  `install: invalid group: '<user>'`. Now resolved via `id -gn`.
- **Gateway token file briefly world-readable.** A bare redirect created it
  `0644 root:root` under root's umask before the ownership/mode fix landed.
  Now created with its final mode via `install -m 600` before any content
  is written, with an assertion that fails loudly if it's ever wrong.
- **Cloud-init snippet and host log both created `0644`.** Both contain the
  console password in plaintext; the snippet can't be deleted after
  provisioning since PVE re-reads it every boot, so it stayed
  world-readable on the Proxmox node indefinitely. Both are now `0600`.
- **`cmake` and `python3` missing from the package list.** OpenClaw's own
  installer installs these unconditionally as a native-module build
  fallback; without them, a missing prebuilt binary for the guest's exact
  Node ABI/arch was an unrecoverable provisioning failure.
- **`--disk`/`--memory` floors were meaningless.** `--memory 1` and
  `--disk 512M` (the help text's own example) both passed validation and
  failed expensively later — after image download and VM creation. Real
  floors added: memory ≥ 2048 MB (recommend ≥ 4096), disk ≥ 8G (recommend
  ≥ 20G), sized from a measured install footprint (apt ≈645 MB, Node +
  OpenClaw ≈778 MB).
- **`KEEP_VM` set too late.** Only set immediately before the final exit,
  so a signal during the ~60s post-failure IP-detection grace window (or
  even after a full success) could destroy the VM the summary was about
  to report on. Now set the moment the outcome is known.
- **Storage fallback and `--storage` override both under-validated.** The
  fallback didn't filter by `--content images` (picks an unusable `dir`
  storage on ZFS-root nodes); a user-supplied `--storage` was checked only
  against static `storage.cfg`, not live `pvesm status`, so a disabled or
  other-node storage passed and failed at `qm importdisk` after the VM
  already existed.
- **`qm destroy` failure reported as success.** The cleanup trap printed
  "Destroyed VM" unconditionally even when `qm destroy` actually failed
  (e.g. a locked config from a killed mid-`importdisk` run).
- Guest-controlled text (QGA status output, guest-reported IP) is now
  sanitized before reaching the host terminal/log — a compromised guest
  package could otherwise inject terminal escapes or a malformed IP into
  the printed copy-paste SSH command.

### Added

- Swap support (`--swap`, default `2G`) — Ubuntu cloud images ship with
  none, making any memory spike an instant OOM-kill during the apt/npm
  install phases rather than a slowdown.
- `--storage <id>` flag to override disk-storage auto-detection.
- Screenshots of the three points in setup that actually surprised a real
  operator: the onboarding security disclaimer, the unexpected first-chat
  "name your agent" session, and the Control UI's misleading
  "Could not connect" error.
- Full lettered walkthrough of every `openclaw onboard` prompt (security
  disclaimer → LLM provider auth → messaging channel → web search
  provider → first-chat session), including both options — answer the
  agent's naming prompt, or Ctrl+C past it — for the optional final step.
- Line-by-line explanation of every command in step 3 (why
  `XDG_RUNTIME_DIR` is needed, what `enable --now` actually does, why
  `gateway status` matters) instead of one throwaway sentence.
- Three documented, verified Control UI access paths — SSH tunnel,
  Tailscale Serve, Cloudflare Tunnel — replacing guidance that turned out
  to be impossible: the Control UI requires a secure context (HTTPS or
  localhost) for its browser-side device identity, so
  `http://<vm-ip>:18789` can never work in a browser regardless of bind
  mode or token correctness.
- Troubleshooting entries for: SSH `Permission denied (publickey)` from
  the wrong machine, the Control UI secure-context error (with the raw
  gateway-log technique used to diagnose it), `sudo` failing under an
  expired initial password despite `NOPASSWD`, and permission
  verification commands.
- Mock-PVE test harness (stubbed `qm`/`pvesh`/`pvesm`/`qemu-img`) exercising
  the happy path and the create/resize/provision failure paths with their
  expected exit codes and destroy behavior.

### Changed

- `bind=lan` is now documented as being for native non-browser clients and
  external reverse proxies only — not for direct browser access to the
  Control UI, which needs a secure context instead.
- Resource-sizing guidance in the README replaced with measured figures
  (645 MB apt, 778 MB Node+OpenClaw) rather than estimates.

### Security

- Documented that the SSH key auto-detected and embedded is the **Proxmox
  node's** key, not the operator's own workstation — connecting from a
  different machine fails at the SSH handshake before any password prompt.
- Documented token rotation (`openssl rand -hex 32` → `gateway.auth.token`
  → `gateway restart`) for any token that may have been exposed (screen
  share, chat log, etc).

## [1.1.0] - 2026-07-29

Initial public release.

### Added

- `openclaw-vm.sh`: creates an Ubuntu cloud-image VM on Proxmox VE via
  `qm`/cloud-init, installs Node.js (NodeSource, version-gated against
  OpenClaw's documented minimums) and OpenClaw (`npm install -g`), enables
  systemd lingering so the gateway survives logout/reboot, and
  pre-generates a gateway auth token — all without ever running
  `openclaw onboard`, so no LLM API key touches this script or the
  Proxmox host log.
- Auto-detection of disk storage (preferring `local-lvm`, filtered by
  `images` content), snippet-capable storage, network bridge, and SSH key.
- Status polling via the QEMU Guest Agent rather than SSH — cloud-init's
  `chpasswd: expire: true` makes PAM reject every non-interactive SSH
  command for the new user until the password is changed interactively,
  so SSH-based polling could never have worked here.
- Cleanup trap: destroys the VM on failure before it's provisioned, and
  keeps it (via a `KEEP_VM` flag and exit code `2`) when provisioning
  itself fails, so there's something left to inspect.
- One-liner install via `curl | bash`, mirroring the parent
  [proxmox-bun-vm](https://github.com/wesley83/proxmox-bun-vm) project's
  install pattern.

Scaffolding (storage/snippet detection, cleanup trap, tee logging) is
derived from `proxmox-bun-vm`, adapted with several defect fixes documented
in the initial commit.

[1.3.2]: https://github.com/wesley83/proxmox-openclaw-vm/compare/v1.3.1...v1.3.2
[1.3.1]: https://github.com/wesley83/proxmox-openclaw-vm/compare/v1.3.0...v1.3.1
[1.3.0]: https://github.com/wesley83/proxmox-openclaw-vm/compare/v1.2.1...v1.3.0
[1.2.1]: https://github.com/wesley83/proxmox-openclaw-vm/compare/v1.2.0...v1.2.1
[1.2.0]: https://github.com/wesley83/proxmox-openclaw-vm/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/wesley83/proxmox-openclaw-vm/releases/tag/v1.1.0
