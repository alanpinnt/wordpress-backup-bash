# wp-backup

A simple bash script for automated WordPress backups. Dumps the MySQL database and compresses the `wp-content` directory, with automatic rotation to keep your backup directory from growing indefinitely.

## Features

- **Database backup** - Uses `mysqldump` with `--single-transaction` for consistent dumps without locking tables
- **File backup** - Compresses the entire `wp-content` directory (uploads, themes, plugins)
- **Auto-rotation** - Keeps the last N backup sets and removes older ones
- **Auto-detection** - Reads database credentials directly from `wp-config.php` if not provided
- **Dry run mode** - Preview what the script will do without making changes
- **Configurable** - Settings via `.env` file, environment variables, or command-line flags

## Requirements

- `bash` 4.0+
- `mysqldump`
- `tar` and `gzip`
- Read access to the WordPress installation directory
- MySQL user with `SELECT` and `LOCK TABLES` privileges

## Quick Start

```bash
git clone https://github.com/yourusername/wp-backup.git
cd wp-backup
cp .env.example .env
# Edit .env with your WordPress path and backup directory
chmod +x wp-backup.sh
./wp-backup.sh
```

## Configuration

Copy `.env.example` to `.env` and adjust the values:

| Variable | Default | Description |
|---|---|---|
| `WP_PATH` | `/var/www/html` | Path to the WordPress installation |
| `BACKUP_DIR` | `/var/backups/wordpress` | Where backups are stored |
| `RETAIN_COUNT` | `7` | Number of backup sets to keep |
| `DB_HOST` | *(from wp-config.php)* | Database host |
| `DB_NAME` | *(from wp-config.php)* | Database name |
| `DB_USER` | *(from wp-config.php)* | Database user |
| `DB_PASS` | *(from wp-config.php)* | Database password |

Database credentials are auto-detected from `wp-config.php` if not explicitly set.

## Usage

```bash
# Basic backup using .env configuration
./wp-backup.sh

# Use a specific config file
./wp-backup.sh --config /etc/wp-backup.env

# Preview without making changes
./wp-backup.sh --dry-run

# Verbose output for debugging
./wp-backup.sh --verbose

# Override settings via environment
WP_PATH=/var/www/mysite RETAIN_COUNT=14 ./wp-backup.sh
```

### Options

| Flag | Description |
|---|---|
| `-c, --config FILE` | Path to config file (default: `.env` in script directory) |
| `-n, --dry-run` | Show what would happen without making changes |
| `-v, --verbose` | Enable detailed output |
| `-h, --help` | Show help message |

## Backup Output

Each run creates two timestamped files in your backup directory:

```
/var/backups/wordpress/
  db_20260216_020000.sql.gz          # Database dump
  wp-content_20260216_020000.tar.gz  # wp-content archive
  db_20260215_020000.sql.gz
  wp-content_20260215_020000.tar.gz
  ...
```

## Automating with Cron

Run daily at 2 AM:

```bash
crontab -e
```

```cron
0 2 * * * /path/to/wp-backup/wp-backup.sh >> /var/log/wp-backup.log 2>&1
```

## Restoring from Backup

### Database

```bash
gunzip < /var/backups/wordpress/db_20260216_020000.sql.gz | mysql -u USER -p DATABASE_NAME
```

### Files

```bash
tar -xzf /var/backups/wordpress/wp-content_20260216_020000.tar.gz -C /var/www/html/
```

## License

[MIT](LICENSE)
