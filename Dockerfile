# syntax=docker/dockerfile:1
# DeepSeek Harness (`dsh`) — Web UI Docker image.
#
# Built from the published npm CLI (@deepseek-ai/dsh), which bundles the built
# frontend (dist) and every profile package, so no source checkout is needed.
#
# Build:  docker build -t deepseek-harness:0.1.0-rc.6 .
# Run:    docker run -d -p 3080:3080 -v dsh-data:/data deepseek-harness:0.1.0-rc.6

# ── stage 1: install the dsh CLI + compile its native addons ────────────────
FROM node:22-trixie-slim AS dsh-install
ARG DSH_VERSION=0.1.0-rc.6
# node-pty / koffi build native code at install time, so the build stage needs
# a toolchain; the runtime stage ships only the compiled artifacts.
RUN apt-get update \
 && apt-get install -y --no-install-recommends git python3 make g++ \
 && rm -rf /var/lib/apt/lists/* \
 && npm install -g @deepseek-ai/dsh@${DSH_VERSION} --no-audit --no-fund

# ── stage 2: runtime ────────────────────────────────────────────────────────
FROM node:22-trixie-slim
ENV NODE_ENV=production \
    DSH_HOME=/data \
    DSH_TELEMETRY_DISABLED=1 \
    PORT=3080
# pnpm is needed at runtime by `dsh plugin` for out-of-tree bundle installs.
ENV PNPM_HOME=/pnpm
ENV PATH=$PNPM_HOME:$PATH
RUN corepack enable \
 && corepack prepare pnpm@11.7.0 --activate
# Tools the agent needs: ripgrep (fs-search tool shells out to it), bubblewrap
# (Linux sandbox candidate; Landlock is the other, kernel 5.13+), plus common
# utilities for agent work.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ripgrep bubblewrap ca-certificates curl git procps \
 && rm -rf /var/lib/apt/lists/*

# Native addons were compiled in dsh-install; ship only the built artifacts.
COPY --from=dsh-install /usr/local/bin /usr/local/bin
COPY --from=dsh-install /usr/local/lib/node_modules /usr/local/lib/node_modules

# dsh 0.1.0-rc.6 calls crypto.randomUUID() unguarded in the browser image
# draft-attachment path; browsers without it (Chrome<92/FF<95/Safari<15.4, old
# WebViews) throw "crypto.randomUUID is not a function". Inject a polyfill
# into the served index.html so all bundles are covered.
COPY polyfill-randomuuid.mjs /usr/local/bin/
RUN node /usr/local/bin/polyfill-randomuuid.mjs

# Operator opt-out for the /api browser-trust fence: DSH_TRUST_FENCE=0 lets
# the app work from any host without filling DSH_TRUSTED_HOSTS (RainYun's
# public address changes would otherwise require reconfiguration). Default
# (unset) keeps the fence intact.
COPY patch-trust-fence.mjs /usr/local/bin/
RUN node /usr/local/bin/patch-trust-fence.mjs

# Built-in password gate (default on via DSH_AUTH=1, see docker-entrypoint.sh):
# first visit registers a password, afterwards login is required. dsh itself
# binds only 127.0.0.1; the gate owns the public port.
COPY auth-proxy.js /usr/local/bin/
RUN chmod 755 /usr/local/bin/auth-proxy.js

# The agent's working directory; mount a volume here to give it a workspace.
WORKDIR /workspace

# The official node image ships a `node` user (uid 1000). We do NOT set USER:
# the entrypoint starts as root, self-heals persistent-volume ownership (K8s /
# RainYun volumes are root-owned and do not inherit image ownership), then
# drops privileges to uid 1000 before execing dsh — so the harness itself
# never runs as root, and Landlock confinement (which works unprivileged)
# keeps full enforcement.
RUN mkdir -p /data /workspace \
 && chown -R node:node /data /workspace

# All user data (settings, credentials, sessions, profiles) lives under
# $DSH_HOME — mount a volume at /data to persist across restarts.
VOLUME /data
EXPOSE 3080

HEALTHCHECK --interval=20s --timeout=5s --start-period=30s --retries=5 \
  CMD node -e "fetch('http://127.0.0.1:'+(process.env.PORT||3080)).then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

COPY docker-entrypoint.sh /usr/local/bin/dsh-entrypoint
RUN chmod 755 /usr/local/bin/dsh-entrypoint

# No USER on purpose: the entrypoint drops to uid 1000 itself (see above).
ENTRYPOINT ["dsh-entrypoint"]
