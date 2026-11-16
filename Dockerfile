#
# Multi-stage Dockerfile for Pentest Agent
# Uses Chainguard Wolfi for minimal attack surface and supply chain security
#
# The base image and the apk closures in docker/apk-*.lock are pinned.
# Direct downloads (pnpm, Typst, Chrome for Testing) are checked before use.

# Builder stage - Install tools and dependencies
FROM cgr.dev/chainguard/wolfi-base@sha256:2c12da5496e21e99003b3db3b9246f025e53d533c4df334205391260f1e8f85b AS builder

COPY docker/apk-builder.lock /tmp/apk-builder.lock
COPY docker/verify-file.mjs /tmp/verify-file.mjs
RUN apk add --no-cache $(tr '\n' ' ' < /tmp/apk-builder.lock)

# pnpm's published tarball has no runtime dependencies, so this checksum covers the tool.
RUN curl -fsSL -o /tmp/pnpm.tgz https://registry.npmjs.org/pnpm/-/pnpm-10.33.0.tgz \
    && node /tmp/verify-file.mjs /tmp/pnpm.tgz sha512 EFaLtKavtYyes2MNqQzJUWQXq+vT+rvmc58K55VyjaFJHp21pUTHatjrdXD1xLs9bGN7LLQb/c20f6gjyGSTGQ== \
    && npm install -g --ignore-scripts /tmp/pnpm.tgz \
    && rm /tmp/pnpm.tgz

# Build Node.js application in builder to avoid QEMU emulation failures in CI
WORKDIR /app

# Copy workspace manifests for install layer caching
COPY package.json pnpm-workspace.yaml pnpm-lock.yaml .npmrc ./
COPY apps/worker/package.json ./apps/worker/
COPY apps/cli/package.json ./apps/cli/

RUN pnpm install --frozen-lockfile

COPY . .

# Build worker. CLI not needed in Docker
RUN pnpm --filter @shannon/worker run build

