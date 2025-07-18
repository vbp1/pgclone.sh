#!/usr/bin/env bats
# Scenarios F-1 … F-4 – path quirks, .partial, many tablespaces

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'
load 'common.sh'

setup()   { build_image 15; network_up; }
teardown() { stop_test_env; network_rm; }

@test "PGDATA with a space in path" {
  export PGDATA='/var/lib/postgresql/data dir'
  docker run --init -d \
    --name "$PRIMARY" \
    --network "$NETWORK" \
    --label "pgclone-test-run=$RUN_ID" \
    -e POSTGRES_PASSWORD=postgres \
    -e PGDATA="$PGDATA" \
    -e ROLE=primary \
    -v "$PWD/test-key.pub":/tmp/test-key.pub:ro \
    "${IMAGE_BASE}:15" >/dev/null
  _TEST_CONTAINERS+=("$(docker ps -q -f name=$PRIMARY)")

  # Wait for the primary to create the "$PGDATA"/ready file
  for i in {1..30}; do
    docker exec "$PRIMARY" test -f "$PGDATA"/ready && break
    sleep 1
  done

  docker exec "$PRIMARY" test -f "$PGDATA"/ready || {
    echo "[common.sh] File $PGDATA/ready not found after 30 s" >&2
    return 1
  }

  start_replica 15
  run docker exec -u postgres "$REPLICA" bash -c "export PGPASSWORD=postgres; \
      pgclone --pghost pg-primary --pguser postgres \
        --primary-pgdata '/var/lib/postgresql/data dir' \
        --replica-pgdata /var/lib/postgresql/data \
        --slot \
        --ssh-key /tmp/id_rsa --ssh-user postgres \
        --insecure-ssh \
        --verbose"
  assert_success
  run docker exec -u postgres "$REPLICA" test -f /var/lib/postgresql/data/backup_label
  assert_success
  run docker exec -u postgres "$REPLICA" test -f /var/lib/postgresql/data/PG_VERSION
  assert_success
}

@test "replica_waldir == subdir of pgdata (default)" {
  start_primary 15; start_replica 15
  run_pgclone
  run docker exec -u postgres "$REPLICA" test ! -L /var/lib/postgresql/data/pg_wal   # should be a dir, not symlink
  assert_success
}

@test "garbage in TEMP_WALDIR" {
  start_primary 15; start_replica 15
  # inject dummy partial
  docker exec -u postgres "$REPLICA" bash -c "mkdir -p /tmp/pg_wal && touch /tmp/pg_wal/000000010000000000007777"
  run_pgclone
  run docker exec -u postgres "$REPLICA" bash -c '
    if [ -f /var/lib/postgresql/data/pg_wal/000000010000000000007777 ]; then \
       echo "file /var/lib/postgresql/data/pg_wal/000000010000000000007777 exists"; \
       exit 1; \
    fi
  '
  assert_success
}
