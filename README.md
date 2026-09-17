# 🦞 openclaw-vm

**One command to create an Ubuntu VM on Proxmox VE with [OpenClaw](https://github.com/openclaw/openclaw) installed and ready to set up.**

Created by **Wesley Faulkner** · Current release: [v1.6.0](https://github.com/wesley83/proxmox-openclaw-vm/releases/tag/v1.6.0) · [Changelog](CHANGELOG.md)

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/wesley83/proxmox-openclaw-vm/main/openclaw-vm.sh)"
```

> **Two things to know before your first run:**
> 1. Enable **Snippets** on a Proxmox storage first — [how](#enable-snippets-once).
> 2. The Control UI will **never** load at `http://<vm-ip>:18789`, even with the right token — [use one of these instead](#4-open-the-control-ui).

**Contents:** [What you get](#what-you-get) · [Requirements](#requirements) · [Install](#install) · [Options](#options) · [After the script finishes](#after-the-script-finishes) · [Everyday commands](#everyday-commands) · [Troubleshooting](#troubleshooting) · [Security](#security) · [Reference](#reference)

---

## What you get

- An **Ubuntu VM** built from the official cloud image (latest LTS): 8 GB RAM, 4 cores, 40 GB disk and 2 GB swap by default
- **Node.js 24** (LTS) from NodeSource — or a working Node already on the image
- **OpenClaw**, latest or a version you pin
- A user account (`openclaw`) that accepts your Proxmox node's SSH key, with systemd lingering so the gateway keeps running after you log out and after reboots
- A random **gateway token**, generated inside the VM
- Build tools (`build-essential`, `python3`, `cmake`) for OpenClaw's native modules
- Progress reporting through the QEMU Guest Agent, and a full log on the host

**Setup of your AI provider and chat apps is left to you, on purpose.** No API key or account login ever passes through the Proxmox host or its logs.

Tested end to end on Proxmox VE 7. The `--runtime bun` option has not yet been tested on real hardware.

---

## Requirements

| You need | Details |
|---|---|
| Proxmox VE 7, 8 or 9 | Run the script on the node itself, as `root` |
| Snippets enabled on a storage | One-time setting — [see below](#enable-snippets-once) |
| An SSH key on the node | `/root/.ssh/id_ed25519.pub` or `id_rsa.pub`, or pass `--ssh-key` |
| ~10 GB free on the VM storage | Setup uses about 5 GB. The script warns you before it starts if space is tight |
| ~2 GB free in `/tmp` on the node | The Ubuntu image downloads here first. Set `TMPDIR=/other/path` to use somewhere else |
| Free RAM for the VM | 8 GB by default |
| Internet access | **Node:** `cloud-images.ubuntu.com`, `api.launchpad.net`. **VM:** Ubuntu's apt mirrors, `deb.nodesource.com`, the npm registry — plus `bun.sh` and `github.com` with `--runtime bun` |

If a firewall blocks the VM from Ubuntu's apt mirrors, setup fails *and* the script can't report progress, because the guest agent is installed from apt.

### Enable Snippets (once)

In the Proxmox web UI: **Datacenter → Storage → select `local` → Edit → Content → add `Snippets` → OK.**

This is the most common reason a first run fails right away.

---

## Install

Run on the Proxmox node as `root`:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/wesley83/proxmox-openclaw-vm/main/openclaw-vm.sh)"
```

To pass options, add them after `--`:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/wesley83/proxmox-openclaw-vm/main/openclaw-vm.sh)" -- --memory 16384 --cores 8
```

Or clone the repo and run it locally:

```bash
git clone https://github.com/wesley83/proxmox-openclaw-vm.git
cd proxmox-openclaw-vm
bash openclaw-vm.sh
```

The script:

1. Picks the storage, network bridge, SSH key and next free VM ID
2. Downloads and verifies the Ubuntu cloud image
3. Creates the VM and sets up its disk
4. Installs Node.js and OpenClaw inside the VM
5. Waits for that to finish (up to about 17 minutes), then prints your next steps

---

## Options

| Option | What it does | Default |
|---|---|---|
| `-m`, `--memory <MB>` | RAM. Minimum `2048`; warns below `4096` | `8192` |
| `-c`, `--cores <N>` | CPU cores. Warns if the node has fewer | `4` |
| `-d`, `--disk <SIZE>` | Disk size with a unit, like `40G`. Minimum `8G`; warns below `20G` | `40G` |
| `-s`, `--swap <SIZE>` | Swap file size, or `0` for none | `2G` |
| `-u`, `--ubuntu <codename>` | Ubuntu release, like `noble` or `resolute` | Latest LTS |
| `-n`, `--node <major>` | Node.js version: `24` or `26`. (`22` and `25` are accepted but only work with an older `--openclaw-version`) | `24` |
| `--openclaw-version <v>` | OpenClaw version or npm tag. Pin one for repeatable builds | `latest` |
| `--runtime <auto\|node\|bun>` | What runs the gateway — see [Node and Bun](#node-and-bun) | `auto` |
| `--user <name>` | VM username | `openclaw` |
| `--storage <id>` | Storage for the VM disk — see [How storage is chosen](#how-storage-is-chosen) | Automatic |
| `--snippet-storage <id>` | Storage for the cloud-init snippet | First with Snippets enabled |
| `--ssh-key <path>` | Public key file (`.pub`). It can hold several keys, one per line | The node's root key |
| `--debug` | Print every command as it runs | Off |
| `-h`, `--help` | Show help | — |

Examples:

```bash
# A bigger VM on a specific storage
bash openclaw-vm.sh --memory 16384 --cores 8 --disk 80G --storage local-zfs

# Pin OpenClaw for a repeatable build
bash openclaw-vm.sh --openclaw-version 2026.9.4
```

### How storage is chosen

The script prefers `local-lvm`, otherwise the first storage that can hold VM disks. If that storage has less than about 10 GB free and another has room:

- **At a terminal**, it lists the storages with room and asks which to use. Press Enter to keep the original choice.
- **Without a terminal** (cron, CI), it switches to the storage with the most room and tells you.
- **If you passed `--storage`**, it always uses exactly that storage.

### Node and Bun

OpenClaw needs Node.js in every case, so the script always installs it — or reuses a working copy already on the image. `--runtime` only decides what runs the **gateway service**:

| `--runtime` | Gateway runs on |
|---|---|
| `auto` (default) | Node — or Bun, if a working Bun is already on the image |
| `node` | Node |
| `bun` | Bun, installed to `/opt/bun` if needed |

"Working" means the runtime passes a quick check of its built-in SQLite support — the same check OpenClaw's own installer uses. A fresh Ubuntu image has neither Node nor Bun, so there `auto` simply installs Node.

Node is the default because it's OpenClaw's recommended runtime; OpenClaw's docs note that Bun can hold database files open longer. When the gateway will run on Bun, the onboarding command the script prints includes `--daemon-runtime bun`.

---

## After the script finishes

The script's summary shows your VM's IP address, a one-time console password, and the steps below with your details filled in.

### 1. Log in

Use either:

- **The Proxmox console** — always works. In the Proxmox web UI, select the VM → **Console**, and log in as `openclaw` with the console password from the summary.
- **SSH from the Proxmox node** — `ssh openclaw@<vm-ip>`

On first login you must choose a new password. When it asks for your "current" password, enter the console password.

Only the Proxmox node's SSH key is installed, and password login over SSH is turned off. So SSH from your own computer fails with `Permission denied (publickey)` until you add that computer's key. From a shell in the VM:

```bash
mkdir -p ~/.ssh && chmod 700 ~/.ssh
echo '<your public key>' >> ~/.ssh/authorized_keys
```

You'll need this for step 4. (Or re-run the script with `--ssh-key` pointing at a file containing both keys.)

### 2. Set up OpenClaw

```bash
openclaw onboard --install-daemon --gateway-token "$(cat ~/.openclaw/gateway-token)"
```

If the summary shows `gateway=bun`, copy the command from the summary instead — it adds `--daemon-runtime bun`.

The wizard walks you through:

1. **A security notice** — press Enter to accept.
2. **Your AI provider** — paste an API key, *or* sign in with a subscription you already have. ChatGPT, GitHub Copilot and others are supported, so you don't need a pay-as-you-go API key.
3. **A messaging app** to talk to your assistant — Telegram, WhatsApp, Slack, Discord and more.
4. **A web search provider.**
5. **A first chat** in the terminal, where your assistant introduces itself. Reply, or press **Ctrl+C** to leave. To skip it entirely, add `--skip-ui` to the command.

The exact prompts change between OpenClaw versions — answer whatever it asks.

To add or change your AI sign-in later:

```bash
openclaw models auth login --provider openai
openclaw models auth list
```

### 3. Start the gateway

```bash
export XDG_RUNTIME_DIR=/run/user/$(id -u)
systemctl --user enable --now openclaw-gateway.service
openclaw gateway status --require-rpc
```

- The first line lets `systemctl --user` find your session. Without it you'll see `Failed to connect to bus`.
- The second starts the gateway now and on every boot. It keeps running after you log out.
- The third confirms the gateway is running and accepts your token.

Then check the gateway is using your token. These two should print the same value:

```bash
openclaw gateway auth-token --show
cat ~/.openclaw/gateway-token
```

If they differ:

```bash
openclaw config set gateway.auth.token "$(cat ~/.openclaw/gateway-token)"
openclaw gateway restart
```

### 4. Open the Control UI

**`http://<vm-ip>:18789` will not work, even with the correct token.** The Control UI needs a secure browser connection — HTTPS or `localhost` — so a plain-HTTP IP address is always refused. It looks like this:

![OpenClaw Control UI showing "Could not connect" when opened over plain HTTP at a LAN IP address, even with a correct token](img/control-ui-wrong-way.png)

Pick one of these instead:

| Option | Good for | You need |
|---|---|---|
| [A. SSH tunnel](#a-ssh-tunnel) | Getting started | Nothing extra |
| [B. Tailscale Serve](#b-tailscale-serve) | Private access from all your devices | A Tailscale account |
| [C. Cloudflare Tunnel](#c-cloudflare-tunnel) | Access from anywhere on your own domain | A Cloudflare account and domain |
| [D. nginx with HTTPS](#d-nginx-with-https) | A permanent address on your home network | Nothing extra |

#### A. SSH tunnel

On the computer whose browser you'll use — **not** in the VM:

```bash
ssh -N -L 18789:127.0.0.1:18789 openclaw@<vm-ip>
```

Leave it running (it prints nothing), then open **http://localhost:18789/** and enter your gateway token. This needs your computer's SSH key on the VM ([step 1](#1-log-in)).

Tip: in the VM, `openclaw dashboard --no-open` prints the full link with your token already in it.

#### B. Tailscale Serve

OpenClaw's own recommended option. [Install Tailscale](https://tailscale.com/download/linux) in the VM and run `sudo tailscale up`. Then:

```bash
openclaw config set gateway.tailscale.mode serve
openclaw gateway restart
```

Open `https://<vm-name>.<your-tailnet>.ts.net/` from any device on your tailnet. Nothing is exposed outside it.

#### C. Cloudflare Tunnel

1. In the [Cloudflare Zero Trust dashboard](https://one.dash.cloudflare.com), go to **Networks → Tunnels → Create a tunnel**, and run the install command it gives you inside the VM.
2. Add a **public hostname**, such as `openclaw.example.com`, pointing to `http://localhost:18789`.
3. Open `https://openclaw.example.com/`.

**Also protect the hostname with [Cloudflare Access](https://developers.cloudflare.com/cloudflare-one/policies/access/)** (an email code or single sign-on). Otherwise anyone on the internet can reach your gateway, with only the token stopping them.

#### D. nginx with HTTPS

Gives you a permanent `https://<vm-ip>/` on your network, with nothing to run on each device. Browsers warn once about the self-signed certificate.

In the VM, install nginx and create a certificate:

```bash
sudo apt-get install -y nginx
sudo mkdir -p /etc/nginx/ssl
sudo openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
  -keyout /etc/nginx/ssl/openclaw.key \
  -out /etc/nginx/ssl/openclaw.crt \
  -subj "/CN=openclaw"
sudo chmod 600 /etc/nginx/ssl/openclaw.key
```

Create `/etc/nginx/sites-available/openclaw`:

```nginx
server {
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;
    server_name _;

    ssl_certificate     /etc/nginx/ssl/openclaw.crt;
    ssl_certificate_key /etc/nginx/ssl/openclaw.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

    location / {
        proxy_pass http://127.0.0.1:18789;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_read_timeout 86400s;
    }
}
```

Turn it on:

```bash
sudo rm -f /etc/nginx/sites-enabled/default
sudo ln -sf /etc/nginx/sites-available/openclaw /etc/nginx/sites-enabled/openclaw
sudo nginx -t && sudo systemctl reload nginx
```

Open `https://<vm-ip>/`, accept the certificate warning, and enter your token. If a real domain points at the VM, `sudo apt-get install -y certbot python3-certbot-nginx && sudo certbot --nginx` replaces the self-signed certificate.

This opens port 443 to your whole network, so use a firewall to limit it to the devices that need it.

---

## Everyday commands

In the VM:

```bash
openclaw gateway status --require-rpc     # Is the gateway running and accepting the token?
openclaw doctor --lint                    # Health check, with suggested fixes
journalctl --user -u openclaw-gateway -f  # Live gateway logs
openclaw gateway restart                  # Restart the gateway
openclaw gateway auth-token --show        # Show the token in use
openclaw dashboard --no-open              # Print the Control UI link, token included
```

OpenClaw keeps its settings (`openclaw.json`) and data in `~/.openclaw/`, owned by your user — so installing OpenClaw plugins doesn't need `sudo`.

On the Proxmox node:

```bash
qm guest exec <VMID> -- cat /var/log/openclaw-install.ok        # Installed Node and OpenClaw versions
qm guest exec <VMID> -- tail -n 40 /var/log/openclaw-provision.log
qm terminal <VMID>                                              # Serial console (Ctrl+O to exit)
cat /var/log/openclaw-vm-<VMID>.log                             # The script's own log
```

To remove a VM completely:

```bash
qm stop <VMID> && qm destroy <VMID> --purge
rm -f <snippet-storage-path>/snippets/openclaw-<VMID>.yaml
```

---

## Troubleshooting

**Start with `openclaw doctor --lint`** in the VM. It lists problems along with the command that fixes each one. Before you've run `openclaw onboard`, it always reports missing authentication and an unset gateway mode — that's expected. For a bug report to OpenClaw, `openclaw gateway diagnostics export` creates a shareable bundle without your conversations.

### "No storage with 'snippets' content found"

Enable Snippets on a storage — [see Requirements](#enable-snippets-once).

### "Cannot create new thin volume" or "thin pool … reached threshold"

Your LVM-thin storage is full. Check how full:

```bash
pvesm status --content images
lvs -o lv_name,lv_size,data_percent,metadata_percent
```

Then free up space (remove unused VMs, disks or snapshots), pick another storage with `--storage <id>`, or grow the pool with `lvextend -L +50G pve/data`. A pool can also run out of *metadata* space, which fails the same way.

### "Storage 'X' does not support VM disk images"

Choose a storage that can hold VM disks:

```bash
bash openclaw-vm.sh --storage local-zfs
```

### The Control UI says "Could not connect"

If you're opening `http://<vm-ip>:18789`, that's the cause — use an option from [step 4](#4-open-the-control-ui). You can confirm by clicking **Raw error**: it says `control ui requires device identity (use HTTPS or localhost secure context)`.

If you're already using a step 4 option, watch the gateway log while you click **Connect**:

```bash
tail -f /tmp/openclaw-$(id -u)/openclaw-$(date +%F).log
```

Look at `reason=` on the `closed before connect` line. An authentication reason usually means the browser remembered an old token — clear the token field and paste the current one from `openclaw gateway auth-token --show`.

### "Permission denied (publickey)"

Only the Proxmox node's SSH key is installed, and password SSH is off. Log in through the Proxmox console or from the node, then add your computer's key — [see step 1](#1-log-in).

### "Password change required but no TTY available" — or `sudo` says "Authentication token manipulation error"

You haven't changed the initial password yet. Log in once through the console or an interactive `ssh` session and set a new password; both errors go away.

### The script says UNCONFIRMED, but the VM seems fine

Setup may still be running, or finished after the script stopped waiting. Check:

```bash
qm guest exec <VMID> -- cat /var/log/openclaw-install.ok
```

### The script says FAILED, or `openclaw: command not found`

```bash
qm guest exec <VMID> -- cat /var/log/openclaw-install.fail
qm guest exec <VMID> -- tail -n 50 /var/log/openclaw-provision.log
```

If the message says a runtime failed OpenClaw's capability check, re-run with a different `--node` version, or with `--runtime node`.

### The gateway doesn't start after a reboot

This should print `Linger=yes`:

```bash
loginctl show-user openclaw --property=Linger
```

If it doesn't, run `sudo loginctl enable-linger openclaw`.

### "Could not detect VM IP"

The VM is usually fine. Find its address in the console with `ip a`, or in your router's list of devices under the name `openclaw-<VMID>`.

### The script failed and removed the VM

If setup fails before OpenClaw installation starts, the script deletes the half-built VM. The reason is in `/var/log/openclaw-vm-<VMID>.log`.

### Exit codes

| Code | Meaning |
|---|---|
| `0` | Success |
| `1` | Failed before installation began; any partly created VM was removed |
| `2` | The VM was kept, but installation failed or couldn't be confirmed |
| `130` / `143` | Interrupted by Ctrl+C or a stop signal |

---

## Security

- **The gateway only listens on the VM itself and requires your token.** All four [step 4](#4-open-the-control-ui) options keep it that way. Don't open port 18789 to your network to reach the Control UI — browsers can't use it, and OpenClaw warns never to expose the gateway without authentication.
- `openclaw config set gateway.bind lan` is only for non-browser clients, like OpenClaw's native apps. If you use it, firewall port 18789 to the devices that need it.
- **With Cloudflare Tunnel, add Cloudflare Access** so your gateway isn't open to the whole internet.
- **If your token may have leaked** — pasted into a chat, shown on screen, or saved somewhere public — replace it:

  ```bash
  openssl rand -hex 32 > ~/.openclaw/gateway-token
  openclaw config set gateway.auth.token "$(cat ~/.openclaw/gateway-token)"
  openclaw gateway restart
  ```

  Then clear the old token from the Control UI in your browser.
- **The console password is saved in the host log and the cloud-init snippet**, both readable only by root. Change it at first login, and delete snippet files for VMs you've destroyed.

---

## Reference

### Default VM settings

| Setting | Value |
|---|---|
| Operating system | Ubuntu cloud image, latest LTS |
| User | `openclaw`, with passwordless `sudo` |
| Login | The node's SSH key, plus a one-time console password |
| Hostname | `openclaw-<VMID>` |
| Network | DHCP on `vmbr0` (or the first bridge found) |
| CPU / machine | `host` / `q35` |
| Starts with the node | Yes |
| Guest agent | Installed and running |
| Node.js | 24 (LTS) from NodeSource, or a working Node already on the image |
| Gateway runtime | Node, unless `--runtime` selects Bun |
| OpenClaw | Installed globally with npm |
| Gateway port | `18789`, on localhost only |

### Disk and memory

A freshly set-up VM uses about **5 GB** of disk. The 40 GB default leaves room for logs, conversation history, and a browser if you add one later. OpenClaw's browser automation isn't set up — nothing installs a browser.

A 2 GB swap file is added because Ubuntu cloud images have none, which would otherwise turn a brief memory spike during installation into a crash.

### Known limitations

- **amd64 only.** For ARM, change `-server-cloudimg-amd64.img` to `-arm64.img` in the script.
- **No live migration** between hosts with different CPUs, because the VM uses `--cpu host`. Change it with `qm set <VMID> --cpu kvm64`.
- **Latest-LTS detection can pick a release too early** — before its cloud image exists — which fails with a download error. Pin a release with `--ubuntu <codename>`.
- **Runtime detection only checks the usual places:** `PATH`, plus `~/.bun/bin` for Bun. A Node installed with nvm, fnm or Volta isn't found.
- **Nothing is removed after a successful run**, and `qm destroy` doesn't delete the VM's snippet file. Clean up with the commands in [Everyday commands](#everyday-commands).

### Design notes

For anyone changing the script — these look odd but matter:

- **Progress is checked through the QEMU Guest Agent, not SSH.** Until the first password change, SSH refuses to run commands without a terminal, so SSH-based checking would always fail.
- **Values reach the in-VM setup script as arguments, not variables.** That script is written inside a quoted heredoc so nothing in it is expanded early; a variable written there would arrive empty. The script checks every argument is present.
- **`--openclaw-version` and `--runtime` are strictly validated**, because both end up inside cloud-init's `runcmd`.
- **The imported disk's ID is read back from `qm config`**, not guessed — its name varies by storage type and can collide with leftover disks.
- **Runtimes are checked by what they can do, not by version number.** OpenClaw's Node requirements change between releases, so the script tests the runtime's SQLite support directly, before the large OpenClaw download.
- **Bun only runs the gateway; OpenClaw still needs Node.** Bun installs to `/opt/bun` and is linked into `/usr/local/bin`, one of the places OpenClaw looks for it.
- **`cmake` and other build tools are preinstalled** so native modules can still build if no prebuilt binary matches.
- **Lingering** keeps the gateway running with nobody logged in.
- **Traps on exit** make every failure leave a status file and a meaningful exit code.

Scaffolding is derived from [proxmox-bun-vm](https://github.com/wesley83/proxmox-bun-vm).

---

## Author

**Wesley Faulkner** · [github.com/wesley83](https://github.com/wesley83)

## License

MIT — feel free to fork, modify and contribute.