# Production-only deps (pnpm recommends install --prod over prune in monorepos)
RUN rm -rf node_modules apps/*/node_modules && pnpm install --frozen-lockfile --prod

# Runtime stage - Minimal production image
FROM cgr.dev/chainguard/wolfi-base@sha256:2c12da5496e21e99003b3db3b9246f025e53d533c4df334205391260f1e8f85b AS runtime

# Lifecycle protocol consumed by the CLI before it trusts a container workflow-id label.
LABEL shannon.worker-protocol="workflow-id-v1"

# Install only runtime dependencies
USER root
COPY docker/apk-runtime.lock /tmp/apk-runtime.lock
COPY docker/verify-file.mjs /tmp/verify-file.mjs
RUN apk add --no-cache $(tr '\n' ' ' < /tmp/apk-runtime.lock)

# Install Typst (report PDF compilation)
ARG TYPST_VERSION=0.14.2
RUN case "$(uname -m)" in \
      x86_64) TYPST_ARCH=x86_64-unknown-linux-musl; TYPST_SHA256=a6044cbad2a954deb921167e257e120ac0a16b20339ec01121194ff9d394996d ;; \
      aarch64) TYPST_ARCH=aarch64-unknown-linux-musl; TYPST_SHA256=491b101aa40a3a7ea82a3f8a6232cabb4e6a7e233810082e5ac812d43fdcd47a ;; \
      *) echo "unsupported arch $(uname -m)" && exit 1 ;; \
    esac && \
    mkdir -p /tmp/typst-dl /usr/local/bin && cd /tmp/typst-dl && \
    curl -fsSL "https://github.com/typst/typst/releases/download/v${TYPST_VERSION}/typst-${TYPST_ARCH}.tar.xz" -o typst.tar.xz && \
    node /tmp/verify-file.mjs typst.tar.xz sha256 "${TYPST_SHA256}" && \
    xz -d typst.tar.xz && \
    tar -xf typst.tar && \
    mv "typst-${TYPST_ARCH}/typst" /usr/local/bin/typst && \
    chmod +x /usr/local/bin/typst && \
    cd / && rm -rf /tmp/typst-dl && \
    typst --version

# Create non-root user
RUN addgroup -g 1001 pentest && \
    adduser -u 1001 -G pentest -s /bin/bash -D pentest

# System-level git config (survives UID remapping in entrypoint)
RUN git config --system user.email "agent@localhost" && \
    git config --system user.name "Pentest Agent" && \
    git config --system --add safe.directory '*'

# Set working directory
WORKDIR /app

# Copy only what the worker needs (skip CLI source, infra, tsdown artifacts)
COPY --from=builder /app/package.json /app/pnpm-workspace.yaml /app/pnpm-lock.yaml /app/.npmrc /app/
COPY --from=builder /app/node_modules /app/node_modules
COPY --from=builder /app/apps/worker /app/apps/worker
COPY --from=builder /app/apps/cli/package.json /app/apps/cli/package.json

# Third-party license and notice material travels with the distributed image
COPY LICENSE THIRD_PARTY_NOTICES.md /usr/share/licenses/shannon/
COPY LICENSES/ /usr/share/licenses/shannon/LICENSES/

# @playwright/cli and its dependency tree, verified by the lockfile integrities.
COPY docker/playwright-cli/package.json docker/playwright-cli/package-lock.json /opt/shannon-playwright/
RUN cd /opt/shannon-playwright \
    && npm ci --ignore-scripts \
    && ln -sf /opt/shannon-playwright/node_modules/.bin/playwright-cli /usr/local/bin/playwright-cli

# Chrome for Testing 146.0.7680.0 (playwright-core chromium revision 1212).
# Placed where playwright looks before `playwright-cli install --skills`, so that
# command copies skills and does not download a browser.
RUN case "$(uname -m)" in \
      x86_64) \
        CHROME_URL=https://cdn.playwright.dev/builds/cft/146.0.7680.0/linux64/chrome-linux64.zip; \
        CHROME_SHA256=6b3550372c9d912dd016d3333a8821e903f97277fb1fab503c9fa6ad426dd2a7; \
        CHROME_BIN=chrome-linux64/chrome ;; \
      aarch64) \
        CHROME_URL=https://cdn.playwright.dev/dbazure/download/playwright/builds/chromium/1212/chromium-linux-arm64.zip; \
        CHROME_SHA256=da0e6af6376948fa868d2fc01cf1ebb68b8ac7f083590a676a07d7d93c87debb; \
        CHROME_BIN=chrome-linux/chrome ;; \
      *) echo "unsupported arch $(uname -m)" && exit 1 ;; \
    esac && \
    mkdir -p /root/.cache/ms-playwright/chromium-1212 /tmp/chrome-dl && \
    curl -fsSL "${CHROME_URL}" -o /tmp/chrome-dl/chrome.zip && \
    node /tmp/verify-file.mjs /tmp/chrome-dl/chrome.zip sha256 "${CHROME_SHA256}" && \
    python3 -c 'import zipfile; zipfile.ZipFile("/tmp/chrome-dl/chrome.zip").extractall("/root/.cache/ms-playwright/chromium-1212")' && \
    chmod +x "/root/.cache/ms-playwright/chromium-1212/${CHROME_BIN}" && \
    : > /root/.cache/ms-playwright/chromium-1212/INSTALLATION_COMPLETE && \
    rm -rf /tmp/chrome-dl

RUN mkdir -p /tmp/.claude/skills && \
    playwright-cli install --skills && \
    cp -r .claude/skills/playwright-cli /tmp/.claude/skills/ && \
    rm -rf .claude

# Symlink CLI tools onto PATH
RUN ln -s /app/apps/worker/dist/scripts/save-deliverable.js /usr/local/bin/save-deliverable && \
    chmod +x /app/apps/worker/dist/scripts/save-deliverable.js && \
    ln -s /app/apps/worker/dist/scripts/generate-totp.js /usr/local/bin/generate-totp && \
    chmod +x /app/apps/worker/dist/scripts/generate-totp.js && \
    ln -s /app/apps/worker/dist/scripts/set-report-meta.js /usr/local/bin/set-report-meta && \
    chmod +x /app/apps/worker/dist/scripts/set-report-meta.js

# Create directories for session data and ensure proper permissions
RUN mkdir -p /app/sessions /app/repos /app/workspaces && \
    mkdir -p /tmp/.cache /tmp/.config /tmp/.npm /tmp/.pi/agent && \
    chmod 777 /app && \
    chmod 777 /tmp/.cache && \
    chmod 777 /tmp/.config && \
    chmod 777 /tmp/.npm && \
    chown -R pentest:pentest /app /tmp/.claude /tmp/.pi

COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

# Set environment variables
ENV NODE_ENV=production
ENV PATH="/usr/local/bin:$PATH"
ENV SHANNON_DOCKER=true
ENV PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
ENV PLAYWRIGHT_MCP_EXECUTABLE_PATH=/usr/bin/chromium-browser
ENV npm_config_cache=/tmp/.npm
ENV HOME=/tmp
ENV XDG_CACHE_HOME=/tmp/.cache
ENV XDG_CONFIG_HOME=/tmp/.config

ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["node", "apps/worker/dist/temporal/worker.js"]
