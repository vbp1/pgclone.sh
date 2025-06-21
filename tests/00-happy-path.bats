#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'
load '../common.sh'

@test "Happy-path on PG15/16/17" {
  for v in 15 16 17; do
    build_image "$v"
    network_up
    start_primary "$v"
    start_replica  "$v"

    # ---------- действие ------------------
    run_pgclone
    # ---------- проверки ------------------
    docker exec "$REPLICA" test -f /var/lib/postgresql/data/backup_label
    docker exec "$REPLICA" test -s /var/lib/postgresql/data/pg_wal/$(ls /var/lib/postgresql/data/pg_wal | head -1)

    promote_replica
    docker exec -u postgres "$REPLICA" psql -Atc "SELECT state FROM pg_stat_wal_receiver;" | \
      grep -qx "streaming"

    # ---------- финализация ---------------
    stop_cluster
    check_clean
  done
}
