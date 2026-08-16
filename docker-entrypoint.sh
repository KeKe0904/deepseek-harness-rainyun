#!/bin/bash
# docker-entrypoint.sh — first-boot profile setup + `dsh web` launcher.
#
# Why this exists:
#   1. `dsh web` refuses `--host 0.0.0.0` by design (it would expose remote
#      code execution). The webserver plugin itself supports binding 0.0.0.0,
#      and the profile's own cordis.patch.yml (the user patch layer, applied
#      after the bundle layers) overrides the webserver row's config — so we
#      write that override BEFORE the first boot. dsh never overwrites an
#      existing cordis.patch.yml, and the file hot-reloads, so user edits are
#      respected afterwards.
#   2. The /api browser-trust fence 403s every non-loopback Host unless it is
#      declared via --trusted-host. DSH_TRUSTED_HOSTS (space-separated
#      host[:port] entries) is forwarded to those flags.
set -euo pipefail

export DSH_HOME="${DSH_HOME:-/data}"

# Sanitize PORT: must be a valid port number.
PORT="${PORT:-3080}"
if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
  echo "[dsh-entrypoint] invalid PORT '$PORT', falling back to 3080" >&2
  PORT=3080
fi

PROFILE_DIR="$DSH_HOME/profiles/web"
PROFILE_PATCH="$PROFILE_DIR/cordis.patch.yml"

if [ ! -f "$PROFILE_PATCH" ]; then
  mkdir -p "$PROFILE_DIR"
  cat > "$PROFILE_PATCH" <<PATCH
# Managed by docker-entrypoint.sh — dsh web deployment overrides.
# Edit freely; this layer hot-reloads and user edits are never overwritten.
- id: webserver
  config:
    host: '0.0.0.0'
    port: $PORT
PATCH
  echo "[dsh-entrypoint] wrote $PROFILE_PATCH (bind 0.0.0.0:${PORT})"
elif grep -q '^    host:' "$PROFILE_PATCH" && ! grep -q "port: $PORT" "$PROFILE_PATCH"; then
  echo "[dsh-entrypoint] warning: $PROFILE_PATCH pins another port than PORT=$PORT; delete the file (or edit it) to re-bind" >&2
fi

# /api browser-trust fence authorities, space-separated in DSH_TRUSTED_HOSTS.
TRUSTED_ARGS=()
for authority in ${DSH_TRUSTED_HOSTS:-}; do
  TRUSTED_ARGS+=(--trusted-host "$authority")
done

echo "[dsh-entrypoint] starting dsh web on 0.0.0.0:${PORT} (DSH_HOME=$DSH_HOME)"
exec dsh web "${TRUSTED_ARGS[@]}"
