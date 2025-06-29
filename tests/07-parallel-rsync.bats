#!/usr/bin/env bats
# Scenarios F-1 … F-2 – parallel rsync robustness

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'
load 'common.sh'

setup()   { build_image 15; network_up; }
teardown() { stop_test_env; network_rm; }

# ------------------------------------------------------------------------------
# F-1 – one rsync worker fails  ⇒  pgclone exits with non-zero status
# ------------------------------------------------------------------------------
@test "rsync worker failure propagates to pgclone exit status" {
  start_primary 15; start_replica 15

docker exec -u postgres "$REPLICA" bash -c '
    set -euo pipefail
    cat > /tmp/rsync <<'EOF'
#!/usr/bin/env bash
# Only stub the parallel worker calls (--relative --inplace)
# Everything else (initial sync, --list-only) goes to real rsync
if [[ "\$*" == *"--relative"* && "\$*" == *"--inplace"* ]]; then
  while true; do echo test; sleep 1; done
else
  exec /usr/bin/rsync "\$@"
fi
EOF
    chmod +x /tmp/rsync
    export PATH="/tmp:$PATH"
    export PGPASSWORD=postgres
    pgclone \
        --pghost pg-primary \
        --pguser postgres \
        --primary-pgdata /var/lib/postgresql/data \
        --replica-pgdata /var/lib/postgresql/data \
        --ssh-key /tmp/id_rsa \
        --ssh-user postgres \
        --insecure-ssh \
        --parallel 4 \
        --slot \
        --verbose > /tmp/pgclone.log 2>&1 &
    echo $! > /tmp/pgclone.pid
    wait
    ' &

  # Wait until at least one rsync worker appears, then kill it
  docker exec "$REPLICA" bash -c '
  for i in {1..30}; do
    if pgrep -f "rsync .*-a --relative --inplace" | grep -v $$ >/dev/null; then
      break
    fi
    sleep 1
  done
  if pgrep -f "rsync .*-a --relative --inplace"| grep -v $$ >/dev/null; then
    pid_to_kill=$(pgrep -f "rsync .*-a --relative --inplace" | grep -v $$ | head -n1)
    kill -TERM "$pid_to_kill"
  else
    echo "no rsync procs found" >&2
    exit 1
  fi
'

  # Wait until main pgclone process terminates (max 60s)
  docker exec "$REPLICA" bash -c '
  for i in {1..60}; do
    if ! kill -0 $(cat /tmp/pgclone.pid) 2>/dev/null; then
      exit 0
    fi
    sleep 1
  done
  echo "pgclone did not stop in 60s" >&2
  exit 1
'

  # Check recorded exit status is non-zero
  run docker exec "$REPLICA" cat /tmp/pgclone.log
  assert_success
  assert_output --partial "FATAL: rsync worker failed"
  assert_output --partial "Running cleanup (rc=1)"

  check_clean
}

# ------------------------------------------------------------------------------
# F-2 – SIGINT to pgclone cleans up all rsync workers
# ------------------------------------------------------------------------------
@test "SIGINT triggers rsync workers cleanup" {
  start_primary 15; start_replica 15

docker exec -u postgres "$REPLICA" bash -c '
    set -euo pipefail
    cat > /tmp/rsync <<'EOF'
#!/usr/bin/env bash
# Only stub the parallel worker calls (--relative --inplace)
# Everything else (initial sync, --list-only) goes to real rsync
if [[ "\$*" == *"--relative"* && "\$*" == *"--inplace"* ]]; then
  while true; do echo test; sleep 1; done
else
  exec /usr/bin/rsync "\$@"
fi
EOF
    chmod +x /tmp/rsync
    export PATH="/tmp:$PATH"
    export PGPASSWORD=postgres
    pgclone \
        --pghost pg-primary \
        --pguser postgres \
        --primary-pgdata /var/lib/postgresql/data \
        --replica-pgdata /var/lib/postgresql/data \
        --ssh-key /tmp/id_rsa \
        --ssh-user postgres \
        --insecure-ssh \
        --parallel 4 \
        --slot \
        --verbose > /tmp/pgclone.log 2>&1 &
    echo $! > /tmp/pgclone.pid
    wait
    ' &

  # Wait until at least one rsync worker appears, then kill pgclone main script
  docker exec "$REPLICA" bash -c '
  for i in {1..30}; do
    if pgrep -f "rsync .*-a --relative --inplace" | grep -v $$ >/dev/null; then
      break
    fi
    sleep 1
  done
  if pgrep -f "rsync .*-a --relative --inplace"| grep -v $$ >/dev/null; then
    pid_to_kill=$(pgrep -f "rsync .*-a --relative --inplace" | grep -v $$ | head -n1)
    kill -TERM $(cat /tmp/pgclone.pid)
  else
    echo "no rsync procs found" >&2
    exit 1
  fi
'

  # Wait until pgclone exits
  docker exec "$REPLICA" bash -c '
  for i in {1..60}; do
    if ! kill -0 $(cat /tmp/pgclone.pid) 2>/dev/null; then
      exit 0
    fi
    sleep 1
  done
  echo "pgclone did not stop in 60s" >&2
  exit 1
'

  check_clean
} 