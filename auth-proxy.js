#!/usr/bin/env node
/**
 * dsh-auth-proxy — minimal password gate in front of the dsh web server.
 *
 * Built into the image (default on, env DSH_AUTH=1). dsh itself binds only
 * 127.0.0.1:DSH_INTERNAL_PORT; this gate binds 0.0.0.0:PORT and forwards to
 * it, so nothing else on the network can reach dsh.
 *
 * Flow:
 *   - No password registered yet -> every request is redirected to /register;
 *     POST /register stores a scrypt(password, salt) hash in
 *     DSH_AUTH_DIR/password.json (persisted on the volume).
 *   - Afterwards /login verifies the password and issues an HMAC-signed
 *     session cookie (30 days, HttpOnly, SameSite=Lax).
 *   - Everything else requires a valid cookie: browser navigations are
 *     redirected to /login, API/asset requests get 401.
 *   - Authenticated traffic is proxied to dsh with the Host header rewritten
 *     to loopback and the Origin header stripped, so dsh's own browser-trust
 *     fence passes without any DSH_TRUSTED_HOSTS configuration.
 *
 * Reset: delete DSH_AUTH_DIR (e.g. /data/auth) and the next visit shows the
 * registration page again.
 *
 * Zero dependencies: node:http + node:crypto only.
 */
import http from 'node:http'
import crypto from 'node:crypto'
import fs from 'node:fs'
import path from 'node:path'

const PUBLIC_PORT = Number(process.env.PORT || 3080)
const INTERNAL_PORT = Number(process.env.DSH_INTERNAL_PORT || 3081)
const AUTH_DIR = process.env.DSH_AUTH_DIR || '/data/auth'
const SESSION_TTL_MS = 30 * 24 * 3600 * 1000
const MIN_PASSWORD = 8
const MAX_LOGIN_FAILS = 10
const LOCKOUT_MS = 5 * 60 * 1000

const passwordFile = path.join(AUTH_DIR, 'password.json')
const secretFile = path.join(AUTH_DIR, 'secret')

fs.mkdirSync(AUTH_DIR, { recursive: true })

let secret
try {
  secret = fs.readFileSync(secretFile)
} catch {
  secret = crypto.randomBytes(32)
  fs.writeFileSync(secretFile, secret, { mode: 0o600 })
}

const hasPassword = () => fs.existsSync(passwordFile)

function readJson(file, dflt) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')) } catch { return dflt }
}

function verifyPasswordSync(password, record) {
  try {
    const expected = crypto.scryptSync(password, Buffer.from(record.salt, 'hex'), 64)
    return crypto.timingSafeEqual(expected, Buffer.from(record.hash, 'hex'))
  } catch { return false }
}

// Password managed by the operator via env (recommended for RainYun): the
// password lives in the deployment spec, not only on the volume, so a volume
// wipe/recreation cannot reset access back to the registration page. When set,
// the gate (re)creates the password file from it at startup.
if (process.env.DSH_AUTH_PASSWORD) {
  const pw = process.env.DSH_AUTH_PASSWORD
  if (pw.length < MIN_PASSWORD) {
    console.error(`[auth] FATAL: DSH_AUTH_PASSWORD is shorter than ${MIN_PASSWORD} characters`)
    process.exit(1)
  }
  const record = readJson(passwordFile, null)
  if (record && verifyPasswordSync(pw, record)) {
    console.log('[auth] password file matches DSH_AUTH_PASSWORD')
  } else {
    const salt = crypto.randomBytes(16)
    const hash = crypto.scryptSync(pw, salt, 64)
    fs.writeFileSync(passwordFile, JSON.stringify({
      salt: salt.toString('hex'),
      hash: hash.toString('hex'),
      created: new Date().toISOString(),
      source: 'env',
    }, null, 2), { mode: 0o600 })
    console.log(record
      ? '[auth] password file was missing/mismatched — recreated from DSH_AUTH_PASSWORD'
      : '[auth] password created from DSH_AUTH_PASSWORD (registration page disabled)')
  }
}

function scryptHash(password, salt) {
  return new Promise((resolve, reject) => {
    crypto.scrypt(password, salt, 64, (err, key) => (err ? reject(err) : resolve(key)))
  })
}

async function verifyPassword(password, record) {
  try {
    const expected = await scryptHash(password, Buffer.from(record.salt, 'hex'))
    return crypto.timingSafeEqual(expected, Buffer.from(record.hash, 'hex'))
  } catch { return false }
}

