// Inject a crypto.randomUUID polyfill into the served frontend index.html.
//
// dsh 0.1.0-rc.6 calls crypto.randomUUID() unguarded in the browser image
// draft-attachment path (dsh-client-ui-conversation). Browsers without the
// API (Chrome <92, Firefox <95, Safari <15.4, old WebViews such as WeChat's
// built-in browser) throw "crypto.randomUUID is not a function". The classic
// <script> below runs before any bundle and only installs the fallback when
// the native API is missing, so modern browsers are untouched.
import { readFileSync, writeFileSync } from 'node:fs'
import { createRequire } from 'node:module'

// Anchor module resolution at the dsh install so the nested
// @deepseek-ai/dsh-web-frontend package resolves regardless of cwd.
const require = createRequire('/usr/local/lib/node_modules/@deepseek-ai/dsh/package.json')
const indexPath = require.resolve('@deepseek-ai/dsh-web-frontend/dist/index.html')
const html = readFileSync(indexPath, 'utf8')

const POLYFILL = `<script>
/* dsh-docker: crypto.randomUUID polyfill for old browsers/WebViews */
(function () {
  if (typeof crypto === 'undefined' || typeof crypto.randomUUID === 'function') return;
  var getBytes = (typeof crypto.getRandomValues === 'function')
    ? function (n) { var b = new Uint8Array(n); crypto.getRandomValues(b); return b; }
    : function (n) { var b = new Uint8Array(n); for (var i = 0; i < n; i++) b[i] = Math.floor(Math.random() * 256); return b; };
  try {
    crypto.randomUUID = function randomUUID() {
      var b = getBytes(16);
      b[6] = (b[6] & 0x0f) | 0x40;
      b[8] = (b[8] & 0x3f) | 0x80;
      var h = '';
      for (var i = 0; i < 16; i++) {
        h += (i === 4 || i === 6 || i === 8 || i === 10 ? '-' : '') + b[i].toString(16).padStart(2, '0');
      }
      return h;
    };
  } catch (e) { /* never break the page over a polyfill */ }
})();
</script>`

if (html.includes('dsh-docker: crypto.randomUUID polyfill')) {
  console.log('[polyfill] index.html already patched, skipping')
} else {
  const injected = html.replace('</head>', POLYFILL + '\n  </head>')
  if (injected === html) throw new Error('[polyfill] </head> not found in index.html')
  writeFileSync(indexPath, injected)
  console.log('[polyfill] injected crypto.randomUUID polyfill into', indexPath)
}
