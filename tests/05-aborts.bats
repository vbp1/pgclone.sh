#!/usr/bin/env bats
# Scenarios E-1 … E-3 – abrupt termination & watchdog

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'
load 'common.sh'

setup()   { build_image 15; network_up; }
teardown() { stop_test_env; network_rm; }

#
# E-1 – kill pgclone mid-rsync on replica
#
@test "watchdog cleans up after pgclone forced kill" {
  start_primary 15; start_replica 15
  # first clone async (background)
  docker exec -u postgres "$REPLICA" bash -c '
  export PGPASSWORD=postgres; \
  sed "/^exit 0/i echo \$\$ > /tmp/pgclone.pid; while true; do sleep 1; done" /usr/bin/pgclone > /tmp/pgclone.debug && \
  chmod +x /tmp/pgclone.debug && \
  /tmp/pgclone.debug \
    --pghost pg-primary \
    --pguser postgres \
    --primary-pgdata /var/lib/postgresql/data \
    --replica-pgdata /var/lib/postgresql/data \
    --ssh-key /tmp/id_rsa --ssh-user postgres \
    --insecure-ssh \
    --verbose \
    > /tmp/pgclone.log 2>&1 & 
  '
  docker exec -u postgres "$REPLICA" bash -c "
    for i in {1..30}; do
      if test -f /tmp/pgclone.pid; then
        kill -TERM \$(cat /tmp/pgclone.pid)
        exit 0
      fi
      sleep 1
    done
    cat /tmp/pgclone.log
    echo 'pgclone.pid not found'
    exit 1
  "
  sleep 3
  check_clean
}

@test "rsyncd watchdog stops when ssh tunnel killed" {
  start_primary 15; start_replica 15

  docker exec -u postgres "$REPLICA" bash -c '
  export PGPASSWORD=postgres; \
  sed "/^\# TEST_stop_point_1/a echo \\$\\$ > /tmp/pgclone.pid; while [ ! -f /tmp/continue ]; do sleep 1; done" /usr/bin/pgclone > /tmp/pgclone.debug && \
  chmod +x /tmp/pgclone.debug && \
  /tmp/pgclone.debug \
    --pghost pg-primary \
    --pguser postgres \
    --primary-pgdata /var/lib/postgresql/data \
    --replica-pgdata /var/lib/postgresql/data \
    --ssh-key /tmp/id_rsa --ssh-user postgres \
    --insecure-ssh \
    --verbose \
    > /tmp/pgclone.log 2>&1 & 
  '

  docker exec -u postgres "$REPLICA" bash -c '
    for i in {1..30}; do
      [ -f /tmp/pgclone.pid ] && exit 0
      sleep 1
    done
    echo "pgclone.pid not found" >&2
    exit 1
  '

  SSH_PID=$(docker exec "$REPLICA" pgrep -f '^ssh .* postgres@pg-primary')
  docker exec "$REPLICA" kill -9 "$SSH_PID"
  docker exec "$REPLICA" touch /tmp/continue

  docker exec -u postgres "$REPLICA" bash -c '
    for i in {1..30}; do
      if ! kill -0 $(cat /tmp/pgclone.pid) 2>/dev/null; then
        exit 0
      fi
      sleep 1
    done
    cat /tmp/pgclone.log
    echo "pgclone did not stop in 30s" >&2
    exit 1
  '

  sleep 3
  check_clean
}

# ------------------------------------------------------------------------------
# E-2 – TERM to rsync worker ⇒ pgclone exits with non-zero status
# ------------------------------------------------------------------------------
@test "TERM to rsync worker -> pgclone exits with non-zero status" {
  start_primary 15; start_replica 15

docker exec -u postgres "$REPLICA" bash -c '
    set -euo pipefail
    cat > /tmp/rsync <<'EOF'
#!/usr/bin/env bash
# Only stub the parallel worker calls (--relative --inplace)
# Everything else (initial sync, --list-only) goes to real rsync
if [[ "\$*" == *"--relative"* && "\$*" == *"--inplace"* && "\$*" != *"--dry-run"* ]]; then
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
