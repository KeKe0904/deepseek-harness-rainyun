#!/bin/bash
# smoke-test.sh — scripted smoke tests for the deepseek-harness image.
#
# Usage: ./smoke-test.sh [image-tag]
#   image-tag defaults to deepseek-harness:0.1.0-rc.6
#
# Covers: entrypoint/profile init, 0.0.0.0 bind, HTTP + __DSH_BOOT__,
# /api trust fence, sandbox (bwrap optional, Landlock probe + real wrap run),
# persistence across restart. Exits non-zero on first failure.
set -euo pipefail

IMAGE="${1:-deepseek-harness:0.1.0-rc.6}"
NAME="dsh-smoke"
VOL="dsh-smoke-data"
PORT="${SMOKE_PORT:-3081}"
FAILED=0

say()  { printf '\n==> %s\n' "$*"; }
ok()   { printf '    [PASS] %s\n' "$*"; }
fail() { printf '    [FAIL] %s\n' "$*"; FAILED=1; }

cleanup() {
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  docker volume rm "$VOL" >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup

say "starting container from $IMAGE"
docker run -d --name "$NAME" \
  -p "$PORT:3080" \
  -v "$VOL:/data" \
  -e DSH_HOME=/data \
  -e PORT=3080 \
  -e 'DSH_TRUSTED_HOSTS=localhost smoke.example.com:3080' \
  "$IMAGE" >/dev/null

for i in $(seq 1 30); do
  docker logs "$NAME" 2>&1 | grep -q 'dsh web:' && break
  sleep 1
done

say "entrypoint wrote the profile patch with 0.0.0.0 bind"
docker exec "$NAME" grep -q "host: '0.0.0.0'" /data/profiles/web/cordis.patch.yml \
  && ok "patch host 0.0.0.0" || fail "patch missing"

say "server responds + __DSH_BOOT__ injected"
code=$(curl -s -o /tmp/dsh-index.html -w '%{http_code}' "http://127.0.0.1:$PORT/")
[ "$code" = "200" ] && grep -q '__DSH_BOOT__' /tmp/dsh-index.html \
  && ok "http 200 with __DSH_BOOT__" || fail "http $code / no boot manifest"

say "0.0.0.0:3080 listener"
docker exec "$NAME" grep -q '00000000:0C08' /proc/net/tcp \
  && ok "listening 0.0.0.0:3080" || fail "not listening on 0.0.0.0:3080"

say "trust fence"
unknown=$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: evil.example:3080' "http://127.0.0.1:$PORT/api/health" || true)
trusted=$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: smoke.example.com:3080' "http://127.0.0.1:$PORT/")
[ "$unknown" = "403" ] && ok "unknown host /api -> 403" || fail "unknown host /api -> $unknown"
[ "$trusted" = "200" ] && ok "trusted host -> 200" || fail "trusted host -> $trusted"

say "sandbox: Landlock probe"
docker exec "$NAME" sh -c 'cd /usr/local/lib/node_modules/@deepseek-ai/dsh && node -e "
const m=require(\"@deepseek-ai/node-addon-landlock-run\");
const r=m.probe(m.launcherPath());
console.log(\"landlock:\", r);
process.exit(r===\"unusable\"?1:0)"' \
  && ok "landlock full/partial" || fail "landlock unusable"

say "sandbox: real confined bash run (same chain dsh-sandbox-local uses)"
out=$(docker exec "$NAME" sh -c 'cd /usr/local/lib/node_modules/@deepseek-ai/dsh && node -e "
const {spawn}=require(\"child_process\");
const m=require(\"@deepseek-ai/node-addon-landlock-run\");
const argv=[m.launcherPath(),...m.grantArgs({readOnly:[\"/\"],readWrite:[\"/tmp\"]}),\"--\",\"bash\",\"-c\",\"echo SANDBOX_OK\"];
spawn(argv[0],argv.slice(1)).stdout.on(\"data\",d=>process.stdout.write(d));"')
[ "$out" = "SANDBOX_OK" ] && ok "confined bash works" || fail "confined bash failed: $out"

say "persistence across restart"
docker exec "$NAME" touch /data/PERSIST-MARKER
docker restart "$NAME" >/dev/null
sleep 5
docker exec "$NAME" test -f /data/PERSIST-MARKER \
  && ok "data survived restart" || fail "data lost on restart"

say "final health"
sleep 25
h=$(docker inspect -f '{{.State.Health.Status}}' "$NAME")
[ "$h" = "healthy" ] && ok "healthcheck healthy" || fail "healthcheck: $h"

echo
if [ "$FAILED" = "0" ]; then
  echo "ALL SMOKE TESTS PASSED"
else
  echo "SOME TESTS FAILED"
fi
exit "$FAILED"
