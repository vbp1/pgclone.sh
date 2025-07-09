#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'
load 'common.sh'

teardown() { stop_test_env; network_rm; }

@test "Happy-path on PG15/16/17" {
  for v in 15 16 17; do
    build_image "$v"
    network_up
    start_primary "$v"
    start_replica  "$v"

    run_pgclone

    run docker exec -u postgres "$REPLICA" test -f /var/lib/postgresql/data/backup_label
    assert_success
    run docker exec -u postgres "$REPLICA" ls /var/lib/postgresql/data/pg_wal
    assert_success
    [[ -n "$output" ]]

    check_clean

    start_pg_on_replica
    run docker exec -u postgres "$REPLICA" bash -c '
      export PGPASSWORD=postgres
      for i in {1..30}; do
        status=$(psql -h localhost -U postgres -Atc "SELECT status FROM pg_stat_wal_receiver;")
        if [ "$status" = "streaming" ]; then
          exit 0
        fi
        sleep 1
      done

      echo "replica did not start streaming from primary" >&2
      status=$(psql -h localhost -U postgres -Atc "SELECT status FROM pg_stat_wal_receiver;")
      echo "streaming status from pg_stat_wal_receiver is: $status" >&2
      exit 1
      '
    assert_success

    stop_test_env
    network_rm
  done
}