function signSession() {
  const payload = Buffer.from(JSON.stringify({ exp: Date.now() + SESSION_TTL_MS })).toString('base64url')
  const mac = crypto.createHmac('sha256', secret).update(payload).digest('base64url')
  return `${payload}.${mac}`
}

function verifySession(value) {
  if (!value) return false
  const dot = value.indexOf('.')
  if (dot <= 0) return false
  const payload = value.slice(0, dot)
  const mac = value.slice(dot + 1)
  const expect = crypto.createHmac('sha256', secret).update(payload).digest('base64url')
  const a = Buffer.from(mac)
  const b = Buffer.from(expect)
  if (a.length !== b.length || !crypto.timingSafeEqual(a, b)) return false
  try {
    const p = JSON.parse(Buffer.from(payload, 'base64url').toString('utf8'))
    return typeof p.exp === 'number' && p.exp > Date.now()
  } catch { return false }
}

function cookieSession(req) {
  const m = /(?:^|;\s*)dsh_session=([^;]+)/.exec(req.headers.cookie || '')
  if (!m) return false
  try {
    return verifySession(decodeURIComponent(m[1]))
  } catch {
    return false // malformed cookie must never crash the gate
  }
}

// ---- trivial per-IP rate limit for /login ----
const fails = new Map()
function rateAllowed(ip) {
  const r = fails.get(ip)
  if (!r) return true
  if (r.until > Date.now()) return false
  fails.delete(ip)
  return true
}
function rateFail(ip) {
  const r = fails.get(ip) || { n: 0, until: 0 }
  r.n += 1
  if (r.n >= MAX_LOGIN_FAILS) { r.until = Date.now() + LOCKOUT_MS; r.n = 0 }
  fails.set(ip, r)
}
function rateOk(ip) { fails.delete(ip) }

// ---- tiny inline pages ----
const base = (title, body) => `<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${title}</title><style>
body{font-family:system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;background:#0f1115;color:#e6e8eb;display:flex;align-items:center;justify-content:center;min-height:100vh;margin:0}
.card{background:#171a21;border:1px solid #262b36;border-radius:12px;padding:32px;width:320px;box-shadow:0 8px 30px rgba(0,0,0,.4)}
h2{margin:0 0 6px;font-size:18px}p.note{margin:0 0 20px;color:#8b93a1;font-size:13px;line-height:1.6}
input{width:100%;box-sizing:border-box;padding:10px 12px;margin:6px 0 14px;border:1px solid #2c3340;border-radius:8px;background:#10131a;color:#e6e8eb;font-size:14px}
button{width:100%;padding:10px;border:0;border-radius:8px;background:#4f7cff;color:#fff;font-size:14px;cursor:pointer}
button:hover{background:#3f66d9}.err{color:#ff6b6b;font-size:13px;margin:0 0 12px}
</style></head><body><div class="card">${body}</div></body></html>`

const registerPage = (err = '') => base('设置访问密码', `
<h2>首次使用：设置访问密码</h2>
<p class="note">此实例尚未设置密码。请设置一个至少 ${MIN_PASSWORD} 位的密码，之后访问都需要登录。</p>
${err ? `<p class="err">${err}</p>` : ''}
<form method="post" action="/register">
  <input type="password" name="password" placeholder="设置密码（至少 ${MIN_PASSWORD} 位）" minlength="${MIN_PASSWORD}" required autofocus>
  <input type="password" name="confirm" placeholder="确认密码" minlength="${MIN_PASSWORD}" required>
  <button type="submit">创建密码</button>
</form>`)

const loginPage = (err = '') => base('登录', `
<h2>登录</h2>
<p class="note">请输入访问密码。</p>
${err ? `<p class="err">${err}</p>` : ''}
<form method="post" action="/login">
  <input type="password" name="password" placeholder="密码" required autofocus>
  <button type="submit">登录</button>
</form>`)

function sendHtml(res, code, html) {
  res.writeHead(code, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' })
  res.end(html)
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let size = 0
    const chunks = []
    req.on('data', (c) => {
      size += c.length
      if (size > 1024 * 1024) { reject(new Error('body too large')); req.destroy() }
      else chunks.push(c)
    })
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')))
    req.on('error', reject)
  })
}

