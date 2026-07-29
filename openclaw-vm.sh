#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# OpenClaw VM Auto-Provisioning Script for Proxmox VE
#
# Creates an Ubuntu cloud-image VM, installs Node.js (NodeSource) and OpenClaw
# (https://github.com/openclaw/openclaw), and prepares the host so the gateway
# daemon can run as an always-on systemd user service.
#
# Onboarding is deliberately NOT run: no LLM API key is ever handled by this
# script, so no secret can land in the Proxmox host log. The final summary
# prints the exact commands to finish setup over SSH.
#
# Scaffolding (storage/snippet detection, cleanup trap, tee logging, two-tier
# IP detection) is derived from proxmox-bun-vm by Wesley Faulkner:
#   https://github.com/wesley83/proxmox-bun-vm
# Every defensive construct carried over from that script is load-bearing —
# see its git history before "simplifying" any of it.
#
# Version: v1.1.0
# -----------------------------------------------------------------------------
set -euo pipefail

############################################
# Color + UI helpers
############################################
if [ -t 1 ]; then
  RED="$(printf '\033[31m')"
  GREEN="$(printf '\033[32m')"
  YELLOW="$(printf '\033[33m')"
  BLUE="$(printf '\033[34m')"
  CYAN="$(printf '\033[36m')"
  BOLD="$(printf '\033[1m')"
  RESET="$(printf '\033[0m')"
else
  RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""; BOLD=""; RESET=""
fi

INFO()  { echo "${BLUE}[INFO]${RESET}  $*"; }
WARN()  { echo "${YELLOW}[WARN]${RESET}  $*"; }
ERROR() { echo "${RED}[ERROR]${RESET} $*" >&2; }
OK()    { echo "${GREEN}[OK]${RESET}    $*"; }
# The || return 0 keeps this errexit-safe: with the && form, any call while
# DEBUG=0 returns 1 and set -e kills the whole script.
DEBUG() { [[ "$DEBUG" -eq 1 ]] || return 0; echo "${CYAN}[DEBUG]${RESET} $*"; }

############################################
# Banner
############################################
SCRIPT_VERSION="v1.1.0"
REPO_URL="https://github.com/openclaw/openclaw"

