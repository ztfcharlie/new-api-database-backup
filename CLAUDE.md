# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This is a Docker-based MySQL replication backup solution using SSH tunnels. It enables secure, non-intrusive real-time master-slave replication without exposing production database ports to the public internet. Each backup instance runs as an isolated Docker container with its own phpMyAdmin interface.

## Architecture

The system uses three main Docker services orchestrated by docker-compose:

1. **tunnel** - SSH tunnel container (Alpine) that creates an encrypted connection to the production server's MySQL via localhost-only ports
2. **db** - MySQL 8.0 slave container that connects through the tunnel service to the master
3. **pma** - phpMyAdmin for visual management (bound to 127.0.0.1 only for security)

The `docker-compose-with-newapi.yml` variant adds a fourth service:
4. **new-aiapi** - calciumion/new-api-horizon application that connects to the replicated database

### Key Design Points

- Master-slave replication uses GTID (Global Transaction IDs) for automatic positioning
- The `db` container runs `init-slave.sh` as a background daemon that monitors and auto-repairs replication issues
- SSH keys are shared via volume mount from `../id_rsa/id_rsa_backup`
- All MySQL containers use `server-id=100` (production should use `server-id=1`)
- phpMyAdmin binds to `127.0.0.1` only - access via SSH tunnel from local machine

## Project Structure

```
/
├── template/              # Copy this to create new backup instances
│   ├── docker-compose.yml               # Standard 3-service setup
│   ├── docker-compose-with-newapi.yml   # Extended setup with API service
│   ├── .env.example                     # Environment variable template
│   ├── init-slave.sh                    # Auto-repair daemon for replication
│   ├── quick_start_sync.sh              # One-click initial sync (for new/small DBs)
│   ├── backup_physical.sh               # XtraBackup for large databases (>20GB)
│   ├── restore_slave.sh                 # Restore from physical backup
│   └── check_sync_status.sh             # Check replication status
├── id_rsa/              # SSH private keys directory
├── README.md            # User documentation (Chinese)
└── document.md          # Operational notes/workflow
```

## Common Commands

### Creating a New Backup Instance

```bash
# 1. Copy template and configure
cp -r template my_backup_project
cd my_backup_project
cp .env.example .env

# 2. Edit .env with your settings
# Key variables: PROJECT_NAME, SSH_HOST, REMOTE_DB_PORT, PMA_WEB_PORT, TARGET_DB_NAME

# 3. Start containers
docker-compose up -d
```

### Initial Data Synchronization

Three methods depending on database size:

**Method A: Quick Start (for new/empty databases)**
```bash
./quick_start_sync.sh
```

**Method B: Logical Import (for <20GB databases)**
```bash
# On production server:
docker exec [prod_container] mysqldump -u root -p \
  --single-transaction --master-data=2 --triggers --routines --events \
  --databases [db_name] | gzip > snapshot.sql.gz

# On backup server (after copying file):
(echo "SET sql_log_bin=0;"; zcat snapshot.sql.gz) | \
  docker exec -i backup_[PROJECT_NAME] mysql -u root -p[local_password]

# Restore binlog and start replication:
echo "SET sql_log_bin=1; START SLAVE; SHOW SLAVE STATUS\G" | \
  docker exec -i backup_[PROJECT_NAME] mysql -u root -p[local_password]
```

**Method C: Physical Backup (for >20GB databases)**
```bash
# On production server:
./backup_physical.sh [prod_container] [mysql_password]

# On backup server (after copying file):
./restore_slave.sh ./prod_full.tar.gz ./data
```

### Checking Replication Status

```bash
# Using the helper script
./check_sync_status.sh

# Or directly
docker exec backup_[PROJECT_NAME] mysql -u root -p -e "SHOW SLAVE STATUS\G"

# Check tunnel connection
docker logs tunnel_[PROJECT_NAME]
```

### Manual Replication Repair

```bash
# Force start slave if replication is stuck
docker exec -i backup_[PROJECT_NAME] mysql -u root -p -e "START SLAVE;"
```

### Accessing phpMyAdmin

Since phpMyAdmin binds to `127.0.0.1`, create an SSH tunnel from your local machine:

```bash
ssh -L [PMA_WEB_PORT]:127.0.0.1:[PMA_WEB_PORT] root@[backup_server]
# Then open http://localhost:[PMA_WEB_PORT] in browser
```

## Environment Variables (.env)

| Variable | Description |
|-----------|-------------|
| `PROJECT_NAME` | Unique identifier for this backup instance (used in container names) |
| `SSH_HOST` | Production server IP address |
| `SSH_PORT` | SSH port (default 22) |
| `SSH_USER` | SSH login user (e.g., core, root) |
| `SSH_PASSWORD` | SSH password (optional, used if SSH key unavailable) |
| `REMOTE_DB_PORT` | MySQL port on production server (e.g., 3306, 3307) |
| `PMA_WEB_PORT` | phpMyAdmin port on backup server (must be unique per instance) |
| `NEW_API_PORT` | API service port (only for docker-compose-with-newapi.yml) |
| `TARGET_DB_NAME` | Database name to replicate |
| `MASTER_USER` | Replication user on master (usually root) |
| `MASTER_PASSWORD` | Replication user password |
| `MYSQL_ROOT_PASSWORD` | Root password for local backup database |

## Important Notes

- SSH key permissions must be correct: `chmod 700 id_rsa/` and `chmod 600 id_rsa/id_rsa_backup`
- The `init-slave.sh` daemon runs continuously and auto-repairs replication failures
- Production MySQL must have binary logging enabled with GTID
- When using physical backups (XtraBackup), the `restore_slave.sh` outputs the required `CHANGE MASTER TO` SQL command
- Resource limits are set to 0.5 CPU and 1GB memory - adjust in docker-compose if needed
