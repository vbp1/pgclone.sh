#!/usr/bin/env bats
# Scenarios F-1 … F-4 – path quirks, .partial, many tablespaces

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'
load '../common.sh'

setup()   { network_up; }
teardown() { stop_cluster; check_clean; }

build_image 15

@test "PGDATA with a space in path" {
  docker run -d --name "$PRIMARY" --network "$NETWORK" \
    -e POSTGRES_PASSWORD=postgres -e ROLE=primary \
    -v "$PWD/test-key.pub":/tmp/test-key.pub:ro \
    -v pgdata_space:/var/lib/postgresql/"data dir" \
    "${IMAGE_BASE}:15" >/dev/null

  start_replica 15
  run docker exec "$REPLICA" bash -c "export PGPASSWORD=postgres; pgclone \
    --pghost pg-primary --pguser postgres --primary-pgdata '/var/lib/postgresql/data dir' \
    --replica-pgdata /var/lib/postgresql/replica_out \
    --ssh-key /root/.ssh/id_rsa --ssh-user root"
  assert_success
  docker exec "$REPLICA" test -f /var/lib/postgresql/replica_out/backup_label
}

@test "20 separate tablespaces" {
  start_primary 15; start_replica 15
  docker exec "$PRIMARY" bash -eu - <<'SH'
    for i in $(seq 1 20); do
      dir="/tblspc$i"; mkdir -p "$dir"; chown postgres:postgres "$dir"
      su - postgres -c "psql -c \"CREATE TABLESPACE t$i LOCATION '$dir';\""
    done
SH
  run_pgclone
  for i in $(seq 1 20); do
    docker exec "$REPLICA" test -d "/tblspc$i"
  done
}

@test "replica_waldir == subdir of pgdata (default)" {
  build_image 15; start_primary 15; start_replica 15
  run_pgclone
  docker exec "$REPLICA" test ! -L /var/lib/postgresql/data/pg_wal   # should be a dir, not symlink
}

@test ".partial file is renamed" {
  start_primary 15; start_replica 15
  # inject dummy partial
  docker exec "$REPLICA" bash -c "touch /tmp/pg_wal/000000010000000000000001.partial"
  run_pgclone
  docker exec "$REPLICA" bash -c 'ls /var/lib/postgresql/data/pg_wal | grep -v partial'
}