printf "${GREEN}${BOLD}"
  cat <<'EOF'
   ___                    ____ _
  / _ \ _ __   ___ _ __  / ___| | __ ___      __
 | | | | '_ \ / _ \ '_ \| |   | |/ _` \ \ /\ / /
 | |_| | |_) |  __/ | | | |___| | (_| |\ V  V /
  \___/| .__/ \___|_| |_|\____|_|\__,_| \_/\_/
       |_|                                    (^)
EOF
printf "${RESET}\n"

printf "${CYAN}           OpenClaw VM Installer for Proxmox VE${RESET}\n"
printf "${GREEN}                        ${SCRIPT_VERSION}${RESET}\n"
printf "${CYAN}     ${REPO_URL}${RESET}\n\n"

############################################
# Defaults
############################################
# Our own sizing choices, not a published vendor spec. Headroom is for the
# npm global install plus native-module builds, and for later browser
# automation if you add it. NOTE: nothing here downloads a browser —
# openclaw depends on playwright-core, which does NOT fetch Chromium at
# install time, and upstream's install.sh has no browser handling at all.
# Enabling browser automation is a separate step that needs its own
# browser + system libraries. Trim with --memory/--cores/--disk.
MEMORY_MB=8192
CORES=4
DISK_SIZE="40G"
UBUNTU_CODENAME="noble"   # Fallback if LTS auto-detection fails
VM_USER="openclaw"
NODE_MAJOR=26             # OpenClaw docs recommend Node 26
SSH_KEY_PATH="auto"       # auto-detect /root/.ssh/id_ed25519.pub or id_rsa.pub
STORAGE_ID="auto"         # VM disk storage; set via --storage
SNIPPET_STORAGE_ID="auto"
DEBUG=0
_UBUNTU_USER_SET=0        # Set to 1 if --ubuntu is passed on the command line

# NodeSource publishes setup_<major>.x for these majors only (verified
# 2026-07-28: 22/24/25/26 return 200, 27 returns 404). Picking anything else
# 404s at download time, which is a loud failure by design.
SUPPORTED_NODE_MAJORS="22 24 25 26"

############################################
# Resolve latest Ubuntu LTS codename
############################################
# Fetches the current latest active LTS codename from Launchpad's API.
# Falls back to the hard-coded "noble" (24.04 LTS) if python3, curl, or the
# API is unavailable.
#
# Future-proofing note (inherited): when the next .04 enters Active Development
# it is flagged active=true and will be picked here before its cloud image
# exists, causing a loud 404 at the curl step. Pin with --ubuntu to bypass.
get_latest_lts() {
  command -v python3 >/dev/null 2>&1 || return 0
  curl -fsSL --max-time 10 \
    'https://api.launchpad.net/1.0/ubuntu/series?active=true' 2>/dev/null | \
  python3 -c '
import json, sys
data = json.load(sys.stdin)
lts = [s for s in data.get("entries", [])
       if s.get("active", False) and s.get("version", "").endswith(".04")]
if lts:
    def key(s):
        try:
            return tuple(int(p) for p in s["version"].split("."))
        except (ValueError, IndexError):
            return (0,)
    print(max(lts, key=key)["name"])
' 2>/dev/null
}

############################################
# Help menu
############################################
print_help() {
  cat <<EOF
Usage: openclaw-vm.sh [options]

Creates an Ubuntu VM on Proxmox VE with Node.js and OpenClaw installed.
Onboarding is left to you — the summary prints the exact commands.

Options:
  -m, --memory <MB>       RAM in MB (default ${MEMORY_MB}, must be >= 1)
  -c, --cores <N>         CPU cores (default ${CORES}, must be >= 1)
  -d, --disk <SIZE>       Disk size with suffix (e.g. 40G, 64G; default ${DISK_SIZE}).
                          Must exceed the cloud image's virtual size (~3.5G):
                          qm resize cannot shrink a disk
  -u, --ubuntu <codename> Ubuntu cloud image codename (default: latest active LTS,
                          falls back to noble)
  -n, --node <major>      Node.js major version (default ${NODE_MAJOR};
                          supported: ${SUPPORTED_NODE_MAJORS})
  --user <name>           VM username (default: ${VM_USER}; lowercase, must
                          start with letter or _ and be <= 32 chars)
  --storage <id>          Proxmox storage for the VM disk (default: local-lvm
                          if present, else the first active storage with
                          'images' content)
  --ssh-key <path>        SSH public key file (default: auto-detect
                          /root/.ssh/id_ed25519.pub, then id_rsa.pub)
  --debug                 Enable bash debug tracing
  -h, --help              Show help

EOF
}

############################################
# Parse args
############################################
while [[ $# -gt 0 ]]; do
  case "$1" in
    -m|--memory)
      [[ "${2:-}" =~ ^[0-9]+$ ]] || { ERROR "--memory must be a positive integer (MB)"; exit 1; }
      (( $2 >= 1 )) || { ERROR "--memory must be >= 1 (got: $2)"; exit 1; }
      MEMORY_MB="$2"; shift 2;;
    -c|--cores)
      [[ "${2:-}" =~ ^[0-9]+$ ]] || { ERROR "--cores must be a positive integer"; exit 1; }
      (( $2 >= 1 )) || { ERROR "--cores must be >= 1 (got: $2)"; exit 1; }
      CORES="$2"; shift 2;;
    -d|--disk)
      [[ "${2:-}" =~ ^[0-9]+[MGK]$ ]] || { ERROR "--disk must have a suffix (e.g. 40G) — bare numbers default to MB in qm resize"; exit 1; }
      size_num="${2%[MGK]}"
      (( size_num >= 1 )) || { ERROR "--disk must be >= 1 (got: $2)"; exit 1; }
      DISK_SIZE="$2"; shift 2;;
    -u|--ubuntu)
      [[ -n "${2:-}" && "${2:-}" != -* ]] || { ERROR "--ubuntu requires a codename argument"; exit 1; }
      UBUNTU_CODENAME="$2"; _UBUNTU_USER_SET=1; shift 2;;
    -n|--node)
      [[ "${2:-}" =~ ^[0-9]+$ ]] || { ERROR "--node must be a major version number (e.g. 26)"; exit 1; }
      # shellcheck disable=SC2076
      [[ " ${SUPPORTED_NODE_MAJORS} " == *" $2 "* ]] || {
        ERROR "--node ${2}: NodeSource does not publish setup_${2}.x"
        ERROR "Supported majors: ${SUPPORTED_NODE_MAJORS}"
        ERROR "OpenClaw requires Node 22.22.3+, 24.15+, or 25.9+ (26 recommended)."
        exit 1
      }
      NODE_MAJOR="$2"; shift 2;;
    --user)
      [[ "${2:-}" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { ERROR "--user must be a valid Linux username (lowercase, starts with a-z or _, max 32 chars)"; exit 1; }
      VM_USER="$2"; shift 2;;
    --storage)
      [[ -n "${2:-}" && "${2:-}" != -* ]] || { ERROR "--storage requires a storage ID argument"; exit 1; }
      STORAGE_ID="$2"; shift 2;;
    --ssh-key)
      [[ -f "${2:-}" ]] || { ERROR "--ssh-key: file '${2:-}' not found or not a regular file"; exit 1; }
      [[ "$2" == *.pub ]] || {
        ERROR "--ssh-key: file '$2' does not end in .pub"
        ERROR "HINT: extract the public key from a private key with:"
        ERROR "  ssh-keygen -y -f <private-key> > <name>.pub"
        exit 1
      }
      SSH_KEY_PATH="$2"; shift 2;;
    --debug)     DEBUG=1; shift;;
    -h|--help)   print_help; exit 0;;
    *) ERROR "Unknown option: $1"; exit 1;;
  esac
done

# Auto-detect the latest Ubuntu LTS if the user didn't pin one with --ubuntu
if [[ "$_UBUNTU_USER_SET" -eq 0 ]]; then
  LATEST_LTS="$(get_latest_lts 2>/dev/null || true)"
  if [[ -n "$LATEST_LTS" && "$LATEST_LTS" != "$UBUNTU_CODENAME" ]]; then
    INFO "Auto-detected latest Ubuntu LTS: ${LATEST_LTS} (default was: ${UBUNTU_CODENAME})"
    UBUNTU_CODENAME="$LATEST_LTS"
  fi
fi

[[ "$DEBUG" -eq 1 ]] && set -x

############################################
# Environment validation
############################################
if [[ "$(id -u)" -ne 0 ]]; then
  ERROR "This script must be run as root on a Proxmox VE node."
  exit 1
fi

for cmd in qm pvesh pvesm awk curl ip qemu-img; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    ERROR "Required command '$cmd' not found. Are you running this on a Proxmox node?"
    exit 1
  fi
done

############################################
# VM ID and log setup
############################################
if ! VM_ID="$(pvesh get /cluster/nextid 2>/dev/null)"; then
  ERROR "Failed to get next VM ID — cluster/quorum may be degraded."
  exit 1
fi

VM_NAME="openclaw-${VM_ID}"
LOG_FILE="/var/log/openclaw-vm-${VM_ID}.log"

# Begin logging
exec > >(tee -a "$LOG_FILE") 2>&1
TEE_PID=$!

INFO "Log file: $LOG_FILE"
INFO "Script version: $SCRIPT_VERSION"
INFO "Using VMID: $VM_ID"
INFO "VM Name: $VM_NAME"
INFO "Ubuntu codename: $UBUNTU_CODENAME"
INFO "Node.js major: $NODE_MAJOR"
INFO "VM user: $VM_USER"
INFO "Resources: ${MEMORY_MB} MB RAM, ${CORES} cores, disk ${DISK_SIZE}"

############################################
# Cleanup handler
############################################
VM_CREATED=0
KEEP_VM=0   # Set to 1 once the VM is worth keeping: lets the script exit
            # non-zero (so scripted callers see the failure) WITHOUT the trap
            # destroying the VM the operator was promised for inspection.
IMG_FILE=""

cleanup() {
  local exit_code=$?
  if [[ $exit_code -ne 0 ]]; then
    if [[ $VM_CREATED -eq 1 && $KEEP_VM -eq 0 ]]; then
      ERROR "Script failed with exit code $exit_code."
      WARN "Cleaning up VM ${VM_ID}..."
      qm stop "${VM_ID}" >/dev/null 2>&1 || true
      qm destroy "${VM_ID}" --purge >/dev/null 2>&1 || true
      OK "Destroyed VM ${VM_ID}."
      ERROR "See log file for details: ${LOG_FILE}"
    elif [[ $VM_CREATED -eq 1 ]]; then
      WARN "Exit code ${exit_code}: VM ${VM_ID} was KEPT for inspection (not destroyed)."
      WARN "Log file: ${LOG_FILE}"
    else
      ERROR "Script failed with exit code $exit_code."
      ERROR "See log file for details: ${LOG_FILE}"
    fi

    if [[ -n "$IMG_FILE" && -f "$IMG_FILE" ]]; then
      WARN "Removing downloaded image ${IMG_FILE}..."
      rm -f "${IMG_FILE}" || true
    fi
  fi

  # Close stdout to signal EOF to tee (otherwise wait deadlocks — tee blocks
  # on read() of the still-open pipe), then wait for tee to finish flushing.
  exec >/dev/null 2>&1
  wait "${TEE_PID:-}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

############################################
# Detect VM disk storage
############################################
INFO "Detecting VM disk storage..."

# pvesm status columns: Name(1) Type(2) Status(3) Total(4) Used(5) Available(6) %(7).
# Stable across PVE 6/7/8/9. Note: grep -q here would SIGPIPE the producer and
# fail the pipeline under pipefail — that bug silently broke local-lvm
# selection once already. Keep the redirect form.
if [[ "$STORAGE_ID" != "auto" && -n "$STORAGE_ID" ]]; then
  STORAGE="$STORAGE_ID"
  INFO "Using user-selected storage: ${STORAGE}"
elif pvesm status | awk 'NR>1{print $1,$3}' | grep '^local-lvm active' >/dev/null; then
  STORAGE="local-lvm"
else
  # --content images matters: on ZFS-root/Ceph nodes the alphabetically-first
  # active storage is 'local' (dir; iso/vztmpl/backup only), which cannot hold
  # VM disks — an unfiltered fallback picks it and dies at the gate below even
  # though an images-capable storage (e.g. local-zfs) sits right next to it.
  STORAGE="$(pvesm status --content images | awk 'NR>1 && $3=="active"{print $1;exit}' || true)"
fi

if [[ -z "${STORAGE}" ]]; then
  ERROR "Could not determine active storage for VM disks."
  exit 1
fi

STORAGE_CONTENT="$(
  awk -v target="${STORAGE}" '
    /^[a-z0-9_-]+:/{split($0,a,"[ :]+"); id=a[2]; inblock=(id==target)}
    inblock && $1=="content"{print; exit}
  ' /etc/pve/storage.cfg
)"
# qm importdisk needs the 'images' content type specifically. 'rootdir' is
# container-only (LXC) — a rootdir-only storage would pass a looser gate here
# and then fail at import time, after the VM already exists.
if [[ "$STORAGE_CONTENT" != *images* ]]; then
  ERROR "Storage '${STORAGE}' does not support VM disk images (content: ${STORAGE_CONTENT:-none})."
  ERROR "Enable 'Disk image' content on this storage, or pick another with --storage <id>."
  exit 1
fi

OK "Using disk storage: ${STORAGE}"

############################################
# Snippet auto-detect
############################################
CFG="/etc/pve/storage.cfg"

if [[ ! -f "${CFG}" ]]; then
  ERROR "Missing storage.cfg — this node may not be healthy."
  exit 1
fi

# All three storage.cfg awks below flush block state on the NEXT header line
# as well as on blank lines and END: PVE's SectionConfig parser accepts files
# with no blank line between blocks (hand-edited/concatenated), and an awk
# that only flushes on NF==0 silently drops such a block's snippets flag.
INFO "Scanning for snippet-capable storages..."
awk '
  function flush() { if(inblock && has) print "  " hdr "\n    (content includes snippets)" }
  /^[a-z0-9_-]+:/ {flush(); hdr=$0; inblock=1; has=0}
  inblock && $1=="content" && /snippets/ {has=1}
  NF==0 {flush(); inblock=0}
  END {flush()}
' "$CFG"

if [[ "$SNIPPET_STORAGE_ID" == "auto" || -z "$SNIPPET_STORAGE_ID" ]]; then
  INFO "Auto-selecting first snippet-enabled storage..."

  SNIPPET_STORAGE_ID="$(
    awk '
      function flush() { if(inblock && has && !printed){ print id; printed=1 } }
      BEGIN{printed=0; inblock=0}
      /^[a-z0-9_-]+:/ {
        flush(); if(printed) exit
        split($0,a,"[ :]+"); id=a[2]
        inblock=1; has=0
      }
      inblock && $1=="content" && /snippets/ {has=1}
      NF==0 {
        flush(); if(printed) exit
        inblock=0
      }
      END { flush() }
    ' "$CFG"
  )"

  SNIPPET_STORAGE_ID="$(printf '%s\n' "$SNIPPET_STORAGE_ID" | head -n1)"

  if [[ -z "$SNIPPET_STORAGE_ID" ]]; then
    ERROR "No storage with 'snippets' content found."
    ERROR "Enable it once via: Datacenter -> Storage -> local -> Edit -> check 'Snippets'"
    exit 1
  fi

  OK "Auto-selected snippet storage: ${SNIPPET_STORAGE_ID}"
fi

HAS_SNIP="$(
  awk -v target="${SNIPPET_STORAGE_ID}" '
    function flush() { if(inblock && has) found=1 }
    /^[a-z0-9_-]+:/{
      flush()
      split($0,a,"[ :]+"); id=a[2]
      inblock=(id==target); has=0
    }
    inblock && $1=="content" && /snippets/ {has=1}
    NF==0 { flush(); inblock=0 }
    END { flush(); if(found) print "yes" }
  ' "$CFG"
)"

if [[ "$HAS_SNIP" != "yes" ]]; then
  ERROR "Storage '${SNIPPET_STORAGE_ID}' does NOT have 'snippets' content."
  exit 1
fi

SNIPPET_BASE_PATH="$(
  awk -v target="${SNIPPET_STORAGE_ID}" '
    /^[a-z0-9_-]+:/{ split($0,a,"[ :]+"); id=a[2]; inblock=(id==target) }
    inblock && $1=="path"{print $2; exit}
  ' "$CFG"
)"

if [[ -z "$SNIPPET_BASE_PATH" ]]; then
  ERROR "Could not determine snippet storage path."
  exit 1
fi

SNIPPET_DIR="${SNIPPET_BASE_PATH}/snippets"
OK "Snippet directory: ${SNIPPET_DIR}"

############################################
# Detect network bridge
############################################
INFO "Detecting network bridge..."

BRIDGE="$(awk '/^auto vmbr/{print $2;exit}' /etc/network/interfaces 2>/dev/null || true)"

if [[ -z "$BRIDGE" ]]; then
  for f in /etc/network/interfaces.d/*; do
    [[ -f "$f" ]] || continue
    candidate="$(awk '/^auto vmbr/{print $2;exit}' "$f" 2>/dev/null || true)"
    if [[ -n "$candidate" ]]; then
      BRIDGE="$candidate"
      break
    fi
  done
fi

if [[ -z "$BRIDGE" && -n "$(ip -o link show vmbr0 2>/dev/null || true)" ]]; then
  BRIDGE="vmbr0"
fi

if [[ -z "$BRIDGE" ]]; then
  ERROR "Could not find network bridge (vmbr)."
  exit 1
fi

OK "Using bridge: ${BRIDGE}"

############################################
# Detect SSH key
############################################
INFO "Detecting SSH key..."

if [[ "$SSH_KEY_PATH" != "auto" && -n "$SSH_KEY_PATH" ]]; then
  SSH_KEY="$SSH_KEY_PATH"
elif [[ -f /root/.ssh/id_ed25519.pub ]]; then
  SSH_KEY="/root/.ssh/id_ed25519.pub"
elif [[ -f /root/.ssh/id_rsa.pub ]]; then
  SSH_KEY="/root/.ssh/id_rsa.pub"
else
  ERROR "No SSH key found. Pass --ssh-key <path>, or create /root/.ssh/id_ed25519.pub."
  exit 1
fi

OK "Using SSH key: $SSH_KEY"

# Keys are embedded as YAML double-quoted strings. Backslashes and double
# quotes are escaped (\ -> \\, " -> \"). $ and ` are safe inside YAML
# double-quoted scalars, and bash expansion here is single-pass.
SSH_KEYS_YAML=""
VALID_KEY_COUNT=0
while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line#"${line%%[![:space:]]*}"}"  # trim leading whitespace
  line="${line%"${line##*[![:space:]]}"}"  # trim trailing whitespace
  [[ -z "$line" || "$line" == \#* ]] && continue
  first_token="${line%% *}"
  if [[ "$first_token" =~ ^(ssh-|ecdsa-|sk-) ]]; then
    line_escaped="${line//\\/\\\\}"
    line_escaped="${line_escaped//\"/\\\"}"
    SSH_KEYS_YAML+="      - \"${line_escaped}\""$'\n'
    VALID_KEY_COUNT=$((VALID_KEY_COUNT + 1))
  else
    WARN "Skipping unrecognized line in ${SSH_KEY}: ${line:0:60}..."
  fi
done < "$SSH_KEY"

if [[ $VALID_KEY_COUNT -eq 0 ]]; then
  ERROR "No valid SSH keys found in ${SSH_KEY}."
  ERROR "Expected lines starting with: ssh-rsa, ssh-ed25519, ecdsa-sha2-..., or sk-*"
  exit 1
fi

OK "Loaded ${VALID_KEY_COUNT} SSH key(s) from ${SSH_KEY}"

# Random initial console password; must be changed on first login.
# || true suppresses SIGPIPE (141) from pipefail when head closes the pipe.
RANDOM_PASSWORD="$(LC_ALL=C tr -dc 'A-HJ-Za-km-z0-9' </dev/urandom | head -c 8 || true)"

############################################
# Download Ubuntu cloud image
############################################
IMG_URL="https://cloud-images.ubuntu.com/${UBUNTU_CODENAME}/current/${UBUNTU_CODENAME}-server-cloudimg-amd64.img"
IMG_FILE="$(mktemp /tmp/ubuntu-cloudimg-XXXXXX.img)"

INFO "Downloading cloud image:"
INFO "  $IMG_URL"
curl -fsSL "$IMG_URL" -o "$IMG_FILE" || { ERROR "Download failed: $IMG_URL"; rm -f "$IMG_FILE"; exit 1; }

INFO "Verifying image integrity..."
if ! qemu-img check "$IMG_FILE" >/dev/null 2>&1; then
  ERROR "Downloaded image failed integrity check (corrupt or truncated)."
  rm -f "$IMG_FILE"
  exit 1
fi

OK "Image downloaded and verified."

# qm resize with a bare (non-'+') size is ABSOLUTE and shrinking is not
# supported — a --disk at or below the image's virtual size (~3.5G for Ubuntu
# server cloudimg) would fail AFTER the VM exists and get it destroyed by the
# trap. Reject it now, while the only sunk cost is the download.
size_to_bytes() {
  local n="${1%[KMG]}"
  case "$1" in
    *K) echo $((n * 1024));;
    *M) echo $((n * 1024 * 1024));;
    *G) echo $((n * 1024 * 1024 * 1024));;
  esac
}
IMG_VIRT_BYTES="$(
  qemu-img info --output=json "$IMG_FILE" 2>/dev/null | \
    python3 -c 'import json, sys; print(json.load(sys.stdin)["virtual-size"])' 2>/dev/null || true
)"
if [[ -z "$IMG_VIRT_BYTES" ]]; then
  # No python3: parse the human-readable "virtual size: 3.5 GiB (3758096384 bytes)"
  IMG_VIRT_BYTES="$(
    qemu-img info "$IMG_FILE" 2>/dev/null | \
      awk -F'[()]' '/virtual size/{split($2,a," "); print a[1]; exit}' || true
  )"
