#!/usr/bin/env bash
set -euo pipefail

IMAGE_BASE=pgclone-test
PRIMARY=pg-primary
REPLICA=pg-replica
NETWORK=pgclone-net
export PGPASSWORD=postgres

build_image() {
  local pg_ver=$1   # 15 | 16 | 17
  docker build \
    --build-arg PG_MAJOR="$pg_ver" \
    -t "${IMAGE_BASE}:${pg_ver}" .
}

network_up() {
  docker network inspect "$NETWORK" &>/dev/null || docker network create "$NETWORK"
}

start_primary() {
  local pg_ver=$1
  docker run -d --name "$PRIMARY" --network "$NETWORK" \
    -e POSTGRES_PASSWORD=postgres \
    -e ROLE=primary \
    -v "$PWD/test-key.pub":/tmp/test-key.pub:ro \
    "${IMAGE_BASE}:${pg_ver}" >/dev/null
}

start_replica() {
  local pg_ver=$1
  docker run -d --name "$REPLICA" --network "$NETWORK" \
    -e POSTGRES_PASSWORD=postgres \
    -e ROLE=replica \
    -v "$PWD/test-key":/root/.ssh/id_rsa:ro \
    -v "$PWD/pgclone":/usr/bin/pgclone:ro \
    "${IMAGE_BASE}:${pg_ver}" >/dev/null
}

run_pgclone() {
  docker exec "$REPLICA" bash -c '
    set -euo pipefail
    export PGPASSWORD=postgres
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
      --parallel 4'
}

promote_replica() {
  # для сценариев G-1/G-2
  docker exec "$REPLICA" bash -c '
    chown -R postgres:postgres /var/lib/postgresql/data &&
    echo "primary_conninfo = '\''host=pg-primary port=5432 user=postgres password=postgres sslmode=prefer application_name=replica1'\''" >> /var/lib/postgresql/data/postgresql.auto.conf &&
    touch /var/lib/postgresql/data/standby.signal'
  docker exec -u postgres "$REPLICA" pg_ctl -D /var/lib/postgresql/data start -w -t 60
}

stop_cluster() {
  docker rm -f "$PRIMARY" "$REPLICA" &>/dev/null || true
}

check_clean() {
  # общая проверка D-1/D-2 после любого теста
  ! pgrep -f "(pg_receivewal|rsync.*--daemon|pgclone_watchdog)" &>/dev/null
  ! ls -1d /tmp/pgclone_* 2>/dev/null
}
