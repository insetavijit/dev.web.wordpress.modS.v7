#!/bin/bash

# Industry-grade WordPress installation script with enhanced permission handling
# Purpose: Automates secure WordPress setup with robust error handling and logging
# Version: 2.1.0
# Requirements: wp-cli, bash 4.0+, apache2

set -euo pipefail
IFS=$'\n\t'

# Configuration
declare -r LOG_FILE="/var/log/wordpress_install.log"
declare -r BACKUP_DIR="/var/backups/wordpress"
declare -r WP_PATH="${WP_PATH:-/var/www/html}"
declare -r MAX_DB_RETRIES=5
declare -r RETRY_DELAY=5
declare -r WEB_USER="${WEB_USER:-www-data}" # Allow customization of web user
declare -r WEB_GROUP="${WEB_GROUP:-www-data}" # Allow customization of web group

# Default values for optional variables
: "${WORDPRESS_DB_HOST:=localhost}"
: "${WORDPRESS_DB_PORT:=3306}"
: "${WORDPRESS_DB_PREFIX:=wp_}"
: "${WORDPRESS_URL:=http://localhost:8080}"
: "${WORDPRESS_TITLE:=My Dev Site}"
: "${WORDPRESS_ADMIN_USER:=admin}"
: "${WORDPRESS_ADMIN_PASSWORD:=adminpass}"
: "${WORDPRESS_ADMIN_EMAIL:=admin@example.com}"

# Set secure umask for file creation
umask 027

# Logging function
log() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

# Error handling function
error_exit() {
    log "ERROR" "$1"
    exit 1
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error_exit "This script must be run as root for permission handling"
    fi
}

