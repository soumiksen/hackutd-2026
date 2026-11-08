#!/usr/bin/env bash
# Run this on a NEW server before deploying. It checks what the Parkour stack needs and says PASS / WARN / FAIL.
#   curl -O ... or copy the file over, then:  bash check-server.sh
# It changes nothing except pulling the tiny `hello-world` Docker image when Docker is installed.
if [ "$(uname -s)" != "Linux" ]; then echo "Run this on the Linux server you plan to deploy to, not on your own computer."; exit 2; fi
PASS=0; WARN=0; FAIL=0
ok()   { echo "  PASS  $1"; PASS=$((PASS+1)); }
warn() { echo "  WARN  $1"; WARN=$((WARN+1)); }
bad()  { echo "  FAIL  $1"; FAIL=$((FAIL+1)); }

echo "Parkour server check"
. /etc/os-release 2>/dev/null
case "${ID:-}" in
  ubuntu|debian) ok "OS: ${PRETTY_NAME}";;
  *) warn "OS: ${PRETTY_NAME:-unknown}. The deploy notes assume Ubuntu 24.04 or Debian.";;
esac

arch="$(uname -m)"
[ "$arch" = "x86_64" ] && ok "CPU architecture: x86_64" || warn "CPU architecture: $arch (the images should have arm64 builds, but this is untested)"

mem_mb=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)
if   [ "$mem_mb" -ge 3500 ]; then ok "RAM: ${mem_mb} MB"
elif [ "$mem_mb" -ge 1800 ]; then warn "RAM: ${mem_mb} MB. Enough to run, tight with Chromium. 4 GB is comfortable."
else bad "RAM: ${mem_mb} MB. Chromium needs about 2 GB."; fi

cpus=$(nproc)
[ "$cpus" -ge 2 ] && ok "CPUs: $cpus" || warn "CPUs: $cpus. Registrations will be slow with 1 core."

disk_gb=$(df -BG --output=avail / | tail -1 | tr -dc 0-9)
[ "$disk_gb" -ge 15 ] && ok "Free disk: ${disk_gb} GB" || bad "Free disk: ${disk_gb} GB. Images and data need about 15 GB."

virt="$(systemd-detect-virt 2>/dev/null || echo unknown)"
case "$virt" in
  kvm|qemu|vmware|microsoft|xen|none) ok "Virtualization: $virt (Docker-friendly)";;
  openvz|lxc|lxc-libvirt|systemd-nspawn) bad "Virtualization: $virt. Container-based servers often cannot run Docker properly.";;
  *) warn "Virtualization: $virt (could not tell)";;
esac

[ "$(id -u)" -eq 0 ] || sudo -n true 2>/dev/null && ok "Root or passwordless sudo available" || warn "No root or passwordless sudo. Installing Docker will need it."

if command -v docker >/dev/null; then
  ok "Docker installed: $(docker --version | cut -d, -f1)"
  docker compose version >/dev/null 2>&1 && ok "Docker Compose plugin present" || bad "Docker Compose plugin missing (install docker-compose-plugin)"
  if docker run --rm hello-world >/dev/null 2>&1; then ok "Docker can run containers"; else bad "Docker cannot run a test container (needs root/docker group, or the host blocks it)"; fi
else
  warn "Docker not installed yet (install: https://docs.docker.com/engine/install/)"
fi

curl -fsS -m 8 -o /dev/null https://registry-1.docker.io/v2/ 2>/dev/null; rc=$?
[ "$rc" -eq 0 ] || [ "$rc" -eq 22 ] && ok "Outbound internet (Docker registry reachable)" || bad "Cannot reach the Docker registry (outbound internet or DNS problem)"
curl -fsS -m 8 -o /dev/null https://integrate.api.nvidia.com/ 2>/dev/null; rc=$?
[ "$rc" -le 22 ] && ok "NVIDIA API host reachable" || warn "Cannot reach integrate.api.nvidia.com"

for p in 80 443; do
  if (ss -ltn 2>/dev/null | awk '{print $4}' | grep -q ":$p\$"); then warn "Port $p is already in use on this server"; else ok "Port $p is free"; fi
done
pubip="$(curl -fsS -m 6 https://api.ipify.org 2>/dev/null)"
[ -n "$pubip" ] && ok "Public IPv4: $pubip (point your domain's A record here)" || warn "Could not determine a public IPv4 address"
echo "Not tested from here: whether the provider's firewall lets ports 80 and 443 in from the internet."
echo "  Test from your own machine after step 1:  curl -m 5 http://$pubip   (any answer or a refusal means it is reachable; a timeout means it is blocked)"

echo; echo "Result: $PASS pass, $WARN warn, $FAIL fail"
[ "$FAIL" -eq 0 ] && echo "This server can host Parkour." || echo "Fix the FAIL items first, or pick another provider."
exit $FAIL
