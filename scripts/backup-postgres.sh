
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

NAMESPACE="devops-helm"
POD="demo-app-postgres-0"
DB_USER="devops"
DB_NAME="demoapp"
BACKUP_DIR="/var/backups/cloudforge/postgres"

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

TIMESTAMP=$(date -u +"%Y%m%dT%H%M%SZ")
BACKUP_FILE="$BACKUP_DIR/demoapp-${TIMESTAMP}.dump"
TEMP_FILE="${BACKUP_FILE}.partial"

trap 'rm -f "$TEMP_FILE"' EXIT

echo "Starting PostgreSQL backup..."

/usr/local/bin/k3s kubectl exec -n "$NAMESPACE" "$POD" -- \
  pg_dump -U "$DB_USER" -d "$DB_NAME" \
  --format=custom --no-owner \
  > "$TEMP_FILE"

test -s "$TEMP_FILE"

# Check that the custom-format archive can be read.
pg_restore --list "$TEMP_FILE" > /dev/null

mv "$TEMP_FILE" "$BACKUP_FILE"

# Export backup for Windows SCP retrieval
EXPORT_DIR="/var/backups/cloudforge-export"

install -d \
  -o root \
  -g cloudforge-backup \
  -m 2750 \
  "$EXPORT_DIR"

install \
  -o root \
  -g cloudforge-backup \
  -m 640 \
  "$BACKUP_FILE" \
  "$EXPORT_DIR/$(basename "$BACKUP_FILE")"

echo "Backup exported: $EXPORT_DIR/$(basename "$BACKUP_FILE")"

trap - EXIT

echo "Backup created: $BACKUP_FILE"
echo "Size: $(du -h "$BACKUP_FILE" | cut -f1)"

# Retain backups for 7 days
RETENTION_DAYS=7

echo "Removing backups older than ${RETENTION_DAYS} days..."

find "$BACKUP_DIR" \
  -maxdepth 1 \
  -type f \
  -name 'demoapp-*.dump' \
  -mtime +6 \
  -print \
  -delete

echo "Backup retention completed."
