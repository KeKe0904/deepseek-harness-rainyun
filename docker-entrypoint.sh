#!/bin/bash
# docker-entrypoint.sh — first-boot profile setup + `dsh web` launcher.
#
# The container starts as root (the image declares no USER). The entrypoint:
#   1. creates the data roots, and when running as root owns them so the
#      runtime user (uid 1000) can write everywhere — this self-heals
#      root-owned persistent volumes (K8s / RainYun volumes do NOT inherit
#      image ownership, unlike Docker named volumes);
#   2. writes the webserver patch (bind 0.0.0.0; the CLI refuses
#      `--host 0.0.0.0` by design, but the profile user layer overrides the
#      bundle row);
#   3. drops privileges to uid 1000 (node) and execs `dsh web` so the harness
#      itself never runs as root. Landlock confinement works unprivileged.
set -euo pipefail

# Build marker: bump on every image publish so deployments can verify from the
# logs which build is actually running (RainYun caches images by tag).
DSH_DOCKER_BUILD="${DSH_DOCKER_BUILD:-2026-08-16-1}"

RUNTIME_UID="${DSH_RUNTIME_UID:-1000}"
RUNTIME_GID="${DSH_RUNTIME_GID:-1000}"

export DSH_HOME="${DSH_HOME:-/data}"

# Sanitize PORT: must be a valid port number.
PORT="${PORT:-3080}"
if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
  echo "[dsh-entrypoint] invalid PORT '$PORT', falling back to 3080" >&2
  PORT=3080
fi

PROFILE_DIR="$DSH_HOME/profiles/web"
PROFILE_PATCH="$PROFILE_DIR/cordis.patch.yml"

# 1) Create the data roots, then own them so the runtime user can write
#    everywhere. Order matters: chowning BEFORE creating nested dirs would
#    leave the new dirs root-owned (EACCES on profiles/node_modules).
#    A fresh/root-owned volume (K8s / RainYun PVs do not inherit image
#    ownership) is chowned recursively once; otherwise only the roots and the
#    profiles subtree created here are owned, keeping restarts fast.
if [ "$(id -u)" = "0" ]; then
  mkdir -p "$PROFILE_DIR" /workspace
  if [ "$(stat -c %u "$DSH_HOME")" != "$RUNTIME_UID" ] \
     || [ "$(stat -c %u /workspace)" != "$RUNTIME_UID" ]; then
    echo "[dsh-entrypoint] fixing ownership of volume roots -> uid $RUNTIME_UID (volume was not writable by the runtime user)"
    chown -R "$RUNTIME_UID:$RUNTIME_GID" "$DSH_HOME"
    chown -R "$RUNTIME_UID:$RUNTIME_GID" /workspace
  else
    chown "$RUNTIME_UID:$RUNTIME_GID" "$DSH_HOME" /workspace
    # The profiles subtree (just created) must be owned by the runtime user
    # INCLUDING its parent, or dsh cannot create profiles/node_modules.
    chown -R "$RUNTIME_UID:$RUNTIME_GID" "$DSH_HOME/profiles"
  fi
else
  mkdir -p "$PROFILE_DIR" /workspace 2>/dev/null || true
fi

# 2) Write the webserver override patch once (never overwrite user edits).
if [ ! -f "$PROFILE_PATCH" ]; then
  if ! cat > "$PROFILE_PATCH" <<PATCH
# Managed by docker-entrypoint.sh — dsh web deployment overrides.
# Edit freely; this layer hot-reloads and user edits are never overwritten.
- id: webserver
  config:
    host: '0.0.0.0'
    port: $PORT
PATCH
  then
    echo "[dsh-entrypoint] FATAL: cannot write $PROFILE_PATCH (Permission denied)." >&2
    echo "[dsh-entrypoint] The persistent volume at $DSH_HOME must be writable by uid $RUNTIME_UID," >&2
    echo "[dsh-entrypoint] or the container must start as root so the entrypoint can fix ownership." >&2
    exit 1
  fi
  if [ "$(id -u)" = "0" ]; then
    chown "$RUNTIME_UID:$RUNTIME_GID" "$PROFILE_PATCH"
  fi
  echo "[dsh-entrypoint] wrote $PROFILE_PATCH (bind 0.0.0.0:${PORT})"
elif grep -q '^    host:' "$PROFILE_PATCH" && ! grep -q "port: $PORT" "$PROFILE_PATCH"; then
  echo "[dsh-entrypoint] warning: $PROFILE_PATCH pins another port than PORT=$PORT; delete the file (or edit it) to re-bind" >&2
fi

# /api browser-trust fence authorities, space-separated in DSH_TRUSTED_HOSTS.
TRUSTED_ARGS=()
for authority in ${DSH_TRUSTED_HOSTS:-}; do
  TRUSTED_ARGS+=(--trusted-host "$authority")
done

echo "[dsh-entrypoint] starting dsh web on 0.0.0.0:${PORT} (DSH_HOME=$DSH_HOME, build=$DSH_DOCKER_BUILD)"
if [ "$(id -u)" = "0" ]; then
  exec setpriv --reuid="$RUNTIME_UID" --regid="$RUNTIME_GID" --clear-groups \
    env HOME=/home/node DSH_HOME="$DSH_HOME" \
    dsh web "${TRUSTED_ARGS[@]}"
else
  exec dsh web "${TRUSTED_ARGS[@]}"
fi
