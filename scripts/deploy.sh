#!/usr/bin/env bash
# One-command deploy / update on the EC2 instance.
set -Eeuo pipefail
cd "$(dirname "$(readlink -f "$0")")/.."

[ -f .env ] || { echo ".env missing - run: cp .env.example .env and fill it in"; exit 1; }

git pull --ff-only || echo "(git pull skipped)"
docker compose build --pull
./scripts/scout-scan.sh          # stops here if the scan fails
docker compose up -d
docker image prune -f
docker compose ps
