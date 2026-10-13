#!/usr/bin/env bash
# Usage: ./scripts/restore.sh latest
#        ./scripts/restore.sh mongodb/expense_tracker/2026-10-14T20-00-01Z.archive.gz
set -Eeuo pipefail
export PATH="/usr/local/bin:/usr/bin:/bin:${PATH}"
cd "$(dirname "$(readlink -f "$0")")/.."
set -a; . ./.env; set +a

: "${S3_BACKUP_BUCKET:?set S3_BACKUP_BUCKET in .env}"
REGION="${AWS_REGION:-ap-southeast-1}"
DB="${MONGO_DB:-expense_tracker}"
KEY="${1:?usage: restore.sh <s3-key|latest>}"

if [ "$KEY" = "latest" ]; then
  KEY=$(aws s3api list-objects-v2 --bucket "${S3_BACKUP_BUCKET}" --prefix "mongodb/${DB}/" --region "${REGION}" \
          --query 'sort_by(Contents,&LastModified)[-1].Key' --output text)
fi

echo "About to restore s3://${S3_BACKUP_BUCKET}/${KEY} into '${DB}' (existing data will be DROPPED)."
read -r -p "Type 'yes' to continue: " ans
[ "$ans" = "yes" ] || { echo "aborted"; exit 1; }

aws s3 cp "s3://${S3_BACKUP_BUCKET}/${KEY}" - --region "${REGION}" \
  | docker compose exec -T mongo sh -c 'exec mongorestore --quiet \
      --username "$MONGO_INITDB_ROOT_USERNAME" --password "$MONGO_INITDB_ROOT_PASSWORD" \
      --authenticationDatabase admin --archive --gzip --drop'
echo "Restore finished."
