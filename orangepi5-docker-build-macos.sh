#!/usr/bin/env bash
#
# orangepi5-docker-build-macos.sh
# ------------------------------------------------------------------------------
# Reproducible Orange Pi 5 (RK3588S) image build on macOS / Apple Silicon using
# Colima's Docker. orangepi-build is Linux-only, so we run it inside a privileged
# Ubuntu 22.04 container (arm64 == native, no QEMU). This script encapsulates all
# the fixes discovered while getting it to work on a bare ubuntu:22.04:
#
#   * installs deps that prepare_host omits but the repo Dockerfile needs
#     (fdisk/sfdisk, kpartx, sudo, locales, lsb-release, xxd, xfsprogs, ...)
#   * installs a `losetup` shim that creates loop partition nodes via device-mapper
#     because the Colima VM kernel has loop `max_part=0` (built-in, non-reloadable),
#     so `losetup -P` never creates /dev/loopNpM on its own.
#   * keeps the whole build tree (sources, compiled debs, rootfs cache, ccache) in
#     a persistent named Docker volume mounted at /root/orangepi-build, so it
#     survives `docker rm` / container recreation and never needs a full rebuild.
#     Artifacts + logs are still copied back to ./output on the Mac.
#
# Usage:
#   bash orangepi5-docker-build-macos.sh                # server image, jammy, current
#   BUILD_DESKTOP=yes RELEASE=bookworm bash orangepi5-docker-build-macos.sh
#   CLEAN_LEVEL=debs,oldcache bash orangepi5-docker-build-macos.sh   # force clean rebuild
#
set -euo pipefail

# ---- build parameters (override via environment) -----------------------------
BOARD="${BOARD:-orangepi5}"
BRANCH="${BRANCH:-current}"          # current = 6.1 (recommended), legacy = 5.10
RELEASE="${RELEASE:-jammy}"          # jammy | bookworm | bullseye | focal
BUILD_DESKTOP="${BUILD_DESKTOP:-no}"
BUILD_MINIMAL="${BUILD_MINIMAL:-no}"
CLEAN_LEVEL="${CLEAN_LEVEL:-}"       # empty = reuse compiled debs (fast re-runs)
CONTAINER="${CONTAINER:-opi-build}"
IMAGE="${IMAGE:-ubuntu:22.04}"
VOLUME="${VOLUME:-opi-build-tree}"   # persistent volume holding the whole build tree

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# deps the bare ubuntu:22.04 image lacks (prepare_host installs the rest itself)
EXTRA_DEPS="sudo locales ca-certificates gnupg curl git fdisk util-linux kpartx \
lsb-release xxd xfsprogs qemu-utils tzdata openssh-client python3-setuptools \
python3-pkg-resources"

log() { printf '\n\033[1;32m==>\033[0m %s\n' "$*"; }

# ---- 0. preconditions --------------------------------------------------------
docker info >/dev/null 2>&1 || {
  echo "Docker/Colima not reachable. Start it first, e.g.:"
  echo "  colima start --cpu 4 --memory 8 --disk 100"
  exit 1
}
mkdir -p "$SRC/output"

# ---- 1. persistent build-tree volume + container ----------------------------
# The build tree lives in a named Docker volume so it survives `docker rm` and
# container recreation. Docker stores it inside the Colima VM on native ext4 --
# fast, and with correct root ownership for the rootfs/chroot/mknod steps (which
# are unreliable on the virtiofs-mounted repo). Persist across removal, not just stop.
docker volume inspect "$VOLUME" >/dev/null 2>&1 || {
  log "Creating persistent build-tree volume '$VOLUME'"
  docker volume create "$VOLUME" >/dev/null
}

if ! docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  log "Creating privileged container '$CONTAINER' (volume '$VOLUME' -> /root/orangepi-build)"
  docker run -d --name "$CONTAINER" --privileged \
    -v "$VOLUME":/root/orangepi-build \
    -v "$SRC":/src:ro -v "$SRC/output":/out \
    "$IMAGE" sleep infinity >/dev/null
else
  log "Reusing existing container '$CONTAINER'"
  docker start "$CONTAINER" >/dev/null 2>&1 || true
fi

# seed the volume from the repo on first use only (skip when already populated)
if docker exec "$CONTAINER" test -f /root/orangepi-build/build.sh; then
  log "Build tree already present in volume '$VOLUME' (reusing cache)"
else
  log "Seeding build tree into volume '$VOLUME' (first run, excluding output/)"
  docker exec "$CONTAINER" bash -c \
    'mkdir -p /root/orangepi-build && tar -C /src --exclude=./output -cf - . | tar -C /root/orangepi-build -xf -'