fi
if [[ "$IMG_VIRT_BYTES" =~ ^[0-9]+$ ]]; then
  REQ_BYTES="$(size_to_bytes "$DISK_SIZE")"
  if (( REQ_BYTES <= IMG_VIRT_BYTES )); then
    ERROR "--disk ${DISK_SIZE} is not larger than the cloud image's virtual size ($((IMG_VIRT_BYTES / 1073741824)) GiB)."
    ERROR "qm resize cannot shrink disks — pass a larger --disk (e.g. 40G)."
    rm -f "$IMG_FILE"
    exit 1
  fi
else
  WARN "Could not determine image virtual size; skipping --disk sanity check."
fi

############################################
# Create VM
############################################
INFO "Creating VM ${VM_ID}..."

qm create "$VM_ID" \
  --name "$VM_NAME" \
  --memory "$MEMORY_MB" \
  --cores "$CORES" \
  --cpu host \
  --machine q35 \
  --agent enabled=1,fstrim_cloned_disks=1 \
  --net0 "virtio,bridge=${BRIDGE}" \
  --scsihw virtio-scsi-single \
  --serial0 socket \
  --ostype l26 \
  --onboot 1

VM_CREATED=1
OK "VM created."

############################################
# Import disk
############################################
INFO "Importing disk into ${STORAGE}..."

