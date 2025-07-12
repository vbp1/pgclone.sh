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
  docker image inspect "${IMAGE_BASE}:${pg_ver}" &>/dev/null || \
    docker build \
      --build-arg PG_MAJOR="$pg_ver" \
      -t "${IMAGE_BASE}:${pg_ver}" .
}

network_up() {
  docker network inspect "$NETWORK" &>/dev/null || docker network create "$NETWORK"
}

network_rm() {
  docker network rm -f "$NETWORK"
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
  # shellcheck disable=SC2034
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
      --insecure-ssh \
      --slot \
      --parallel 4 \
      --verbose'
}

start_pg_on_replica() {
  docker exec -u postgres "$REPLICA" bash -c '
    echo "primary_conninfo = '\''host=pg-primary port=5432 user=postgres password=postgres sslmode=prefer application_name=replica1'\''" >> /var/lib/postgresql/data/postgresql.auto.conf &&
    touch /var/lib/postgresql/data/standby.signal'
  docker exec -u postgres "$REPLICA" pg_ctl -D /var/lib/postgresql/data start -w -t 60
}

stop_test_env() {
  docker rm -f --volumes "${_TEST_CONTAINERS[@]}"
  _TEST_CONTAINERS=()
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

# shellcheck disable=SC2154
check_clean() {
  run docker exec -u postgres "$PRIMARY" pgrep -f '[r]sync.*--daemon'
  [ "$status" -ne 0 ] || fail "rsync daemon still running on master"

  run docker exec -u postgres "$PRIMARY" find /tmp -maxdepth 1 -type d -name 'pgclone_*'
  [ "$status" -eq 0 ]
  [ -z "$output" ] || fail "Leftover /tmp/pgclone_* dirs on master: $output"

  run docker exec -u postgres "$REPLICA" pgrep -f '[p]g_receivewal'
  [ "$status" -ne 0 ] || fail "pg_receivewal still running on replica"

  if docker exec -u postgres "$REPLICA" [ -d /tmp/pg_wal ]; then
      run docker exec -u postgres "$REPLICA" find /tmp/pg_wal -mindepth 1
      if [ "$status" -eq 0 ] && [ -z "$output" ]; then
        : # No action needed
      else
        fail "Temp WAL files remain in /tmp/pg_wal: $output"
      fi
  else
      run docker exec -u postgres "$REPLICA" find /tmp -maxdepth 1 -type d -name 'pgclone_temp.*'
      if [ "$status" -eq 0 ] && [ -z "$output" ]; then
        : # No action needed
      else
        fail "Temp WAL files remain in /tmp dir: $output"
      fi
  fi

  run docker exec -u postgres "$REPLICA" pgrep -af '[p]gclone'
  [ "$status" -ne 0 ] || fail "pgclone process still running on replica: $output"

  # Ensure no leftover rsync worker processes on replica
  run docker exec -u postgres "$REPLICA" pgrep -f 'rsync'
  [ "$status" -ne 0 ] || fail "rsync worker processes still running on replica: $output"
  run docker exec -u postgres "$REPLICA" pgrep -f 'awk'
  [ "$status" -ne 0 ] || fail "rsync auxiliary worker processes still running on replica: $output"

  # Ensure no leftover per-run temp directories
  run docker exec -u postgres "$REPLICA" find /tmp -maxdepth 1 -type d -name 'pgclone_*'
  if [ "$status" -eq 0 ] && [ -z "$output" ]; then
    : # No action needed
  else
    fail "Leftover pgclone_* dirs on replica: $output"
  fi

  # Ensure no leftover lock files (concurrent run protection)
  run docker exec -u postgres "$REPLICA" find /tmp -maxdepth 1 -type f -name 'pgclone_*.lock'
  if [ "$status" -eq 0 ] && [ -z "$output" ]; then
    : # No action needed
  else
    fail "Leftover pgclone_*.lock files on replica: $output"
  fi

  # Ensure temporary replication slot removed on primary
  run docker exec -u postgres "$PRIMARY" psql -At -c "SELECT slot_name FROM pg_replication_slots WHERE slot_name LIKE 'pgclone_%';"
  if [ "$status" -eq 0 ] && [ -z "$output" ]; then
    : # No action needed
  else
    fail "Replication slot still exists on primary: $output"
  fi
}
