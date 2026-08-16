#!/bin/bash
# docker-entrypoint.sh — first-boot profile setup + `dsh web` launcher.
#
# The container starts as root (the image declares no USER). The entrypoint:
#   1. creates the data roots, and when running as root owns them so the
#      runtime user (uid 1000) can write everywhere — this self-heals
#      root-owned persistent volumes (K8s / RainYun volumes do NOT inherit
#      image ownership, unlike Docker named volumes);
#   2. writes the webserver patch (the CLI refuses `--host 0.0.0.0` by design,
#      but the profile user layer overrides the bundle row);
#   3. drops privileges to uid 1000 (node) for every long-lived process.
#
# Auth mode (default on, env DSH_AUTH=1): dsh binds 127.0.0.1:3081 and the
# built-in auth gate (auth-proxy.js) binds 0.0.0.0:${PORT}, enforcing
# first-visit password registration + login. With DSH_AUTH=0 the gate is
# skipped and dsh binds 0.0.0.0:${PORT} directly (legacy behavior).
set -euo pipefail

# Build marker: bump on every image publish so deployments can verify from the
# logs which build is actually running (RainYun caches images by tag).
DSH_DOCKER_BUILD="${DSH_DOCKER_BUILD:-2026-08-16-3}"

RUNTIME_UID="${DSH_RUNTIME_UID:-1000}"
RUNTIME_GID="${DSH_RUNTIME_GID:-1000}"

export DSH_HOME="${DSH_HOME:-/data}"

# Sanitize PORT: must be a valid port number.
PORT="${PORT:-3080}"
if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
  echo "[dsh-entrypoint] invalid PORT '$PORT', falling back to 3080" >&2
  PORT=3080
fi

AUTH_MODE="${DSH_AUTH:-1}"
DSH_INTERNAL_PORT="${DSH_INTERNAL_PORT:-3081}"

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
#    Auth mode: dsh stays on loopback; the auth gate owns the public port.
#    Legacy mode: dsh binds 0.0.0.0:${PORT}.
if [ "$AUTH_MODE" = "0" ]; then
  BIND_HOST="0.0.0.0"
  BIND_PORT="$PORT"
else
  BIND_HOST="127.0.0.1"
  BIND_PORT="$DSH_INTERNAL_PORT"
fi

if [ ! -f "$PROFILE_PATCH" ]; then
  if ! cat > "$PROFILE_PATCH" <<PATCH
# Managed by docker-entrypoint.sh — dsh web deployment overrides.
# Edit freely; this layer hot-reloads and user edits are never overwritten.
- id: webserver
  config:
    host: '$BIND_HOST'
    port: $BIND_PORT
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
  echo "[dsh-entrypoint] wrote $PROFILE_PATCH (bind ${BIND_HOST}:${BIND_PORT})"
elif grep -q '^    host:' "$PROFILE_PATCH" && ! grep -q "port: $BIND_PORT" "$PROFILE_PATCH"; then
  echo "[dsh-entrypoint] warning: $PROFILE_PATCH pins another port than $BIND_PORT; delete the file (or edit it) to re-bind" >&2
fi

# /api browser-trust fence authorities, space-separated in DSH_TRUSTED_HOSTS.
# Each entry must be a bare host[:port] — no scheme, no path, no trailing
# slash. Normalize common pasted-URL mistakes (http://, paths, trailing /)
# so users can fill the browser URL verbatim. Only meaningful in legacy mode;
# in auth mode dsh is loopback-only and the gate strips Origin, so the fence
# passes without any entry.
TRUSTED_ARGS=()
for authority in ${DSH_TRUSTED_HOSTS:-}; do
  normalized="$authority"
  case "$normalized" in
    http://*)  normalized="${normalized#http://}" ;;
    https://*) normalized="${normalized#https://}" ;;
  esac
  normalized="${normalized%%/*}"   # drop path / query
  normalized="${normalized%%\?*}"
  normalized="${normalized%/}"     # drop trailing slash
  if [ -n "$normalized" ]; then
    TRUSTED_ARGS+=(--trusted-host "$normalized")
  fi
done
if [ "${#TRUSTED_ARGS[@]}" -gt 0 ]; then
  echo "[dsh-entrypoint] trust fence authorities: ${TRUSTED_ARGS[*]}"
fi

run_as_node() {
  # "$@" is the full argv to run as uid 1000
  if [ "$(id -u)" = "0" ]; then
    exec setpriv --reuid="$RUNTIME_UID" --regid="$RUNTIME_GID" --clear-groups \
      env HOME=/home/node DSH_HOME="$DSH_HOME" "$@"
  else
    exec env DSH_HOME="$DSH_HOME" "$@"
  fi
}

echo "[dsh-entrypoint] starting dsh web on ${BIND_HOST}:${BIND_PORT} (DSH_HOME=$DSH_HOME, build=$DSH_DOCKER_BUILD, auth=$AUTH_MODE)"

if [ "$AUTH_MODE" = "0" ]; then
  run_as_node dsh web "${TRUSTED_ARGS[@]}"
fi

# Auth mode: run dsh in the background on loopback, then exec the gate.
run_as_node dsh web "${TRUSTED_ARGS[@]}" &
DSH_PID=$!

READY=0
for _ in $(seq 1 60); do
  if curl -sf -o /dev/null "http://127.0.0.1:${DSH_INTERNAL_PORT}/" 2>/dev/null; then
    READY=1
    break
  fi
  sleep 1
done
if [ "$READY" != "1" ]; then
  echo "[dsh-entrypoint] FATAL: dsh did not become ready on 127.0.0.1:${DSH_INTERNAL_PORT} (pid $DSH_PID)" >&2
  kill "$DSH_PID" 2>/dev/null || true
  exit 1
fi

echo "[dsh-entrypoint] dsh ready on 127.0.0.1:${DSH_INTERNAL_PORT}; starting auth gate on 0.0.0.0:${PORT}"
export PORT DSH_INTERNAL_PORT
export DSH_AUTH_DIR="$DSH_HOME/auth"
run_as_node node /usr/local/bin/auth-proxy.js
