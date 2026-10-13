#!/bin/bash
# Runs ONCE, only when the Mongo data volume is empty (first start).
# Creates a least-privilege user that can only read/write the app database.
set -e

mongosh --quiet \
  -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" \
  --authenticationDatabase admin "$MONGO_INITDB_DATABASE" <<JS
db.createUser({
  user: "$MONGO_APP_USER",
  pwd: "$MONGO_APP_PASSWORD",
  roles: [{ role: "readWrite", db: "$MONGO_INITDB_DATABASE" }]
});
JS
