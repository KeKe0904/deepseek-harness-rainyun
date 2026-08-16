// Optional operator bypass for the /api browser-trust fence.
//
// The fence normally 403s every /api request whose Host is not loopback, a
// container LAN IP, or a declared --trusted-host authority — which is why a
// RainYun deployment needs DSH_TRUSTED_HOSTS filled with the public address.
// There is no upstream config to relax it, so this build-time patch adds an
// explicit opt-out: when the operator sets DSH_TRUST_FENCE=0|false|off, the
// fence is bypassed and the app works from ANY host without configuration.
// Default (unset) keeps the fence fully intact. Note: dsh has no
// authentication layer, so with the fence off anyone who can reach the port
// can use it — document this to your users.
import { readFileSync, writeFileSync } from 'node:fs'

const file = '/usr/local/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai/dsh-client-connection/lib/index.js'
const MARK = 'DSH_TRUST_FENCE'
const src = readFileSync(file, 'utf8')

if (src.includes(MARK)) {
  console.log('[trust-fence] already patched, skipping')
  process.exit(0)
}

const needle = 'function isTrustedApiRequest(request, trustedHosts) {'
const idx = src.indexOf(needle)
if (idx === -1) throw new Error('[trust-fence] anchor not found in ' + file)

const inject =
  needle +
  '\n\tif (typeof process !== "undefined" && (process.env.DSH_TRUST_FENCE === "0" || process.env.DSH_TRUST_FENCE === "false" || process.env.DSH_TRUST_FENCE === "off")) return true;'

writeFileSync(file, src.slice(0, idx) + inject + src.slice(idx + needle.length))
console.log('[trust-fence] patched isTrustedApiRequest with DSH_TRUST_FENCE opt-out')