fi

# ---- 2. dependencies (idempotent) -------------------------------------------
log "Ensuring build dependencies"
docker exec "$CONTAINER" bash -c \
  "export DEBIAN_FRONTEND=noninteractive; apt-get -qq update && \
   apt-get install -qq -y --no-install-recommends $EXTRA_DEPS >/dev/null && echo ' deps ok'"

# ---- 3. losetup partition shim (loop max_part=0 workaround) -------------------
log "Installing losetup partition shim"
cat > "$SRC/output/.losetup-shim" <<'SHIM'
#!/bin/bash
# Create loop partition nodes via device-mapper (kpartx) when the kernel's loop
# driver has max_part=0 and thus does not create /dev/loopNpM on `losetup -P`.
REAL=/usr/sbin/losetup
[[ -x $REAL ]] || REAL=/sbin/losetup
args=("$@")
for a in "${args[@]}"; do
  if [[ $a == -d || $a == -D ]]; then
    for x in "${args[@]}"; do
      if [[ $x == /dev/loop[0-9]* ]]; then
        b=$(basename "$x"); rm -f /dev/${b}p[0-9]* 2>/dev/null; kpartx -d "$x" 2>/dev/null || true
      fi
    done
    exec "$REAL" "${args[@]}"
  fi
done
out=$("$REAL" "${args[@]}"); rc=$?
[[ -n $out ]] && printf '%s\n' "$out"
[[ $rc -ne 0 ]] && exit $rc
want_p=0
for a in "${args[@]}"; do [[ $a == --partscan || $a == -*P* ]] && want_p=1; done
[[ $want_p -eq 0 ]] && exit 0
loop=""
for a in "${args[@]}"; do [[ $a == /dev/loop[0-9]* ]] && loop=$a; done
[[ -z $loop && $out == /dev/loop[0-9]* ]] && loop=$out
[[ -z $loop ]] && exit 0
[[ -b ${loop}p1 ]] && exit 0
kpartx -as "$loop" >/dev/null 2>&1 || true
b=$(basename "$loop")
for m in /dev/mapper/${b}p*; do [[ -e $m ]] && ln -sf "$m" "/dev/$(basename "$m")"; done
exit 0
SHIM
docker exec "$CONTAINER" install -m0755 /out/.losetup-shim /usr/local/bin/losetup

# ---- 4. build ----------------------------------------------------------------
log "Building: BOARD=$BOARD BRANCH=$BRANCH RELEASE=$RELEASE desktop=$BUILD_DESKTOP (CLEAN_LEVEL='${CLEAN_LEVEL}')"
# Write the in-container steps to a file (mounted at /out) and pass values via
# `docker exec -e`. This avoids all shell-quoting/escaping fragility of an inline
# `bash -c "..."` (which broke with a literal `$ec` when run via the shebang).
cat > "$SRC/output/.build-run.sh" <<'RUN'
#!/bin/bash
export DEBIAN_FRONTEND=noninteractive
cd /root/orangepi-build || exit 2
bash build.sh BOARD="$BOARD" BRANCH="$BRANCH" BUILD_OPT=image RELEASE="$RELEASE" \
  BUILD_DESKTOP="$BUILD_DESKTOP" BUILD_MINIMAL="$BUILD_MINIMAL" KERNEL_CONFIGURE=no \
  NO_APT_CACHER=yes CLEAN_LEVEL="$CLEAN_LEVEL" 2>&1 | tee /out/build.log
ec=${PIPESTATUS[0]}
mkdir -p /out/debug /out/images
cp -f output/debug/*.log /out/debug/ 2>/dev/null || true
cp -rf output/images/. /out/images/ 2>/dev/null || true
exit "$ec"
RUN
if docker exec \
  -e BOARD="$BOARD" -e BRANCH="$BRANCH" -e RELEASE="$RELEASE" \
  -e BUILD_DESKTOP="$BUILD_DESKTOP" -e BUILD_MINIMAL="$BUILD_MINIMAL" -e CLEAN_LEVEL="$CLEAN_LEVEL" \
  "$CONTAINER" bash /out/.build-run.sh; then
  log "build.sh finished ok"
else
  log "build.sh reported a non-zero exit — see output/build.log"
fi

# ---- 5. report ---------------------------------------------------------------
log "Artifacts in $SRC/output/images:"
find "$SRC"/output/images -name '*.img' -exec ls -lh {} \; 2>/dev/null \
  || echo "  (no .img produced — inspect output/build.log)"
echo
echo "Flash with:  sudo dd if=output/images/<name>/<name>.img of=/dev/rdiskN bs=4m status=progress"
