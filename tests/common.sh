#!/usr/bin/env bash
set -euo pipefail

IMAGE_BASE=pgclone-test
PRIMARY=pg-primary
REPLICA=pg-replica
NETWORK=pgclone-net
export PGPASSWORD=postgres
RUN_ID=${RUN_ID:-pgclone-$RANDOM}

declare -a _TEST_CONTAINERS=()

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
  docker run --init -d \
    --name "$PRIMARY" \
    --network "$NETWORK" \
    --label "pgclone-test-run=$RUN_ID" \
    -e POSTGRES_PASSWORD=postgres \
    -e ROLE=primary \
    -v "$PWD/test-key.pub":/tmp/test-key.pub:ro \
    "${IMAGE_BASE}:${pg_ver}" >/dev/null
  _TEST_CONTAINERS+=("$(docker ps -q -f name=$PRIMARY)")

  # Wait for the primary to create the /var/lib/postgresql/data/ready file
  for i in {1..30}; do
    docker exec "$PRIMARY" test -f /var/lib/postgresql/data/ready && break
    sleep 1
  done

  docker exec "$PRIMARY" test -f /var/lib/postgresql/data/ready || {
    echo "[common.sh] File /var/lib/postgresql/data/ready not found after 30 s" >&2
    return 1
  }

  # Wait for the primary to become ready
  for i in {1..30}; do
    docker exec "$PRIMARY" pg_isready -U postgres -q && break
    sleep 1
  done

  docker exec "$PRIMARY" pg_isready -U postgres -q || {
    echo "[common.sh] Primary did not become ready in 30 s" >&2
    return 1
  }

}

start_replica() {
  local pg_ver=$1
  docker run --init -d \
    --name "$REPLICA" \
    --network "$NETWORK" \
    --label "pgclone-test-run=$RUN_ID" \
    -e POSTGRES_PASSWORD=postgres \
    -e ROLE=replica \
    -v "$PWD/test-key":/id_rsa:ro \
    -v "$PWD/pgclone":/usr/bin/pgclone:ro \
    "${IMAGE_BASE}:${pg_ver}" >/dev/null
  _TEST_CONTAINERS+=("$(docker ps -q -f name=$REPLICA)")
}

run_pgclone() {
  docker exec -u postgres "$REPLICA" bash -c '
    set -euo pipefail
    export PGPASSWORD=postgres
RUN_ID=${RUN_ID:-pgclone-$RANDOM}

declare -a _TEST_CONTAINERS=()
    pgclone \
      --pghost pg-primary \
      --pgport 5432 \
      --pguser postgres \
      --primary-pgdata /var/lib/postgresql/data \
      --replica-pgdata /var/lib/postgresql/data \
      --replica-waldir /var/lib/postgresql/data/pg_wal \
      --temp-waldir /tmp/pg_wal \
      --ssh-key /tmp/id_rsa \
      --ssh-user postgres \
      --parallel 4 \
      --verbose'
}

start_replication() {
  docker exec -u postgres "$REPLICA" bash -c '
    echo "primary_conninfo = '\''host=pg-primary port=5432 user=postgres password=postgres sslmode=prefer application_name=replica1'\''" >> /var/lib/postgresql/data/postgresql.auto.conf &&
    touch /var/lib/postgresql/data/standby.signal'
  docker exec -u postgres "$REPLICA" pg_ctl -D /var/lib/postgresql/data start -w -t 60
}

stop_cluster() {
  docker rm -f "${_TEST_CONTAINERS[@]}" &>/dev/null || true
  _TEST_CONTAINERS=()
}

check_clean() {
  ! pgrep -f "(pg_receivewal|rsync.*--daemon|pgclone_watchdog)" &>/dev/null
  ! ls -1d /tmp/pgclone_* 2>/dev/null
}

run_psql() {
  local target=$1
  local port=$2
  local psql_cmd=$3

  docker exec -u postgres -i "$target" bash -eu - <<SH
export PGPASSWORD=postgres
psql -U postgres -h 127.0.0.1 -p $port -c "$psql_cmd"
SH
}
