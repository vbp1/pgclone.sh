#!/usr/bin/env bats
# Scenarios G-1 / G-2 – replica can start and read data incl. external tablespaces

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'
load '../common.sh'

setup()   { network_up; }
teardown() { stop_cluster; check_clean; }

build_image 15

@test "standby starts and streams (no tablespace)" {
  start_primary 15; start_replica 15
  run_pgclone
  promote_replica
  docker exec -u postgres "$REPLICA" psql -Atc "SELECT status FROM pg_stat_wal_receiver;" | grep -qx "streaming"
}

@test "reads data from external tablespace" {
  start_primary 15
  # create tablespace and data
  docker exec "$PRIMARY" bash -eu - <<'SH'
    mkdir -p /extspc
    chown postgres:postgres /extspc
    su - postgres -c "psql -c \"CREATE TABLESPACE ext LOCATION '/extspc'; \
                                  CREATE TABLE foo(id int) TABLESPACE ext; \
                                  INSERT INTO foo VALUES (123);\""
SH
  start_replica 15
  run_pgclone
  promote_replica
  run docker exec -u postgres "$REPLICA" psql -Atc "SELECT id FROM foo;"
  assert_success
  assert_output "123"
}
