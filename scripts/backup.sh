#!/usr/bin/env bash
# Streams a compressed mongodump straight to S3 (nothing is written to local disk).
# Auth to S3 comes from the EC2 instance IAM role - no access keys on the server.
set -Eeuo pipefail
export PATH="/usr/local/bin:/usr/bin:/bin:${PATH}"
cd "$(dirname "$(readlink -f "$0")")/.."
set -a; . ./.env; set +a

: "${S3_BACKUP_BUCKET:?set S3_BACKUP_BUCKET in .env}"
REGION="${AWS_REGION:-ap-southeast-1}"
DB="${MONGO_DB:-expense_tracker}"
KEY="mongodb/${DB}/$(date -u +%Y-%m-%dT%H-%M-%SZ).archive.gz"

echo "[$(date -u +%FT%TZ)] Backing up '${DB}' -> s3://${S3_BACKUP_BUCKET}/${KEY}"

docker compose exec -T mongo sh -c 'exec mongodump --quiet \
    --username "$MONGO_INITDB_ROOT_USERNAME" --password "$MONGO_INITDB_ROOT_PASSWORD" \
    --authenticationDatabase admin --db "$MONGO_INITDB_DATABASE" --archive --gzip' \
  | aws s3 cp - "s3://${S3_BACKUP_BUCKET}/${KEY}" --region "${REGION}" --sse AES256

SIZE=$(aws s3api head-object --bucket "${S3_BACKUP_BUCKET}" --key "${KEY}" --region "${REGION}" \
        --query ContentLength --output text)
if [ "${SIZE}" -lt 100 ]; then
  echo "ERROR: backup object is suspiciously small (${SIZE} bytes)"; exit 1
fi
echo "[$(date -u +%FT%TZ)] OK - ${SIZE} bytes uploaded"
