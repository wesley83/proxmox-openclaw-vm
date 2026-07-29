# 🦞 **openclaw-vm**
### _Automatic OpenClaw-Ready Ubuntu VM Installer for Proxmox VE_
Created by **Wesley Faulkner**

---

## 🚀 Overview

`openclaw-vm.sh` is a one-command installer that creates a fully configured **Ubuntu VM** on **Proxmox VE** and automatically installs:

- 🟢 **Node.js** (from NodeSource — version-verified against OpenClaw's minimums)
- 🦞 **OpenClaw** ([openclaw/openclaw](https://github.com/openclaw/openclaw)) — the personal AI assistant
- 🔐 SSH access for a customizable user (default: `openclaw`)
- ⏱️ **systemd lingering**, so the gateway daemon survives logout and starts at boot
- 🎟️ A pre-generated gateway auth token (created *inside* the VM, never in host logs)
- 📦 Cloud-init provisioning + QEMU Guest Agent
- 📝 Logging, status reporting, and error handling

**No template VM required** — the script downloads the official Ubuntu Cloud Image and builds everything from scratch.

> **Onboarding is deliberately NOT automated.** No LLM API key is ever handled by this script, so no secret can land in the Proxmox host log. The script finishes by printing the exact commands to complete setup over SSH.

---

## ⚠️ Status

**Verified on real Proxmox VE hardware (PVE 7).** A full run against a `local-lvm` + directory-snippet-storage node completed end to end: disk import/resize on thin-LVM, cloud-init, Node v26.5.1, `openclaw 2026.7.1-2` installed, gateway token generated, provisioning confirmed via QEMU Guest Agent — exit 0. Before that, the guest-side provisioning also ran green in an isolated Ubuntu 26.04 rootfs, and the host side was exercised against a mock PVE covering the happy path and three failure paths with correct exit codes, plus ShellCheck and cloud-init schema validation. Onboarding (`openclaw onboard`) and the gateway daemon itself are still unexercised past this point. See [Known Limitations](#-known-limitations).

---

## 🧩 One-liner Install

Run this directly on any **Proxmox VE node** as **root**:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/wesley83/proxmox-openclaw-vm/main/openclaw-vm.sh)"
```

Pass flags after `--`:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/wesley83/proxmox-openclaw-vm/main/openclaw-vm.sh)" -- --memory 16384 --cores 8
```

Or clone and run locally — recommended for a first run, since `--debug` output goes to the log:

```bash
git clone https://github.com/wesley83/proxmox-openclaw-vm.git
cd proxmox-openclaw-vm
bash openclaw-vm.sh --debug
```

The script will:

- Detect storage, snippet storage, bridge, SSH keys, and the next free VMID
- Download and verify the Ubuntu cloud image
- Create the VM, import and resize the disk
- Provision Node.js + OpenClaw via cloud-init
- Poll provisioning status via the QEMU Guest Agent
- Print your onboarding instructions

---

## 🧰 Requirements

| Requirement | Description |
|------------|-------------|
| Proxmox VE 7/8/9 | Runs directly on a node (not inside a VM) |
| Snippets storage | A storage with **Snippets** content enabled *(once only — see below)* |
| SSH key | `/root/.ssh/id_ed25519.pub` or `id_rsa.pub` **on the Proxmox node** (or pass `--ssh-key`). This is the node's own key, not your desktop's — see the note below |
| `qm`, `pvesh`, `pvesm`, `curl`, `qemu-img`, `ip`, `awk` | Pre-installed on Proxmox; verified by the script |
| `python3` | Optional but recommended — used for JSON parsing, with fallbacks throughout |
| Network access | `cloud-images.ubuntu.com` and `api.launchpad.net` (host); `archive.ubuntu.com`/`security.ubuntu.com` or your apt mirror, `deb.nodesource.com`, and the npm registry (guest). On an egress-filtered network, blocking the apt mirrors fails provisioning *and* blanks QGA status polling, since `qemu-guest-agent` is one of the apt packages |

### Enable Snippets (Required Once)

Proxmox GUI →
**Datacenter → Storage → local → Edit → Check `Snippets` → Save**

This is the most common reason a first run fails immediately.

---

## ⚙️ Options

| Flag | Meaning | Default |
|------|---------|---------|
| `-m`, `--memory <MB>` | VM RAM. Minimum `2048`, warns below `4096` | `8192` |
| `-c`, `--cores <N>` | CPU cores (≥ 1). Warns if it exceeds the node's CPU threads | `4` |
| `-d`, `--disk <SIZE>` | Disk size with suffix. Minimum `8G`, warns below `20G`; must also exceed the image's ~3.5 GiB virtual size, since `qm resize` cannot shrink | `40G` |
| `-s`, `--swap <SIZE>` | Swapfile size, or `0` to disable. Cloud images ship with **no swap** | `2G` |
| `-u`, `--ubuntu <codename>` | Ubuntu codename (`resolute`, `noble`, `jammy`, …) | latest active LTS (auto-detected; falls back to `noble`) |
| `-n`, `--node <major>` | Node.js major version | `26` (supported: `22 24 25 26`) |
| `--user <name>` | VM username (lowercase, starts with a–z or `_`, ≤ 32 chars) | `openclaw` |
| `--storage <id>` | Proxmox storage for the VM disk | `local-lvm` if present, else first active storage with `images` content |
| `--ssh-key <path>` | SSH public key file (must end in `.pub`; multiple keys supported) | `/root/.ssh/id_ed25519.pub` (or `id_rsa.pub`) |
| `--debug` | Enable bash debug tracing (`set -x`) | off |
| `-h`, `--help` | Show help and exit | — |

### Example

```bash
bash openclaw-vm.sh --memory 16384 --cores 8 --disk 80G --node 24 --user assistant
```

---

## 🔐 Default VM Configuration

| Setting | Value |
|---------|-------|
| OS | Ubuntu Cloud Image (latest LTS, auto-detected) |
| User | `openclaw` (customizable via `--user`), passwordless sudo |
| Auth | Your root SSH public key; random initial console password printed in the summary |
| Hostname | `openclaw-<VMID>` (also what appears in DHCP leases) |
| Network | DHCP via `vmbr0` (or first available bridge) |
| CPU / Machine | `host` / `q35` |
| Autostart | `--onboot 1` — this is an always-on assistant |
| Guest Agent | Installed and started (used for status polling and IP detection) |
| Node.js | NodeSource, version-verified against OpenClaw's minimums |
| Build toolchain | `build-essential python3 cmake` — matches what OpenClaw's own `install.sh` installs on Debian/Ubuntu |
| OpenClaw | `npm install -g openclaw@latest` |
| Gateway port | `18789` (not yet listening — set during onboarding) |

### Why `cmake` is pre-installed

OpenClaw's main native dependencies (`@lydell/node-pty`, `sqlite-vec`) ship per-platform **prebuilt** binaries, so a normal install compiles nothing. But when a prebuild is missing for the running Node ABI or architecture, npm falls back to building from source, which needs `cmake`.

Upstream's `install.sh` handles this two ways: it installs `build-essential python3 make g++ cmake` unconditionally on Linux, *and* it greps failed npm logs for `cmake: command not found` / `Failed to build llama.cpp` to install the toolchain and retry. This script calls `npm` directly rather than going through `install.sh`, so it gets neither remedy — pre-installing the toolchain is what keeps that fallback from becoming an unrecoverable provisioning failure.

### Resource sizing

Measured footprint, so you can size deliberately rather than guess:

| Component | Disk |
|---|---|
| Ubuntu cloud image, booted | ~2.2 G |
| apt packages, all 10 incl. `build-essential` + `cmake` toolchain (**measured**) | 645 M |
| Node.js (NodeSource) + OpenClaw incl. its 56 dependency trees and npm cache (**measured**) | 778 M |
| **Measured total on top of the base image** | **~1.4 G (≈3.6 G with the booted base)** |
| **With headroom for logs, state, and updates** | **~5 G is the planning number** |

Hence the `8G` hard floor and `20G` warning. The `40G` default leaves room for logs, state, conversation history, and a browser later.

**Swap:** Ubuntu cloud images ship with **zero** swap, which makes a memory spike an instant OOM-kill rather than a slowdown. The script adds a `2G` swapfile via cloud-init's `mounts` module. Ordering was verified against the real module list: `growpart` → `resizefs` → `mounts` all run in the `cloud_init` stage, *before* `package_update_upgrade_install` and `runcmd` in `cloud_final` — so the disk is already grown and swap is already active during the apt and npm installs, which are the actual memory spikes. Disable with `--swap 0`.

**Disk growth** is automatic: `growpart` and `resizefs` are image-level cloud-init modules, so they still run even though `--cicustom` replaces the user-data.

### Browser automation is *not* included

Nothing here downloads a browser. `openclaw` depends on `playwright-core`, which does **not** fetch Chromium at install time, and upstream's `install.sh` contains no browser handling at all. If you enable browser automation later, budget for installing a browser and its system libraries yourself — the default `40G` disk and `8192` MB RAM leave headroom for it.

---

## 🏁 After the Script Finishes

The script installs OpenClaw but does **not** onboard it. Finish over SSH:

### 1. Connect

```bash
ssh <user>@<vm-ip>
```

> **Run this from the Proxmox node, not your desktop** — the embedded key is `/root/.ssh/id_ed25519.pub` (or `id_rsa.pub`) **on the node**, so only the node's own key is authorized. Connecting from elsewhere fails with `Permission denied (publickey)` before any password prompt even appears. To connect directly from your own machine going forward, add its public key to `~/.ssh/authorized_keys` on the VM (or re-run with `--ssh-key` pointing at a file containing both keys, one per line — multiple keys are supported), once you're in via the node.

> **First login forces a password change.** Have the console password from the summary ready — PAM asks for it as the "current" password even with SSH key auth.

### 2. Onboard

```bash
openclaw onboard --install-daemon --gateway-bind lan --gateway-token "$(cat ~/.openclaw/gateway-token)"
```

The wizard will ask for your LLM API key.

> **About the token:** the script pre-generates `~/.openclaw/gateway-token`, but **nothing reads that file automatically** — OpenClaw reads auth from `gateway.auth` in `~/.openclaw/openclaw.json`, env vars, CLI flags, or an explicitly configured SecretRef. Passing `--gateway-token` is what links them. If your OpenClaw version lacks that flag, onboarding mints its own token instead — either way the **authoritative** token afterwards is `gateway.auth.token` in `openclaw.json`.

A gateway token is not optional for a LAN bind: **non-loopback binds refuse to start without a valid auth path** (fail-closed by design).

### 3. Start the gateway

```bash
export XDG_RUNTIME_DIR=/run/user/$(id -u)
systemctl --user enable --now openclaw-gateway.service
openclaw gateway status
```

`XDG_RUNTIME_DIR` must be exported before any `systemctl --user` call on a headless box or it can't find the session bus. Lingering is already enabled by the script, so the gateway survives logout and starts at boot.

### 4. Use it

- **Control UI:** `http://<vm-ip>:18789`
- **Logs:** `journalctl --user -u openclaw-gateway -f`
- **Config:** `~/.openclaw/openclaw.json`

---

## ✅ Post-Install Verification

Run these **on the Proxmox node** — note they use the guest agent, not SSH:

```bash
# 1. VM is running
qm status <VMID>

# 2. Provisioning succeeded (prints installed versions)
qm guest exec <VMID> -- cat /var/log/openclaw-install.ok

# 3. Full provisioning log
qm guest exec <VMID> -- tail -n 40 /var/log/openclaw-provision.log

# 4. Cloud-init finished cleanly
qm guest exec <VMID> -- cloud-init status --long
```

### Exit codes

| Code | Meaning |
|------|---------|
| `0` | Provisioning confirmed OK |
| `1` | Setup failed before provisioning began (anywhere up through VM start) — the VM, if it existed, is auto-destroyed. The host log always remains, and the cloud-init snippet remains if it was already written |
| `2` | VM created and **deliberately kept**, but provisioning failed or went unconfirmed |

Exit `2` is not a crash. It exists so scripted callers see a non-zero status while the VM survives for inspection.

---

## 🐞 Troubleshooting

### ❗ "No storage with 'snippets' content found"
Enable snippets: **Datacenter → Storage → local → Edit → check `Snippets`**.

### ❗ "Storage 'X' does not support VM disk images"
The auto-selected storage can't hold VM disks. Pick one explicitly:

```bash
bash openclaw-vm.sh --storage local-zfs
```

### ❗ "Permission denied (publickey)" when connecting to the VM
You're almost certainly connecting from the wrong machine. The embedded SSH key is auto-detected from **the Proxmox node** (`/root/.ssh/id_ed25519.pub` or `id_rsa.pub`), not from wherever you're typing the `ssh` command. This fails at the handshake, before any password prompt — it's unrelated to the password-expiry issues below.

Fix: SSH in **from the Proxmox node itself** first (its key is the one that was embedded), then append your own workstation's public key to `~/.ssh/authorized_keys` on the VM so you can connect directly next time. Or pass `--ssh-key` at creation time pointing at a file with both keys (one per line).

### ❗ "--disk 512M is not larger than the cloud image's virtual size"
`qm resize` treats a bare size as absolute and cannot shrink. Use something larger than ~3.5 GiB — `40G` is the default for a reason.

### ❗ Script says UNCONFIRMED but the VM looks fine
Status polling goes through `qm guest exec`. If the agent responds to `ping` but exec is blocked or slow, the install may have succeeded anyway. Check directly:

```bash
qm guest exec <VMID> -- cat /var/log/openclaw-install.ok
```

### ❗ "Password change required but no TTY available."
Expected. Cloud-init expires the initial password, and until you change it interactively, PAM refuses **all** non-interactive SSH commands for that user — even with valid key auth. Log in interactively once (`ssh <user>@<vm-ip>`) and set a new password. This is exactly why the script polls via the guest agent instead of SSH.

### ❗ "sudo: PAM error: Authentication token manipulation error"
The same root cause, and it clears the same way. While the initial password is expired, `sudo` fails for that user **even though the account has `NOPASSWD: ALL`** — `NOPASSWD` skips the auth stack, but PAM's *account* stack still rejects an expired password. Verified on Ubuntu 26.04: `sudo` fails before the password change and succeeds immediately after.

Nothing in provisioning is affected (it all runs as root), and normal OpenClaw use needs no `sudo` at all — but a command like `ssh <user>@<vm-ip> 'sudo ...'` will fail confusingly until you have logged in once interactively and set a new password.

### ❗ Permissions: what needs to be writable
Everything OpenClaw writes at runtime lives under `~/.openclaw/` (`state`, `logs`, `plugins`, `openclaw.json`), which the script creates as `0700` owned by the VM user. The npm global install under `/usr/lib/node_modules` is root-owned and stays read-only to the user — that is correct and expected, because nothing writes there at runtime. **Installing OpenClaw plugins does not require `sudo`.**

If the gateway token is ever unreadable, check ownership:

```bash
stat -c '%U %G %a' ~/.openclaw ~/.openclaw/gateway-token
# expect: <user> <group> 700   and   <user> <group> 600
```

The provisioning script asserts both of these and fails loudly rather than leaving you with a token you cannot read.

### ❗ "openclaw: command not found" — or a failed install
```bash
qm guest exec <VMID> -- cat /var/log/openclaw-install.fail
qm guest exec <VMID> -- tail -n 50 /var/log/openclaw-provision.log
```

### ❗ Gateway won't start after a reboot
Check lingering is enabled:

```bash
loginctl show-user <user> --property=Linger
```

Should print `Linger=yes`. If not: `sudo loginctl enable-linger <user>`.

### ❗ Could not detect VM IP
Detection tries the bridge neighbor table (matched by MAC) and the guest agent. If both miss, the VM is almost certainly fine — find it via the console (`ip a`) or your router's DHCP leases under the hostname `openclaw-<VMID>`.

### ❗ Script aborted, VM auto-deleted
Failures *before* provisioning trigger cleanup: the VM is stopped, destroyed, and the temp image removed. Check `/var/log/openclaw-vm-<VMID>.log`.

---

## 🔒 Security — Read Before Exposing the Gateway

The default guidance in this README uses `--gateway-bind lan`, which listens on **`0.0.0.0`**. OpenClaw's docs are blunt: *"Never expose the Gateway unauthenticated on 0.0.0.0."*

- Keep `gateway.auth.mode = "token"`. Non-loopback binds are fail-closed and will refuse to start without auth — that's a feature, don't work around it.
- **This script does not configure a firewall.** Restrict port 18789 to a tight source-IP allowlist yourself.
- The docs prefer **Tailscale** over a LAN bind. Note these are two different mechanisms:
  - **Tailscale Serve** — gateway stays on loopback, Tailscale proxies HTTPS in front (`openclaw gateway --tailscale serve`). *This is what the docs recommend.*
  - **Tailnet bind** — `--gateway-bind tailnet` listens directly on the tailnet IP, no Serve layer.
- For loopback-only access instead, onboard with `--gateway-bind loopback` and tunnel:
  ```bash
  ssh -L 18789:localhost:18789 <user>@<vm-ip>
  ```

The initial **console password is printed to the host log** (`/var/log/openclaw-vm-<VMID>.log`). It's needed for console fallback and must be changed on first login. Both the log and the cloud-init snippet are created `0600` (v1.2.0+); if you ran an earlier version, tighten the old files once:

```bash
chmod 600 /var/log/openclaw-vm-*.log /var/lib/vz/snippets/openclaw-*.yaml
```

---

## ⚠️ Known Limitations

### 🧪 Not yet validated on real hardware
The guest-side install has been executed for real in an Ubuntu 26.04 rootfs (see Status), but the Proxmox side has only run against stubs. Still untested end-to-end: the `qm`/QGA plumbing on a real node, and the `--gateway-token` flag on your OpenClaw version (documented upstream, but onboarding has not been executed here).

### 🖥️ amd64 only
The cloud image URL is hard-coded to `amd64`. Edit `-server-cloudimg-amd64.img` → `-arm64.img` for ARM hosts.

### 🚫 Live migration disabled (`--cpu host`)
Best performance, but blocks live migration between hosts with different CPUs. Offline migration works. To change: `qm set <VMID> --cpu kvm64`.

### 🔄 Latest LTS is auto-detected
Queries Launchpad for the newest active LTS, falling back to `noble`. **Risk:** once the next `.04` enters Active Development (~6 months pre-release) it is flagged active and gets picked before its cloud image exists — the failure is a loud 404 from `curl`. Pin with `--ubuntu <codename>` to bypass.

### 🧹 No automatic teardown on success
Cleans up after failure, not after a successful run. See [Useful Commands](#-useful-commands).

### 📄 Snippet files accumulate
`qm destroy` does not remove `<snippet-dir>/openclaw-<VMID>.yaml`. They pile up across retries — and each contains that VM's initial console password, so clean up the ones belonging to destroyed VMs.

---

## 🛠️ Useful Commands

On the **Proxmox node**:

```bash
# Lifecycle
qm status <VMID>
qm start <VMID>
qm shutdown <VMID>              # graceful
qm stop <VMID>                  # hard power-off
qm reboot <VMID>

# Access
qm terminal <VMID>              # serial console (Ctrl+O to exit)
ssh <user>@<vm-ip>

# Inspection (no SSH needed)
qm config <VMID>
qm guest exec <VMID> -- cat /var/log/openclaw-install.ok
qm guest exec <VMID> -- tail -n 40 /var/log/openclaw-provision.log
cat /var/log/openclaw-vm-<VMID>.log

# Complete teardown
qm stop <VMID>
qm destroy <VMID> --purge
rm -f <snippet-dir>/openclaw-<VMID>.yaml
```

Inside the **VM**:

```bash
node --version
openclaw --version
openclaw doctor
openclaw gateway status
systemctl --user status openclaw-gateway.service
journalctl --user -u openclaw-gateway -f
```

---

## 🏗️ Design Notes

A few things in this script look odd and are load-bearing. Before "simplifying" any of them, know what they prevent:

- **Status is polled via the QEMU Guest Agent, never SSH.** `chpasswd: expire: true` makes PAM reject every no-TTY SSH command for the user until the password is changed interactively. SSH-based polling *cannot* succeed — it would stall the full timeout and falsely report failure on every run.
- **The cloud-init user-data is assembled in three heredocs** (interpolated → quoted → interpolated). The provisioning script lives inside the quoted one so every `$` and backtick stays literal, eliminating a whole class of escaping bugs.
- **The imported disk volid is read back from `qm config`**, not reconstructed. Directory/NFS storages produce `storage:VMID/vm-VMID-disk-0.raw`, and the disk index is the lowest *free* one — a guess can silently attach a stale orphan.
- **The apt lock timeout is written to `apt.conf.d`**, not passed with `-o`, because the NodeSource setup script runs its own apt commands internally.
- **The Node version is re-verified after install** rather than trusting apt. Ubuntu's own `nodejs` is 18, which silently breaks OpenClaw.
- **`loginctl enable-linger`** is what stops the gateway from dying with your SSH session.
- **The provisioning script has an EXIT trap** that writes the `.fail` status file, because `fail()` alone can't cover a command that dies unguarded under `set -e`.
- **The cleanup trap is never disarmed** — it flushes the logging `tee` on success too, and gates destruction on both exit code and `KEEP_VM`.

Scaffolding is derived from [proxmox-bun-vm](https://github.com/wesley83/proxmox-bun-vm).

---

## 👤 Author

Created by: **Wesley Faulkner**
GitHub: https://github.com/wesley83

## 📄 License

MIT License — feel free to fork, modify, and contribute.