# qm importdisk, NOT qm disk import — the latter is PVE 8+ only.
qm importdisk "$VM_ID" "$IMG_FILE" "$STORAGE"

# Read the actual volid back instead of reconstructing it. On file-based
# storages (dir/NFS/CIFS) importdisk produces '<storage>:<vmid>/vm-<vmid>-disk-0.raw'
# — a guessed '<storage>:vm-<vmid>-disk-0' fails to parse there. And even on
# LVM-thin the index is the lowest FREE one, so a stale orphan volume from an
# earlier failed run would shift the import to disk-1 while the guess silently
# attached the orphan.
DISK_REF="$(qm config "$VM_ID" | awk '/^unused0:/{print $2; exit}')"
if [[ -z "$DISK_REF" ]]; then
  ERROR "Could not locate the imported disk (no unused0 entry in 'qm config ${VM_ID}')."
  exit 1
fi
INFO "Imported disk volid: ${DISK_REF}"
qm set "$VM_ID" --scsi0 "${DISK_REF},iothread=1" --boot order=scsi0

OK "Disk attached."

INFO "Resizing disk to ${DISK_SIZE}..."
qm resize "$VM_ID" scsi0 "$DISK_SIZE"

############################################
# Cloud-init configuration
############################################
INFO "Configuring cloud-init..."

