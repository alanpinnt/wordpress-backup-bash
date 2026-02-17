#!/usr/bin/env bash
#
# wp-backup.sh - Automated WordPress backup script
# Dumps the database and compresses wp-content with backup rotation.
#
# Usage: ./wp-backup.sh [options]
#   -c, --config FILE    Path to config file (default: .env in script dir)
#   -n, --dry-run        Show what would be done without making changes
#   -v, --verbose        Enable verbose output
#   -h, --help           Show this help message

set -euo pipefail

# ---------- Defaults ----------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
CONFIG_FILE="${SCRIPT_DIR}/.env"
DRY_RUN=false
VERBOSE=false

# Configurable via .env or environment
WP_PATH="${WP_PATH:-/var/www/html}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/wordpress}"
RETAIN_COUNT="${RETAIN_COUNT:-7}"
DB_HOST="${DB_HOST:-}"
DB_NAME="${DB_NAME:-}"
DB_USER="${DB_USER:-}"
DB_PASS="${DB_PASS:-}"

# ---------- Functions ----------

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

verbose() {
    if [[ "$VERBOSE" == true ]]; then
        log "[VERBOSE] $*"
    fi
}

error() {
    log "[ERROR] $*" >&2
}

die() {
    error "$*"
    exit 1
}

usage() {
    sed -n '5,9p' "$0" | sed 's/^# \?//'
    exit 0
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -c|--config) CONFIG_FILE="$2"; shift 2 ;;
            -n|--dry-run) DRY_RUN=true; shift ;;
            -v|--verbose) VERBOSE=true; shift ;;
            -h|--help) usage ;;
            *) die "Unknown option: $1" ;;
        esac
    done
}

load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        verbose "Loading config from $CONFIG_FILE"
        # Source only expected variables, skip comments and blank lines
        while IFS='=' read -r key value; do
            key="$(echo "$key" | xargs)"
            [[ -z "$key" || "$key" == \#* ]] && continue
            value="$(echo "$value" | xargs | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")"
            case "$key" in
                WP_PATH|BACKUP_DIR|RETAIN_COUNT|DB_HOST|DB_NAME|DB_USER|DB_PASS)
                    # Only set if not already overridden by environment
                    if [[ -z "${!key:-}" || "${!key}" == "" ]]; then
                        export "$key=$value"
                    else
                        verbose "$key already set via environment, skipping config value"
                    fi
                    ;;
            esac
        done < "$CONFIG_FILE"
    else
        verbose "No config file found at $CONFIG_FILE, using defaults/environment"
    fi
}

detect_db_credentials() {
    local wp_config="${WP_PATH}/wp-config.php"

    if [[ -n "$DB_NAME" && -n "$DB_USER" ]]; then
        verbose "Database credentials provided via config/environment"
        return
    fi

    if [[ -f "$wp_config" ]]; then
        verbose "Reading database credentials from $wp_config"
        DB_NAME="${DB_NAME:-$(grep -oP "define\(\s*'DB_NAME'\s*,\s*'\\K[^']+" "$wp_config" 2>/dev/null || true)}"
        DB_USER="${DB_USER:-$(grep -oP "define\(\s*'DB_USER'\s*,\s*'\\K[^']+" "$wp_config" 2>/dev/null || true)}"
        DB_PASS="${DB_PASS:-$(grep -oP "define\(\s*'DB_PASSWORD'\s*,\s*'\\K[^']+" "$wp_config" 2>/dev/null || true)}"
        DB_HOST="${DB_HOST:-$(grep -oP "define\(\s*'DB_HOST'\s*,\s*'\\K[^']+" "$wp_config" 2>/dev/null || true)}"
    fi

    [[ -z "$DB_NAME" ]] && die "DB_NAME not set and could not be read from wp-config.php"
    [[ -z "$DB_USER" ]] && die "DB_USER not set and could not be read from wp-config.php"
}

check_dependencies() {
    local missing=()
    for cmd in mysqldump tar gzip; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        die "Missing required commands: ${missing[*]}"
    fi
}

