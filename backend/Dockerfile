# syntax=docker/dockerfile:1
ARG NODE_VERSION=24

# ---------- Stage 1: install production dependencies only ----------
FROM node:${NODE_VERSION}-alpine AS deps
WORKDIR /app
COPY package*.json ./
# Uses the lockfile when present (reproducible); falls back to npm install otherwise
RUN if [ -f package-lock.json ]; then npm ci --omit=dev; else npm install --omit=dev; fi \
 && npm cache clean --force

# ---------- Stage 2: minimal runtime image ----------
FROM node:${NODE_VERSION}-alpine AS runtime
ENV NODE_ENV=production
WORKDIR /app

# Pull in the latest Alpine security patches (helps Docker Scout results)
RUN apk upgrade --no-cache

COPY --from=deps --chown=node:node /app/node_modules ./node_modules
COPY --chown=node:node package.json ./
COPY --chown=node:node src ./src

# Never run as root
USER node

EXPOSE 5000

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD wget -q --spider http://127.0.0.1:5000/api/health || exit 1

CMD ["node", "src/server.js"]