# Validate required environment variables
validate_env() {
    local required_vars=(
        "WORDPRESS_DB_NAME"
        "WORDPRESS_DB_USER"
        "WORDPRESS_DB_PASSWORD"
    )
    
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var}" ]]; then
            error_exit "Missing required environment variable: $var"
        fi
    done
    
    # Validate email format
    if ! [[ $WORDPRESS_ADMIN_EMAIL =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        error_exit "Invalid admin email format: $WORDPRESS_ADMIN_EMAIL"
    fi
}

# Backup existing WordPress installation
backup_existing() {
    if [[ -d "$WP_PATH" && -n "$(ls -A "$WP_PATH")" ]]; then
        local backup_timestamp
        backup_timestamp=$(date '+%Y%m%d_%H%M%S')
        local backup_path="$BACKUP_DIR/wordpress_backup_${backup_timestamp}"
        
        log "INFO" "Creating backup of existing WordPress installation to $backup_path"
        mkdir -p "$BACKUP_DIR" || error_exit "Failed to create backup directory"
        chmod 700 "$BACKUP_DIR" || error_exit "Failed to set backup directory permissions"
        chown "$WEB_USER:$WEB_GROUP" "$BACKUP_DIR" || error_exit "Failed to set backup directory ownership"
        
        if ! tar -czf "${backup_path}.tar.gz" -C "$WP_PATH" . 2>/dev/null; then
            error_exit "Failed to create backup of existing WordPress installation"
        fi
        chmod 600 "${backup_path}.tar.gz" || error_exit "Failed to set backup file permissions"
        log "INFO" "Backup completed successfully"
    fi
}

# Check if command exists
check_command() {
    if ! command -v "$1" &>/dev/null; then
        error_exit "Required command $1 not found"
    fi
}

# Wait for database with retry logic (unchanged)
wait_for_database() {
    local attempt=1
    log "INFO" "Checking database availability on ${WORDPRESS_DB_HOST}:${WORDPRESS_DB_PORT}"
    
    while [[ $attempt -le $MAX_DB_RETRIES ]]; do
        if bash -c "</dev/tcp/${WORDPRESS_DB_HOST}/${WORDPRESS_DB_PORT}" >/dev/null 2>&1; then
            log "INFO" "Database connection established"
            return 0
        fi
        log "WARNING" "Database connection attempt $attempt/$MAX_DB_RETRIES failed"
        sleep "$RETRY_DELAY"
        ((attempt++))
    done
    error_exit "Failed to connect to database after $MAX_DB_RETRIES attempts"
}

# Check SELinux/AppArmor status
check_security_context() {
    if command -v sestatus &>/dev/null && sestatus | grep -q "enabled"; then
        log "INFO" "SELinux detected, ensuring correct context for $WP_PATH"
        chcon -R -t httpd_sys_content_t "$WP_PATH" 2>/dev/null || log "WARNING" "Failed to set SELinux context"
    elif command -v aa-status &>/dev/null && aa-status | grep -q "profiles are in enforce mode"; then
        log "INFO" "AppArmor detected, checking profile compatibility"
        # Add AppArmor profile check if needed
    fi
}

# Validate web user and group
validate_web_user_group() {
    if ! id "$WEB_USER" &>/dev/null; then
        error_exit "Web user $WEB_USER does not exist"
    fi
    if ! getent group "$WEB_GROUP" &>/dev/null; then
        error_exit "Web group $WEB_GROUP does not exist"
    fi
}

# Set WordPress permissions for file modification
set_wordpress_permissions() {
    log "INFO" "Setting WordPress permissions for file modification"
    
    # Define directories that need write access
    local writable_dirs=(
        "$WP_PATH/wp-content/uploads"
        "$WP_PATH/wp-content/plugins"
        "$WP_PATH/wp-content/themes"
        "$WP_PATH/wp-content/cache"
    )
    
    # Set ownership for WordPress directory
    chown -R "$WEB_USER:$WEB_GROUP" "$WP_PATH" || error_exit "Failed to set ownership for $WP_PATH"
    
    # Set base permissions for directories and files
    find "$WP_PATH" -type d -exec chmod 755 {} \; || error_exit "Failed to set directory permissions for $WP_PATH"
    find "$WP_PATH" -type f -exec chmod 644 {} \; || error_exit "Failed to set file permissions for $WP_PATH"
    
    # Set write permissions for specific directories
    for dir in "${writable_dirs[@]}"; do
        if [[ -d "$dir" || -L "$dir" ]]; then
            log "INFO" "Setting write permissions for $dir"
            chmod -R 775 "$dir" || error_exit "Failed to set write permissions for $dir"
            chown -R "$WEB_USER:$WEB_GROUP" "$dir" || error_exit "Failed to set ownership for $dir"
        else
            log "INFO" "Creating writable directory $dir"
            mkdir -p "$dir" || error_exit "Failed to create directory $dir"
            chmod 775 "$dir" || error_exit "Failed to set write permissions for $dir"
            chown "$WEB_USER:$WEB_GROUP" "$dir" || error_exit "Failed to set ownership for $dir"
        fi
    done
    
    # Set stricter permissions for wp-config.php
    if [[ -f "$WP_PATH/wp-config.php" ]]; then
        log "INFO" "Setting strict permissions for wp-config.php"
        chmod 640 "$WP_PATH/wp-config.php" || error_exit "Failed to set permissions for wp-config.php"
        chown "$WEB_USER:$WEB_GROUP" "$WP_PATH/wp-config.php" || error_exit "Failed to set ownership for wp-config.php"
    fi
    
    # Apply SELinux context if applicable
    if command -v sestatus &>/dev/null && sestatus | grep -q "enabled"; then
        log "INFO" "Applying SELinux context for writable directories"
        for dir in "${writable_dirs[@]}"; do
            if [[ -d "$dir" || -L "$dir" ]]; then
                chcon -R -t httpd_sys_rw_content_t "$dir" 2>/dev/null || log "WARNING" "Failed to set SELinux context for $dir"
            fi
        done
        if [[ -f "$WP_PATH/wp-config.php" ]]; then
            chcon -t httpd_sys_content_t "$WP_PATH/wp-config.php" 2>/dev/null || log "WARNING" "Failed to set SELinux context for wp-config.php"
        fi
    fi
}

# Main installation function
install_wordpress() {
    log "INFO" "Starting WordPress installation process"
    
    # Create WordPress directory
    log "INFO" "Preparing WordPress directory at $WP_PATH"
    mkdir -p "$WP_PATH" || error_exit "Failed to create WordPress directory"
    chown "$WEB_USER:$WEB_GROUP" "$WP_PATH" || error_exit "Failed to set WordPress directory ownership"
    chmod 755 "$WP_PATH" || error_exit "Failed to set WordPress directory permissions"
    
    # Clean existing content
    log "INFO" "Cleaning WordPress directory"
    rm -rf "$WP_PATH"/* || error_exit "Failed to clean WordPress directory"
    
    # Download WordPress
    log "INFO" "Downloading WordPress"
    wp core download --path="$WP_PATH" --allow-root || error_exit "Failed to download WordPress"
    
    # Create wp-config.php
    log "INFO" "Creating wp-config.php"
    wp config create \
        --dbname="${WORDPRESS_DB_NAME}" \
        --dbuser="${WORDPRESS_DB_USER}" \
        --dbpass="${WORDPRESS_DB_PASSWORD}" \
        --dbhost="${WORDPRESS_DB_HOST}" \
        --dbprefix="${WORDPRESS_DB_PREFIX}" \
        --allow-root || error_exit "Failed to create wp-config.php"
    
    # Install WordPress
    log "INFO" "Installing WordPress core"
    wp core install \
        --url="${WORDPRESS_URL}" \
        --title="${WORDPRESS_TITLE}" \
        --admin_user="${WORDPRESS_ADMIN_USER}" \
        --admin_password="${WORDPRESS_ADMIN_PASSWORD}" \
        --admin_email="${WORDPRESS_ADMIN_EMAIL}" \
        --skip-email \
        --allow-root || error_exit "Failed to install WordPress"
    
    # Configure WordPress settings
    log "INFO" "Configuring WordPress settings"
    wp config set WP_DEBUG true --raw --allow-root || error_exit "Failed to set WP_DEBUG"
    wp config set FS_METHOD direct --allow-root || error_exit "Failed to set FS_METHOD"
    wp config set FS_CHMOD_DIR 0755 --raw --allow-root || error_exit "Failed to set FS_CHMOD_DIR"
    wp config set FS_CHMOD_FILE 0644 --raw --allow-root || error_exit "Failed to set FS_CHMOD_FILE"
    
    # Additional security settings
    log "INFO" "Applying security configurations"
    wp config set DISALLOW_FILE_EDIT true --raw --allow-root || error_exit "Failed to set DISALLOW_FILE_EDIT"
    wp config set WP_AUTO_UPDATE_CORE false --raw --allow-root || error_exit "Failed to set WP_AUTO_UPDATE_CORE"
    
    # Set WordPress permissions
    set_wordpress_permissions
}

# Function to link development theme
link_dev_theme() {
    local source_theme="/shared/themes/modS.theme.template.code"
    local target_theme="$WP_PATH/wp-content/themes/modS.theme.template"

    if [[ -d "$source_theme" ]]; then
        mkdir -p "$(dirname "$target_theme")" || error_exit "Failed to create theme directory"
        chown "$WEB_USER:$WEB_GROUP" "$(dirname "$target_theme")" || error_exit "Failed to set theme directory ownership"
        chmod 775 "$(dirname "$target_theme")" || error_exit "Failed to set theme directory permissions"
        ln -sfn "$source_theme" "$target_theme" || error_exit "Failed to create theme symlink"
        log "INFO" "Theme symlink created: $target_theme -> $source_theme"
    else
        log "WARNING" "Source theme $source_theme not found. Skipping symlink."
    fi
}

# Main execution
main() {
    # Check if running as root
    check_root
    
    # Initialize logging
    mkdir -p "$(dirname "$LOG_FILE")" || error_exit "Failed to create log directory"
    chmod 750 "$(dirname "$LOG_FILE")" || error_exit "Failed to set log directory permissions"
    touch "$LOG_FILE" || error_exit "Failed to create log file"
    chmod 640 "$LOG_FILE" || error_exit "Failed to set log file permissions"
    chown "$WEB_USER:$WEB_GROUP" "$LOG_FILE" || error_exit "Failed to set log file ownership"
    
    log "INFO" "Starting WordPress installation script"
    
    # Check prerequisites
    check_command "wp"
    check_command "apache2-foreground"
    
    # Validate web user and group
    validate_web_user_group
    
    # Check security context
    check_security_context
    
    # Validate environment
    validate_env
    
    # Create backup
    backup_existing
    
    # Wait for database
    wait_for_database
    
    # Install WordPress
    install_wordpress
    
    log "INFO" "WordPress installation completed successfully"
    
    # Link development themes
    link_dev_theme
    
    # Start Apache
    log "INFO" "Starting Apache web server"
    exec apache2-foreground
}

# Execute main function
main "$@"