validate_paths() {
    [[ -d "$WP_PATH" ]] || die "WordPress path not found: $WP_PATH"
    [[ -d "${WP_PATH}/wp-content" ]] || die "wp-content directory not found in $WP_PATH"

    if [[ "$DRY_RUN" == false ]]; then
        mkdir -p "$BACKUP_DIR" || die "Cannot create backup directory: $BACKUP_DIR"
    fi
}

backup_database() {
    local dump_file="${BACKUP_DIR}/db_${TIMESTAMP}.sql.gz"
    log "Backing up database: $DB_NAME"

    if [[ "$DRY_RUN" == true ]]; then
        log "[DRY RUN] Would dump database to $dump_file"
        return
    fi

    local mysql_args=(-h "${DB_HOST:-localhost}" -u "$DB_USER")
    if [[ -n "$DB_PASS" ]]; then
        mysql_args+=(-p"$DB_PASS")
    fi

    mysqldump "${mysql_args[@]}" \
        --single-transaction \
        --routines \
        --triggers \
        --add-drop-table \
        "$DB_NAME" | gzip > "$dump_file"

    local size
    size="$(du -h "$dump_file" | cut -f1)"
    log "Database backup complete: $dump_file ($size)"
}

backup_files() {
    local archive="${BACKUP_DIR}/wp-content_${TIMESTAMP}.tar.gz"
    log "Backing up wp-content directory"

    if [[ "$DRY_RUN" == true ]]; then
        log "[DRY RUN] Would create archive: $archive"
        return
    fi

    tar -czf "$archive" -C "$WP_PATH" wp-content

    local size
    size="$(du -h "$archive" | cut -f1)"
    log "File backup complete: $archive ($size)"
}

rotate_backups() {
    log "Rotating backups (keeping last $RETAIN_COUNT)"

    if [[ "$DRY_RUN" == true ]]; then
        local count
        count="$(find "$BACKUP_DIR" -maxdepth 1 -name 'db_*.sql.gz' | wc -l)"
        log "[DRY RUN] Found $count database backups, would remove oldest if > $RETAIN_COUNT"
        count="$(find "$BACKUP_DIR" -maxdepth 1 -name 'wp-content_*.tar.gz' | wc -l)"
        log "[DRY RUN] Found $count file backups, would remove oldest if > $RETAIN_COUNT"
        return
    fi

    # Rotate database backups
    local db_backups
    db_backups="$(find "$BACKUP_DIR" -maxdepth 1 -name 'db_*.sql.gz' -printf '%T@ %p\n' | sort -rn | tail -n +$((RETAIN_COUNT + 1)) | cut -d' ' -f2-)"
    if [[ -n "$db_backups" ]]; then
        echo "$db_backups" | while read -r file; do
            verbose "Removing old database backup: $file"
            rm -f "$file"
        done
    fi

    # Rotate file backups
    local file_backups
    file_backups="$(find "$BACKUP_DIR" -maxdepth 1 -name 'wp-content_*.tar.gz' -printf '%T@ %p\n' | sort -rn | tail -n +$((RETAIN_COUNT + 1)) | cut -d' ' -f2-)"
    if [[ -n "$file_backups" ]]; then
        echo "$file_backups" | while read -r file; do
            verbose "Removing old file backup: $file"
            rm -f "$file"
        done
    fi

    local remaining
    remaining="$(find "$BACKUP_DIR" -maxdepth 1 \( -name 'db_*.sql.gz' -o -name 'wp-content_*.tar.gz' \) | wc -l)"
    log "Rotation complete. $((remaining / 2)) backup sets remaining."
}

# ---------- Main ----------

main() {
    parse_args "$@"
    load_config
    check_dependencies
    detect_db_credentials
    validate_paths

    log "Starting WordPress backup"
    verbose "WordPress path: $WP_PATH"
    verbose "Backup directory: $BACKUP_DIR"
    verbose "Retain count: $RETAIN_COUNT"

    backup_database
    backup_files
    rotate_backups

    log "Backup complete!"
}

main "$@"
