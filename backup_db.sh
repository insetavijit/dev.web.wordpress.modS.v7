#!/bin/bash
set -e

# Load environment variables from .env
if [ -f .env ]; then
    export $(grep -v '^#' .env | xargs)
fi

# Backup folder and table
mkdir -p "$BACKUP_DIR"

# Unique backup file using timestamp
TIMESTAMP=$(date +%F-%H%M%S)
BACKUP_FILE="$BACKUP_DIR/db-backup-$TIMESTAMP.sql"

# Check table row count
ROW_COUNT=$(docker exec webdevwordpress-wpcli wp db query "SELECT COUNT(*) FROM $TABLE_TO_CHECK;" --skip-column-names --allow-root 2>/dev/null || echo 0)

if [ "$ROW_COUNT" -eq 0 ]; then
    echo "Database is empty. Attempting to restore from latest backup..."

    # Find the latest backup in BACKUP_DIR
    LATEST_BACKUP=$(ls -t $BACKUP_DIR/*.sql 2>/dev/null | head -n 1)

    if [ -f "$LATEST_BACKUP" ]; then
        docker cp "$LATEST_BACKUP" webdevwordpress-wpcli:/var/www/html/wpcli-cache/db-backup.sql
        docker exec -it webdevwordpress-wpcli wp db import /var/www/html/wpcli-cache/db-backup.sql --allow-root
        echo "Database restored successfully from backup: $LATEST_BACKUP"
    else
        echo "No backup found. Starting with empty database."
    fi
else
    echo "Database has data. Exporting current state to unique backup..."
    docker exec webdevwordpress-wpcli wp db export /var/www/html/wpcli-cache/db-backup.sql --allow-root
    docker cp webdevwordpress-wpcli:/var/www/html/wpcli-cache/db-backup.sql "$BACKUP_FILE"
    echo "Backup created: $BACKUP_FILE"
fi
