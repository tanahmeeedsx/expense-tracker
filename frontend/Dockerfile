# syntax=docker/dockerfile:1
ARG NODE_VERSION=24

# ---------- Stage 1: install dependencies ----------
FROM node:${NODE_VERSION}-alpine AS deps
WORKDIR /app
COPY package*.json ./
RUN if [ -f package-lock.json ]; then npm ci; else npm install; fi

# ---------- Stage 2: build the Vite/React app ----------
FROM deps AS build
COPY index.html ./index.html
COPY src ./src
RUN npm run build

# ---------- Stage 3: serve with NGINX (non-root, port 8080) ----------
FROM nginxinc/nginx-unprivileged:stable-alpine AS runtime

COPY --from=build --chown=nginx:nginx /app/dist /usr/share/nginx/html
COPY nginx/default.conf /etc/nginx/conf.d/default.conf

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD wget -q --spider http://127.0.0.1:8080/healthz || exit 1