qm set "$VM_ID" --ide2 "${STORAGE}:cloudinit"
qm set "$VM_ID" --ipconfig0 "ip=dhcp"
# --ciuser and --sshkey intentionally omitted: --cicustom user=... below
# provides a full user-data file that REPLACES Proxmox's generated one.

############################################
# Create user-data
############################################
mkdir -p "$SNIPPET_DIR"
USERDATA="${SNIPPET_DIR}/openclaw-${VM_ID}.yaml"

# The user-data is assembled in three parts so the provisioning script can be
# embedded verbatim inside a QUOTED heredoc. That keeps every $ and backtick
# literal and removes an entire class of escaping bugs — the interpolated
# parts stay short and obvious.

# --- Part 1: interpolated (user, keys, password, packages) -------------------
cat > "$USERDATA" <<EOF
#cloud-config
# hostname matters beyond cosmetics: --cicustom REPLACES Proxmox's generated
# user-data (which is where PVE would inject it), so without this the guest
# keeps the image default 'ubuntu' — and that is the name that shows up in
# the router's DHCP leases, colliding across VMs.
hostname: ${VM_NAME}
manage_etc_hosts: true

users:
  - name: ${VM_USER}
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
${SSH_KEYS_YAML}

# NOTE: expire:true has a far-reaching side effect — until the password is
# changed interactively, PAM refuses EVERY no-TTY SSH command for this user
# ("Password change required but no TTY available."), which is why the host
# polls install status via the QEMU Guest Agent, never SSH.
# 'users:' is the supported form; the old 'list:' form is deprecated since
# cloud-init 22.2 and on the 5-year removal schedule — a trap given this
# script auto-tracks the newest LTS image.
chpasswd:
  expire: true
  users:
    - name: ${VM_USER}
      password: ${RANDOM_PASSWORD}
      type: text

package_update: true

