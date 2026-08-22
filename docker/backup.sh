#!/bin/sh
# Nightly backup for WTF-OpenCats.
#   - mysqldump of the whole database
#   - tar of candidate attachments + the live config
#   - both pushed to S3, local copies pruned after 7 days
# Installed at /srv/cats/backup.sh, run from root's crontab at 20:30 UTC (02:00 IST).
set -eu

BUCKET="wtf-opencats-attachments-246814138703"
REGION="ap-south-1"
COMPOSE="/opt/opencats/docker/docker-compose.prod.yml"
CONFIG="/srv/cats/config/config.php"
OUT="/srv/cats/backups"
STAMP="$(date -u +%Y%m%d-%H%M%S)"

mkdir -p "$OUT"

DBU="$(grep -oP "DATABASE_USER'\s*,\s*'\K[^']+" "$CONFIG")"
DBP="$(grep -oP "DATABASE_PASS'\s*,\s*'\K[^']+" "$CONFIG")"
DBN="$(grep -oP "DATABASE_NAME'\s*,\s*'\K[^']+" "$CONFIG")"

# --- database ---
DUMP="$OUT/db-$STAMP.sql.gz"
docker compose -f "$COMPOSE" exec -T mariadb \
    mariadb-dump -u"$DBU" -p"$DBP" --single-transaction --quick --routines "$DBN" \
    | gzip -9 > "$DUMP"

# A dump that does not contain a CREATE TABLE is a failed dump, not a small one.
if ! gzip -cd "$DUMP" | head -c 200000 | grep -q "CREATE TABLE"; then
    echo "FATAL: dump has no CREATE TABLE, refusing to upload" >&2
    rm -f "$DUMP"
    exit 1
fi

# --- attachments + config ---
FILES="$OUT/files-$STAMP.tar.gz"
tar -czf "$FILES" -C /srv/cats attachments config

# --- ship ---
aws s3 cp "$DUMP"  "s3://$BUCKET/backups/db/"    --region "$REGION" --only-show-errors
aws s3 cp "$FILES" "s3://$BUCKET/backups/files/" --region "$REGION" --only-show-errors

# --- prune local ---
find "$OUT" -name '*.gz' -mtime +7 -delete

echo "OK $STAMP db=$(du -h "$DUMP" | cut -f1) files=$(du -h "$FILES" | cut -f1)"
