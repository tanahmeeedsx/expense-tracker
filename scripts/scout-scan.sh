#!/usr/bin/env bash
# Docker Scout vulnerability scan. Fails (exit 2) if fixable CRITICAL/HIGH CVEs are found
# in the app images, so deploy.sh stops before shipping a vulnerable build.
set -Eeuo pipefail
cd "$(dirname "$(readlink -f "$0")")/.."
[ -f .env ] && { set -a; . ./.env; set +a; }

TAG="${APP_TAG:-latest}"
FAIL_SEVERITY="${SCOUT_FAIL_SEVERITY:-critical,high}"   # e.g. SCOUT_FAIL_SEVERITY=critical
APP_IMAGES=("expense-tracker-backend:${TAG}" "expense-tracker-frontend:${TAG}")

docker scout version >/dev/null 2>&1 || {
  echo "docker scout is not installed - see DEPLOYMENT.md (section 4.3)"; exit 1; }

status=0
for img in "${APP_IMAGES[@]}"; do
  echo
  echo "==================== ${img} ===================="
  docker scout quickview "local://${img}" || true
  docker scout recommendations "local://${img}" || true
  docker scout cves --only-fixed --only-severity "${FAIL_SEVERITY}" --exit-code "local://${img}" || status=$?
done

echo
echo "==================== mongo:7.0 (info only, not a gate) ===================="
docker scout cves --only-severity critical,high mongo:7.0 || true

if [ "$status" -ne 0 ]; then
  echo; echo "Scout found fixable ${FAIL_SEVERITY} vulnerabilities in the app images. Fix them (rebuild with --pull / bump base image) and re-run."
fi
exit "$status"