# Build toolchain mirrors what OpenClaw's own install.sh installs on
# Debian/Ubuntu (install_build_tools_linux):
#   build-essential python3 make g++ cmake
# make/g++/gcc come from build-essential; python3 is already in the cloud
# image (cloud-init needs it) but is listed explicitly so node-gyp's
# requirement is documented rather than assumed.
#
# cmake is the one that is NOT obvious. OpenClaw's main native deps
# (@lydell/node-pty, sqlite-vec) ship per-platform PREBUILT binaries, so the
# happy path compiles nothing — but when a prebuild is missing for the
# running Node ABI/arch, npm falls back to building from source and needs
# cmake. Upstream installs it unconditionally AND greps npm logs for
# "cmake: command not found" / "Failed to build llama.cpp" to install it and
# retry. This script calls npm directly, so it gets neither remedy: without
# cmake pre-installed, that fallback is an unrecoverable provisioning
# failure. ~30 MB to delete an entire failure class.
packages:
  - curl
  - ca-certificates
  - gnupg
  - git
  - unzip
  - openssl
  - build-essential
  - python3
  - cmake
  - qemu-guest-agent
EOF

# --- Part 2: literal (provisioning script) -----------------------------------
cat >> "$USERDATA" <<'YAMLEOF'

write_files:
  - path: /usr/local/sbin/openclaw-provision.sh
    permissions: '0755'
    owner: root:root
    content: |
      #!/usr/bin/env bash
      # Installs Node.js + OpenClaw and prepares the gateway to run as an
      # always-on systemd user service. Invoked once by cloud-init runcmd.
      set -euo pipefail

      VM_USER="${1:?usage: openclaw-provision.sh <user> <node-major>}"
      NODE_MAJOR="${2:?usage: openclaw-provision.sh <user> <node-major>}"

      rm -f /var/log/openclaw-install.ok /var/log/openclaw-install.fail

      fail() {
        echo "[FAIL] $*" >&2
        printf '%s\n' "$*" > /var/log/openclaw-install.fail
        exit 1
      }

      # Safety net: fail() only covers guarded commands. If any UNGUARDED
      # command dies under set -e, still write the .fail file — the host
      # polls for .ok/.fail and would otherwise wait out its whole timeout,
      # then point the operator at a status file that does not exist.
      trap 'rc=$?; if [ "$rc" -ne 0 ] && [ ! -f /var/log/openclaw-install.fail ]; then echo "provision script exited ${rc} unexpectedly (see /var/log/openclaw-provision.log)" > /var/log/openclaw-install.fail; fi' EXIT

      # First boot races unattended-upgrades for the dpkg lock. The timeout
      # must live in apt.conf.d, not on our command lines: the NodeSource
      # setup script runs its own 'apt update'/'apt install' internally, and
      # a per-invocation -o option can never reach those.
      printf 'DPkg::Lock::Timeout "300";\n' > /etc/apt/apt.conf.d/90openclaw-lock-timeout

      echo "[*] Waiting for any in-flight apt work to finish..."
      apt-get update -qq || true

      echo "[*] Installing Node.js ${NODE_MAJOR}.x from NodeSource..."
      curl -fsSL -o /tmp/nodesource_setup.sh "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" \
        || fail "could not download NodeSource setup script for Node ${NODE_MAJOR}.x"
      bash /tmp/nodesource_setup.sh || fail "NodeSource setup script failed"
      DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs \
        || fail "apt-get install nodejs failed"

      command -v node >/dev/null 2>&1 || fail "node is not on PATH after install"
      NODE_VER="$(node -v)"
      echo "[*] Node installed: ${NODE_VER}"

      # Verify against OpenClaw's documented minimums rather than trusting the
      # repo to have shipped what we asked for. Ubuntu's own apt node is 18,
      # which silently breaks OpenClaw and anything Playwright-shaped.
      node -e '
      const [maj, min, pat] = process.versions.node.split(".").map(Number);
      const ok =
        (maj === 22 && (min > 22 || (min === 22 && pat >= 3))) ||
        (maj === 24 && min >= 15) ||
        (maj === 25 && min >= 9) ||
        maj >= 26;
      if (!ok) {
        console.error("Node " + process.versions.node + " is below OpenClaw minimums.");
        process.exit(1);
      }
      ' || fail "installed Node ${NODE_VER} is below OpenClaw minimums (22.22.3+, 24.15+, 25.9+)"

      echo "[*] Installing OpenClaw..."
      npm install -g openclaw@latest || fail "npm install -g openclaw@latest failed"

      command -v openclaw >/dev/null 2>&1 || fail "openclaw is not on PATH after npm install"
      # timeout, not just || : a command that HANGS under cloud-init (no TTY)
      # would wedge provisioning forever with no status file ever written.
      OPENCLAW_VER="$(timeout 60 openclaw --version 2>/dev/null || echo unknown)"
      echo "[*] OpenClaw installed: ${OPENCLAW_VER}"

      # The gateway runs as a systemd USER service. Without lingering it does
      # not start at boot and is killed when the user's last session exits —
      # the classic "worked when I was SSH'd in, dead by morning" failure.
      # The install page never mentions this; the gateway runbook does.
      echo "[*] Enabling systemd lingering for ${VM_USER}..."
      loginctl enable-linger "$VM_USER" || fail "loginctl enable-linger ${VM_USER} failed"

      # Pre-generate a token the operator can hand to onboarding via
      # --gateway-token and find again later. NOTHING reads this file
      # automatically — onboarding mints its own random token if it isn't
      # passed one — so the printed instructions must wire it explicitly.
      # Generated inside the VM and chmod 600 so it never reaches the
      # Proxmox host log.
      USER_HOME="$(getent passwd "$VM_USER" | cut -d: -f6)"
      [ -n "$USER_HOME" ] || fail "could not resolve home directory for ${VM_USER}"
      install -d -m 700 -o "$VM_USER" -g "$VM_USER" "$USER_HOME/.openclaw"
      TOKEN_FILE="$USER_HOME/.openclaw/gateway-token"
      if [ ! -s "$TOKEN_FILE" ]; then
        openssl rand -hex 32 > "$TOKEN_FILE" || fail "could not generate gateway token"
      fi
      chown "$VM_USER:$VM_USER" "$TOKEN_FILE"
      chmod 600 "$TOKEN_FILE"
      echo "[*] Gateway token written to ${TOKEN_FILE}"

      printf 'node=%s openclaw=%s\n' "$NODE_VER" "$OPENCLAW_VER" > /var/log/openclaw-install.ok
      echo "[*] Provisioning complete."
