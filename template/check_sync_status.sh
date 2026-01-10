#!/bin/bash

# ==============================================================================
# 0. Force Bash (Fixes "source: not found" when running with 'sh')
# ==============================================================================
if [ -z "$BASH_VERSION" ]; then
    echo "⚠️  Detected non-Bash shell. Switching to Bash..."
    exec bash "$0" "$@"
fi

# Load environment variables from .env
if [ -f .env ]; then
  # Use a safer way to export variables that handles spaces/quotes better is preferred, 
  # but for simple .env files this is standard. 
  # Using 'set -a' and sourcing is often cleaner.
  set -a
  source .env
  set +a
else
  echo "Error: .env file not found in current directory."
  echo "Please run this script from the 'template' directory where your .env file is located."
  exit 1
fi

CONTAINER_NAME="backup_${PROJECT_NAME}"

echo "========================================================"
echo "Checking Replication Status for: $CONTAINER_NAME"
echo "========================================================"

# Check if container is running
if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
  echo "Error: Container '$CONTAINER_NAME' is not running."
  echo "Please ensure you have started the services with 'docker-compose up -d'."
  exit 1
fi

# Execute MySQL command and filter output
# We use docker exec to run the command inside the container.
# We explicitly ask for specific fields to make it readable.
docker exec "$CONTAINER_NAME" mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -e "SHOW SLAVE STATUS\G" |
grep -E "Slave_IO_Running:|Slave_SQL_Running:|Seconds_Behind_Master:|Last_IO_Error:|Last_SQL_Error:|Master_Host:|Master_User:|Master_Port:"

echo "========================================================"
echo "Interpretation:"
echo "  Slave_IO_Running:  Must be 'Yes' (Connected to Master)"
echo "  Slave_SQL_Running: Must be 'Yes' (Executing updates)"
echo "  Seconds_Behind_Master: Should be 0 (or low number)"
echo "========================================================"
