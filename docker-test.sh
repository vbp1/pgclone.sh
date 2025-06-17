#!/usr/bin/env bash

set -euo pipefail

IMAGE=pgclone-test
NETWORK=pgclone-net
PRIMARY_CONTAINER=pg-primary
REPLICA_CONTAINER=pg-replica
declare -A skip_container=()

# === Check for existing Docker image ===
if docker image inspect "$IMAGE" > /dev/null 2>&1; then
    read -r -p "Docker image '$IMAGE' already exists. Rebuild? [y/N] " rebuild
    if [[ "$rebuild" =~ ^[Yy]$ ]]; then
        echo ">>> Removing image '$IMAGE' and dependent containers..."
        # Stop and remove containers using the image
        docker ps -a --filter "ancestor=$IMAGE" --format "{{.ID}}" | xargs -r docker rm -f
        docker rmi -f "$IMAGE"
        echo ">>> Building Docker image..."
        docker build -t "$IMAGE" .
    fi
else
    echo ">>> Building Docker image..."
    docker build -t "$IMAGE" .
fi

# === Create network if missing ===
docker network inspect "$NETWORK" > /dev/null 2>&1 || docker network create "$NETWORK"

# === Check and manage existing containers ===
for container in "$PRIMARY_CONTAINER" "$REPLICA_CONTAINER"; do
    if docker ps -a --format '{{.Names}}' | grep -qw "$container"; then
        read -r -p "Container '$container' already exists. Remove and recreate? [y/N] " recreate
        if [[ "$recreate" =~ ^[Yy]$ ]]; then
            docker rm -f "$container"
        else
            echo ">>> Skipping container '$container'"
            skip_container["$container"]=1
            continue
        fi
    fi
done

set -euo pipefail

echo ">>> Starting containers..."
if [[ -z "${skip_container[$PRIMARY_CONTAINER]:-}" ]]; then
    docker run -d \
      --name "$PRIMARY_CONTAINER" \
      --network "$NETWORK" \
      -e POSTGRES_PASSWORD=postgres \
      -e ROLE=primary \
      -v "$PWD/test-key.pub":/tmp/test-key.pub:ro \
      "$IMAGE"
fi

if [[ -z "${skip_container[$REPLICA_CONTAINER]:-}" ]]; then
    docker run -d \
      --name "$REPLICA_CONTAINER" \
      --network "$NETWORK" \
      -e POSTGRES_PASSWORD=postgres \
      -e ROLE=replica \
      -v "$PWD/test-key":/root/.ssh/id_rsa:ro \
      -v "$PWD/pgclone":/usr/bin/pgclone:ro \
      "$IMAGE"
fi

sleep 5

echo ">>> Running pgclone inside replica..."
docker exec "$REPLICA_CONTAINER" bash -c '
  export PGPASSWORD=postgres && \
  pgclone \
    --pghost pg-primary \
    --pgport 5432 \
    --pguser postgres \
    --primary-pgdata /var/lib/postgresql/data \
    --replica-pgdata /var/lib/postgresql/data \
    --replica-waldir /var/lib/postgresql/data/pg_wal \
    --temp-waldir /tmp/pg_wal \
    --ssh-key /root/.ssh/id_rsa \
    --ssh-user root \
    --parallel 4 \
    --verbose'

echo ">>> Done. Checking replica PG_VERSION..."
docker exec "$REPLICA_CONTAINER" cat /var/lib/postgresql/data/PG_VERSION

echo ">>> Configuring and running replica..."
docker exec "$REPLICA_CONTAINER" bash -c '
    chown -R postgres:postgres /var/lib/postgresql/data/'
docker exec -u postgres "$REPLICA_CONTAINER" bash -c "
    echo \"primary_conninfo = 'host=pg-primary port=5432 user=postgres \
    password=postgres sslmode=prefer \
    application_name=replica1'\" >> /var/lib/postgresql/data/postgresql.auto.conf && \
    touch /var/lib/postgresql/data/standby.signal && \
    /usr/lib/postgresql/15/bin/pg_ctl -D /var/lib/postgresql/data/ start"

sleep 10
docker exec -u postgres "$REPLICA_CONTAINER" bash -c '
    /usr/lib/postgresql/15/bin/pg_ctl -D /var/lib/postgresql/data/ stop'

for container in "$PRIMARY_CONTAINER" "$REPLICA_CONTAINER"; do
    read -r -p "Remove container '$container'? [y/N] " remove
    if [[ "$remove" =~ ^[Yy]$ ]]; then
        docker rm -f "$container"
    else
        echo ">>> Skipping container '$container'"
        continue
    fi
done