YAMLEOF

# --- Part 3: interpolated (runcmd) -------------------------------------------
cat >> "$USERDATA" <<EOF

runcmd:
  # Start the guest agent so the host can resolve the VM IP.
  # The package installs but may not auto-start (static preset on newer Ubuntu).
  - [ systemctl, start, qemu-guest-agent ]
  - [ bash, -c, "/usr/local/sbin/openclaw-provision.sh '${VM_USER}' '${NODE_MAJOR}' >/var/log/openclaw-provision.log 2>&1" ]
EOF

qm set "$VM_ID" --cicustom "user=${SNIPPET_STORAGE_ID}:snippets/$(basename "$USERDATA")"

OK "Cloud-init user-data attached."

############################################
# Start the VM
############################################
INFO "Starting VM..."
qm start "$VM_ID"
OK "VM started."

############################################
# Wait for provisioning + detect VM IP
############################################
# Install status is polled through the QEMU Guest Agent, NOT SSH. This is
# load-bearing: chpasswd 'expire: true' makes PAM refuse every no-TTY SSH
# command for ${VM_USER} ("Password change required but no TTY available.")
# until the password is changed interactively — SSH probes would fail for the
# entire window even when provisioning succeeded perfectly. QGA execs run as
# root inside the guest with no sshd/PAM in the path. The VM IP is collected
# opportunistically along the way; it is only needed for the printed
# instructions, never for status detection.

# Run a command inside the guest via QGA. Prints the command's stdout and
# returns its exit code; returns 125 when the agent is unreachable or the
# response is unparseable (e.g. agent not started yet).
qga_exec() {
  local raw
  raw="$(qm guest exec "$VM_ID" -- "$@" 2>/dev/null)" || return 125
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$raw" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(125)
if not d.get("exited"):
    sys.exit(125)
sys.stdout.write(d.get("out-data") or "")
code = d.get("exitcode", d.get("exit-code", 1))
sys.exit(0 if code == 0 else 1)
'
  else
    # No python3: detect success only; out-data is not extracted.
    printf '%s' "$raw" | grep -Eq '"exit-?code"[[:space:]]*:[[:space:]]*0'
  fi
}

VM_MAC="$(
  qm config "$VM_ID" 2>/dev/null | \
    awk '/^net0:/{n=split($0,a,/[=, ]+/); for(i=1;i<=n;i++)if(a[i] ~ /^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$/){print toupper(a[i]);exit}}'
)"
INFO "VM MAC: ${VM_MAC:-unknown}"

detect_ip() {
  local ipa=""
  # Fast path: neighbor table. Two traps fixed here relative to the parent
  # script: (1) neighbor entries live on the L3 device — the BRIDGE — never
  # on the enslaved tap port, so 'dev tapNNNi0' listings are empty by
  # construction; (2) 'ip neigh show dev X' OMITS the 'dev X' tokens from
  # its output, so the MAC is field $3 there, not $5. No MAC → no ARP
  # matching; the first-neighbor guess is gone (it raced the gateway).
  if [[ -n "$VM_MAC" ]]; then
    ipa="$(ip -4 neigh show dev "$BRIDGE" 2>/dev/null | \
      awk -v mac="$VM_MAC" 'tolower($3) == tolower(mac) {print $1; exit}')" || true
    if [[ -z "$ipa" ]]; then
      ipa="$(ip -4 neigh show 2>/dev/null | \
        awk -v mac="$VM_MAC" 'tolower($0) ~ tolower(mac) {print $1; exit}')" || true
    fi
  fi
  # Reliable path: ask the guest agent directly.
  # 'qm guest cmd <vmid> network-get-interfaces' is the portable form; the
  # 'qm guest network-get-interfaces <vmid>' convenience subcommand does not
  # exist on all PVE versions.
  if [[ -z "$ipa" ]] && command -v python3 >/dev/null 2>&1; then
    ipa="$(
      qm guest cmd "$VM_ID" network-get-interfaces 2>/dev/null | \
        python3 -c '
import json, sys
for iface in json.load(sys.stdin):
    if iface.get("name") in ("lo",):
        continue
    for addr in iface.get("ip-addresses", []):
        if addr.get("ip-address-type") == "ipv4":
            print(addr["ip-address"])
            sys.exit(0)
sys.exit(1)
' 2>/dev/null
    )" || true
  fi
  printf '%s' "$ipa"
}

INSTALL_OK=0
INSTALL_STATUS=""
VM_IP=""
IP_GRACE=12   # extra iterations to keep hunting for the IP once status is known

# ~17 min budget (204 x 5s + QGA call overhead). First boot runs a full
# apt update + 8-package install before runcmd even starts, so the guest
# agent routinely takes several minutes to appear — that silence is normal.
INFO "Waiting for provisioning (Node + OpenClaw) — up to ~17 minutes..."
for _ in {1..204}; do
  if [[ -z "$VM_IP" ]]; then
    VM_IP="$(detect_ip)"
    [[ -n "$VM_IP" ]] && INFO "Detected VM IP: ${VM_IP}"
  fi

  if [[ -z "$INSTALL_STATUS" ]]; then
    if OUT="$(qga_exec cat /var/log/openclaw-install.ok)"; then
      INSTALL_OK=1
      INSTALL_STATUS="${OUT:-ok}"
      OK "Provisioning complete: ${INSTALL_STATUS}"
    else
      rc=$?
      # rc 125 = agent not up yet (skip the second call); rc 1 = agent up
      # but no .ok file — check whether provisioning reported failure.
      if [[ $rc -ne 125 ]] && OUT="$(qga_exec cat /var/log/openclaw-install.fail)"; then
        INSTALL_STATUS="failed: ${OUT:-unknown}"
        ERROR "OpenClaw provisioning FAILED: ${OUT:-see /var/log/openclaw-provision.log in the VM}"
      fi
    fi
  fi

  if [[ -n "$INSTALL_STATUS" ]]; then
    [[ -n "$VM_IP" || $IP_GRACE -le 0 ]] && break
    IP_GRACE=$((IP_GRACE - 1))
  fi
  sleep 5
