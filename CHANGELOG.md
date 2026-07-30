# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Version numbers track `SCRIPT_VERSION` in `openclaw-vm.sh`.

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

[1.2.1]: https://github.com/wesley83/proxmox-openclaw-vm/compare/v1.2.0...v1.2.1
[1.2.0]: https://github.com/wesley83/proxmox-openclaw-vm/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/wesley83/proxmox-openclaw-vm/releases/tag/v1.1.0
