#!/bin/bash
set -euo pipefail

# Configuration (can be overridden via environment variables or config file)
CONFIG_FILE="${HOME}/.webdevwordpressrc"
STACK_NAME="${STACK_NAME:-webdevwordpress}"
CONTAINER_NAME="${STACK_NAME}-wp"
DB_CONTAINER_NAME="${STACK_NAME}-db"
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"
LOG_FILE="${LOG_FILE:-/tmp/webdevwordpress.log}"
DB_TIMEOUT_SECONDS="${DB_TIMEOUT_SECONDS:-60}"
MYSQL_USER="${MYSQL_USER:-root}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:-}"
MYSQL_HOST="${MYSQL_HOST:-localhost}"
MYSQL_PORT="${MYSQL_PORT:-3306}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging function
log() {
  local level="$1"
  local message="$2"
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[${timestamp}] ${level}: ${message}" | tee -a "$LOG_FILE"
}

# Load configuration from file if it exists
load_config() {
  if [[ -f "$CONFIG_FILE" ]]; then
    log "INFO" "Loading configuration from $CONFIG_FILE"
    source "$CONFIG_FILE"
  fi
}

# Check if Docker is running
check_docker() {
  if ! docker info >/dev/null 2>&1; then
    log "ERROR" "Docker is not running or not installed"
    exit 1
  fi
}

# Check if docker compose file exists
check_compose_file() {
  if [[ ! -f "$COMPOSE_FILE" ]]; then
    log "ERROR" "Docker Compose file $COMPOSE_FILE not found"
    exit 1
  fi
}

# Check if container exists
check_container_exists() {
  local container="$1"
  if docker ps -a --format '{{.Names}}' | grep -q "^${container}$"; then
    return 0
  else
    return 1
  fi
}

# Wait for database container to be ready
wait_for_db() {
  local start_time
  start_time=$(date +%s)
  log "INFO" "Waiting for database container $DB_CONTAINER_NAME to be ready..."
  while true; do
    if check_container_exists "$DB_CONTAINER_NAME"; then
      if docker exec "$DB_CONTAINER_NAME" mysqladmin ping -h"$MYSQL_HOST" -P"$MYSQL_PORT" -u"$MYSQL_USER" ${MYSQL_PASSWORD:+-p"$MYSQL_PASSWORD"} --silent >/dev/null 2>&1; then
        log "INFO" "Database container $DB_CONTAINER_NAME is ready"
        return 0
      fi
    fi
    local current_time
    current_time=$(date +%s)
    if (( current_time - start_time > DB_TIMEOUT_SECONDS )); then
      log "ERROR" "Timeout waiting for $DB_CONTAINER_NAME to be ready"
      exit 1
    fi
    log "INFO" "Database not ready, still waiting..."
    sleep 5
  done
}

main() {
  # Create log file directory if it doesn't exist
  mkdir -p "$(dirname "$LOG_FILE")"

  log "INFO" "Starting WordPress container management script"
  load_config
  check_docker
  check_compose_file

  # Clean up existing containers if they exist
  if check_container_exists "$CONTAINER_NAME"; then
    log "INFO" "Container $CONTAINER_NAME exists, running docker compose down -v"
    docker compose -f "$COMPOSE_FILE" down -v
  else
    log "INFO" "No existing container $CONTAINER_NAME, skipping docker compose down"
  fi

  # Build and start containers
  log "INFO" "Rebuilding and starting containers with $COMPOSE_FILE"
  if ! docker compose -f "$COMPOSE_FILE" up -d --build; then
    log "ERROR" "Failed to start containers"
    exit 1
  fi

  # Wait for database container to be ready
  wait_for_db

  # Stop and start WordPress container in interactive mode
  log "INFO" "Stopping $CONTAINER_NAME"
  if ! docker stop "$CONTAINER_NAME"; then
    log "ERROR" "Failed to stop $CONTAINER_NAME"
    exit 1
  fi

  log "INFO" "Starting $CONTAINER_NAME in interactive mode"
  if ! docker start -ai "$CONTAINER_NAME"; then
    log "ERROR" "Failed to start $CONTAINER_NAME in interactive mode"
    exit 1
  fi

  log "INFO" "Script completed successfully"
}

# Trap errors and log them
trap 'log "ERROR" "Script failed at line $LINENO: $BASH_COMMAND"; exit 1' ERR

# Run main function
main "$@"