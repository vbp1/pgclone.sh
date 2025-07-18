#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'
load 'common.sh'

setup()   { build_image 15; network_up; }
teardown() { stop_test_env; network_rm; }

@test "Clone with --bypass-rep-traffic on PG15" {
    start_primary 15
    start_replica 15
    # Run pgclone with SSH port forwarding enabled
    run docker exec -u postgres "$REPLICA" bash -c '
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
        --bypass-rep-traffic \
        --slot \
        --parallel 4 \
        --verbose'
    assert_success

    # Ensure clone produced expected artifacts
    run docker exec -u postgres "$REPLICA" test -f /var/lib/postgresql/data/backup_label
    assert_success

    # Ensure cleanup is proper (no lingering ssh/pg_receivewal etc.)
    check_clean

    stop_test_env
  network_rm
}

# ------------------------------------------------------------------------------
# S-1 – kill pgclone main process while slot in use (moved from 11-slot-aborts.bats)
# ------------------------------------------------------------------------------
@test "replication slot removed after pgclone forced kill" {
  start_primary 15; start_replica 15

  docker exec -u postgres "$REPLICA" bash -c '
    set -euo pipefail
    export PGPASSWORD=postgres
    sed "/^exit 0/i echo \\$\\$ > /tmp/pgclone.pid; while [ ! -f /tmp/continue ]; do sleep 1; done" /usr/bin/pgclone > /tmp/pgclone.debug && \
    chmod +x /tmp/pgclone.debug && \
    /tmp/pgclone.debug \
        --pghost pg-primary \
        --pguser postgres \
        --primary-pgdata /var/lib/postgresql/data \
        --replica-pgdata /var/lib/postgresql/data \
        --ssh-key /tmp/id_rsa --ssh-user postgres \
        --insecure-ssh \
        --bypass-rep-traffic \
        --slot \
        --verbose \
        > /tmp/pgclone.log 2>&1 &
  '

  docker exec -u postgres "$REPLICA" bash -c '
    for i in {1..60}; do
      test -f /tmp/pgclone.pid && break
      sleep 1
    done
    test -f /tmp/pgclone.pid || { echo "pgclone.pid not found" >&2; exit 1; }
  '

  docker exec -u postgres "$PRIMARY" bash -c '
    for i in {1..60}; do
      slot=$(psql -At -U postgres -c "SELECT slot_name FROM pg_replication_slots WHERE slot_name LIKE '\''pgclone_%'\'';")
      [ -n "$slot" ] && exit 0
      sleep 1
    done
    echo "replication slot not created in time" >&2; exit 1
  '

  docker exec "$REPLICA" kill -TERM $(docker exec "$REPLICA" cat /tmp/pgclone.pid)
  docker exec "$REPLICA" touch /tmp/continue

  docker exec "$REPLICA" bash -c '
    for i in {1..60}; do
      if ! kill -0 $(cat /tmp/pgclone.pid) 2>/dev/null; then exit 0; fi
      sleep 1
    done
    echo "pgclone did not stop" >&2; exit 1
  '

  check_clean
}

# ------------------------------------------------------------------------------
# S-2 – crash pg_receivewal (SIGKILL) ⇒ watchdog should cleanup slot
# ------------------------------------------------------------------------------
@test "replication slot removed after pg_receivewal crash" {
  start_primary 15; start_replica 15

  docker exec -u postgres "$REPLICA" bash -c '
    set -euo pipefail
    export PGPASSWORD=postgres
    pgclone \
        --pghost pg-primary \
        --pguser postgres \
        --primary-pgdata /var/lib/postgresql/data \
        --replica-pgdata /var/lib/postgresql/data \
        --ssh-key /tmp/id_rsa --ssh-user postgres \
        --insecure-ssh \
        --bypass-rep-traffic \
        --slot \
        --verbose > /tmp/pgclone.log 2>&1 &
    echo $! > /tmp/pgclone.pid
  '

  docker exec -u postgres "$REPLICA" bash -c '
    for i in {1..60}; do
      pid=$(pgrep -f "[p]g_receivewal .* --slot")
      if [ -n "$pid" ]; then echo $pid > /tmp/pg_receivewal.pid; exit 0; fi
      sleep 1
    done
    echo "pg_receivewal not started" >&2; exit 1
  '

  docker exec "$REPLICA" kill -9 $(docker exec "$REPLICA" cat /tmp/pg_receivewal.pid)

  docker exec "$REPLICA" bash -c '
    for i in {1..60}; do
      if ! kill -0 $(cat /tmp/pgclone.pid) 2>/dev/null; then exit 0; fi
      sleep 1
    done
    echo "pgclone did not stop after pg_receivewal crash" >&2; exit 1
  '

  check_clean
}