// ---- forward authenticated traffic to dsh (loopback, Host rewritten) ----
function forward(req, res) {
  const headers = { ...req.headers }
  headers.host = `127.0.0.1:${INTERNAL_PORT}`
  delete headers.origin // dsh fence compares Origin to Host; rewritten Host is loopback
  const up = http.request({
    host: '127.0.0.1', port: INTERNAL_PORT, path: req.url, method: req.method, headers,
  }, (ures) => {
    res.writeHead(ures.statusCode, ures.headers)
    ures.pipe(res)
  })
  up.on('error', () => {
    res.writeHead(502, { 'content-type': 'text/plain' })
    res.end('bad gateway')
  })
  req.pipe(up)
}

const server = http.createServer(async (req, res) => {
  const pathname = (new URL(req.url, 'http://local')).pathname
  const ip = req.socket.remoteAddress || '?'

  if (!hasPassword()) {
    if (pathname === '/register') {
      if (req.method === 'POST') {
        let params
        try {
          params = new URLSearchParams(await readBody(req))
        } catch { return sendHtml(res, 400, registerPage('请求无效')) }
        const pw = params.get('password') || ''
        const cf = params.get('confirm') || ''
        if (pw.length < MIN_PASSWORD) return sendHtml(res, 400, registerPage(`密码至少 ${MIN_PASSWORD} 位`))
        if (pw !== cf) return sendHtml(res, 400, registerPage('两次输入的密码不一致'))
        const salt = crypto.randomBytes(16)
        const hash = await scryptHash(pw, salt)
        fs.writeFileSync(passwordFile, JSON.stringify({
          salt: salt.toString('hex'), hash: hash.toString('hex'), created: new Date().toISOString(),
        }, null, 2), { mode: 0o600 })
        console.log('[auth] password registered (restart-safe, stored on volume)')
        res.writeHead(302, { location: '/login' })
        return res.end()
      }
      return sendHtml(res, 200, registerPage())
    }
    res.writeHead(302, { location: '/register' })
    return res.end()
  }

  if (pathname === '/login') {
    if (req.method === 'POST') {
      if (!rateAllowed(ip)) return sendHtml(res, 429, loginPage('尝试过于频繁，请 5 分钟后再试'))
      let params
      try { params = new URLSearchParams(await readBody(req)) } catch { return sendHtml(res, 400, loginPage('请求无效')) }
      const record = readJson(passwordFile, null)
      const ok = !!record && await verifyPassword(params.get('password') || '', record)
      if (!ok) {
        rateFail(ip)
        return sendHtml(res, 401, loginPage('密码错误'))
      }
      rateOk(ip)
      const maxAge = Math.floor(SESSION_TTL_MS / 1000)
      res.writeHead(302, {
        location: '/',
        'set-cookie': `dsh_session=${signSession()}; Path=/; HttpOnly; SameSite=Lax; Max-Age=${maxAge}`,
      })
      return res.end()
    }
    return sendHtml(res, 200, loginPage())
  }

  if (pathname === '/logout') {
    res.writeHead(302, { location: '/login', 'set-cookie': 'dsh_session=; Path=/; HttpOnly; Max-Age=0' })
    return res.end()
  }

  if (!cookieSession(req)) {
    const accept = req.headers.accept || ''
    if (accept.includes('text/html')) {
      res.writeHead(302, { location: '/login' })
      res.end()
    } else {
      res.writeHead(401, { 'content-type': 'application/json', 'cache-control': 'no-store' })
      res.end(JSON.stringify({ error: 'unauthorized' }))
    }
    return
  }

  forward(req, res)
})

// WebSocket/upgrade forwarding (same gate + Host rewrite)
server.on('upgrade', (req, socket) => {
  if (!cookieSession(req)) { socket.destroy(); return }
  const headers = { ...req.headers, host: `127.0.0.1:${INTERNAL_PORT}` }
  delete headers.origin
  const up = http.request({ host: '127.0.0.1', port: INTERNAL_PORT, path: req.url, headers, method: req.method })
  up.on('upgrade', (ures, usock, head) => {
    socket.write('HTTP/1.1 101 Switching Protocols\r\n\r\n')
    if (head && head.length) usock.unshift(head)
    usock.pipe(socket)
    socket.pipe(usock)
  })
  up.on('error', () => socket.destroy())
  up.end()
})

server.listen(PUBLIC_PORT, '0.0.0.0', () => {
  console.log(`[auth] gate listening on 0.0.0.0:${PUBLIC_PORT} -> 127.0.0.1:${INTERNAL_PORT}`)
  console.log(hasPassword()
    ? '[auth] password already set; /login required'
    : '[auth] no password yet; first visit will ask to register one')
})