done

if [[ -z "$INSTALL_STATUS" ]]; then
  WARN "Provisioning did not report a result within the wait window."
  WARN "It may still be running (first boot does a full apt update + install)."
  INFO "Diagnostics:"
  INFO "  guest agent: $(qm guest cmd "$VM_ID" ping >/dev/null 2>&1 && echo 'responding' || echo 'not responding yet')"
  INFO "  VM status:   $(qm status "$VM_ID" 2>&1 || true)"
  WARN "Re-check later from this node (no SSH needed):"
  WARN "  qm guest exec ${VM_ID} -- cat /var/log/openclaw-install.ok"
  WARN "  qm guest exec ${VM_ID} -- tail -n 30 /var/log/openclaw-provision.log"
fi
if [[ -z "$VM_IP" ]]; then
  WARN "Could not determine the VM IP automatically."
  WARN "Find it via the VM console ('ip a'), or in your router's DHCP leases"
  WARN "under the hostname '${VM_NAME}'."
fi

############################################
# Cleanup image
############################################
rm -f "$IMG_FILE" || true

############################################
# Summary
############################################
# NOTE: do NOT 'trap - EXIT' here. The cleanup trap flushes the logging tee on
# every path, and only destroys the VM when the exit code is non-zero AND
# KEEP_VM=0. The summary below prints UNCONDITIONALLY — the onboarding
# instructions are the whole point of the script and must never be withheld
# because a status probe came back inconclusive.

SSH_TARGET="${VM_USER}@${VM_IP:-<vm-ip>}"

echo
echo "=================================================="
echo " OpenClaw VM Created"
echo "--------------------------------------------------"
echo " VMID          : ${VM_ID}"
echo " Name          : ${VM_NAME}"
echo " Storage       : ${STORAGE}"
echo " Snippets      : ${SNIPPET_STORAGE_ID}"
echo " Bridge        : ${BRIDGE}"
echo " Node.js       : ${NODE_MAJOR}.x (NodeSource)"
echo " Log file      : ${LOG_FILE}"
[[ -n "${VM_IP}" ]] && echo " VM IP         : ${VM_IP}"
if [[ "$INSTALL_OK" -eq 1 ]]; then
  echo " Provisioning  : ${GREEN}OK${RESET} (${INSTALL_STATUS})"
elif [[ -n "$INSTALL_STATUS" ]]; then
  echo " Provisioning  : ${RED}FAILED${RESET} (${INSTALL_STATUS})"
else
  echo " Provisioning  : ${YELLOW}UNCONFIRMED${RESET} (may still be running)"
fi
echo " Console login : ${VM_USER} / ${RANDOM_PASSWORD}  (change on first login)"
echo "=================================================="
echo

if [[ "$INSTALL_OK" -ne 1 ]]; then
  echo "Provisioning is not confirmed OK. The VM was left running for inspection:"
  echo "  qm guest exec ${VM_ID} -- tail -n 30 /var/log/openclaw-provision.log"
  echo "  qm guest exec ${VM_ID} -- cloud-init status --long"
  echo
  echo "The steps below assume provisioning eventually succeeds."
  echo
fi

echo "Node and OpenClaw are installed; onboarding is NOT done yet — finish it"
echo "over SSH so no API key ever touches this host's logs."
echo
echo "  1) Connect. First login forces a password change — have the console"
echo "     password from the summary above ready (PAM asks for it as the"
echo "     'current' password even over SSH key auth):"
echo "       ssh ${SSH_TARGET}"
echo
echo "  2) Run onboarding with the pre-generated gateway token. The wizard"
echo "     will ask for your LLM API key:"
echo "       openclaw onboard --install-daemon --gateway-bind lan \\"
echo "         --gateway-token \"\$(cat ~/.openclaw/gateway-token)\""
echo
echo "     Passing the token is what links that file to the gateway config —"
echo "     nothing reads it automatically. If your OpenClaw version lacks"
echo "     --gateway-token, onboarding mints its own token instead; either"
echo "     way, the AUTHORITATIVE token afterwards is the one in"
echo "     ~/.openclaw/openclaw.json under gateway.auth.token."
echo
echo "  3) Start it. On a headless box XDG_RUNTIME_DIR must be exported"
echo "     before any systemctl --user call, or it fails to find the bus:"
echo "       export XDG_RUNTIME_DIR=/run/user/\$(id -u)"
echo "       systemctl --user enable --now openclaw-gateway.service"
echo "       openclaw gateway status"
echo
echo "     (systemd lingering is already enabled for ${VM_USER}, so the"
echo "      gateway survives logout and starts at boot.)"
echo
echo "  Control UI once running:  http://${VM_IP:-<vm-ip>}:18789"
echo "  Logs:                     journalctl --user -u openclaw-gateway -f"
echo
echo "${YELLOW}SECURITY${RESET} — you chose a LAN bind. OpenClaw's docs are blunt about this:"
echo "  \"Never expose the Gateway unauthenticated on 0.0.0.0.\" A LAN bind"
echo "  listens on 0.0.0.0, so keep auth.mode=token and firewall 18789 to a"
echo "  tight source-IP allowlist. If Tailscale is an option, the docs prefer"
echo "  it over a LAN bind — as Tailscale Serve (gateway stays on loopback;"
echo "  'openclaw gateway --tailscale serve'), or as a direct tailnet bind"
echo "  (--gateway-bind tailnet). These are two different mechanisms."
echo

if [[ "$INSTALL_OK" -eq 1 ]]; then
  exit 0
else
  # Exit 2: the VM exists and is deliberately kept, but provisioning failed
  # or went unconfirmed — scripted callers must not mistake this for success.
  KEEP_VM=1
  exit 2
fi
