#!/usr/bin/env bats
# Covers scenarios B-1 … B-5 (expected failure cases)

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'
load 'common.sh'

setup()   { build_image 15; network_up; }
teardown() { stop_test_env; network_rm; }

#
# B-1 – missing PGPASSWORD
#
@test "fails without PGPASSWORD" {
  start_primary 15; start_replica 15
  run docker exec -u postgres "$REPLICA" bash -c "unset PGPASSWORD; \
    pgclone --pghost pg-primary --pguser postgres \
    --primary-pgdata /var/lib/postgresql/data \
    --replica-pgdata /var/lib/postgresql/data \
    --ssh-key /tmp/id_rsa --ssh-user postgres \
    --insecure-ssh \
    --slot \
    --verbose"
  assert_failure
  assert_output --partial "FATAL: Authentication required"
}

#
# B-2 – primary PostgreSQL < 15
#
@test "fails on PG14 primary" {
  build_image 14
  docker tag "${IMAGE_BASE}:14" "${IMAGE_BASE}:tmp14"
  start_primary tmp14
  start_replica 15
  run docker exec -u postgres "$REPLICA" bash -c "export PGPASSWORD=postgres; \
    pgclone --pghost pg-primary --pguser postgres \
      --primary-pgdata /var/lib/postgresql/data \
      --replica-pgdata /var/lib/postgresql/data \
      --ssh-key /tmp/id_rsa --ssh-user postgres \
      --insecure-ssh \
      --slot \
      --verbose"
  assert_failure
  assert_output --partial "PostgreSQL >= 15 required"
}

#
# B-3 – wrong SSH key
#
@test "fails with wrong ssh key" {
  start_primary 15
  # replica gets wrong key
  ssh-keygen -t rsa -b 2048 -N "" -f wrong-key -q
  docker run --init -d \
    --name "$REPLICA" \
    --network "$NETWORK" \
    --label "pgclone-test-run=$RUN_ID" \
    -e POSTGRES_PASSWORD=postgres \
    -e ROLE=replica \
    -v "$PWD/pgclone":/usr/bin/pgclone:ro \
    -v "$PWD/wrong-key":/id_rsa:ro \
    "${IMAGE_BASE}:15" >/dev/null
  _TEST_CONTAINERS+=("$(docker ps -q -f name=$REPLICA)")
  run docker exec -u postgres "$REPLICA" bash -c "export PGPASSWORD=postgres; \
      pgclone --pghost pg-primary --pguser postgres \
        --primary-pgdata /var/lib/postgresql/data \
        --replica-pgdata /var/lib/postgresql/data \
        --ssh-key /tmp/id_rsa --ssh-user postgres \
        --insecure-ssh \
        --slot \
        --verbose"
  assert_failure
  assert_output --partial "SSH test failed"
  rm -f wrong-key wrong-key.pub
}

#
# B-4 – not enough disk
#
@test "fails when replica has no free space" {
  start_primary 15
  docker run --init -d \
    --name "$REPLICA" \
    --network "$NETWORK" \
    --label "pgclone-test-run=$RUN_ID" \
    -e POSTGRES_PASSWORD=postgres \
    -e ROLE=replica \
    -v "$PWD/test-key":/id_rsa:ro \
    -v "$PWD/pgclone":/usr/bin/pgclone:ro \
    --tmpfs /var/lib/postgresql/data:rw,size=100m \
    "${IMAGE_BASE}:15" >/dev/null
  _TEST_CONTAINERS+=("$(docker ps -q -f name=$REPLICA)")

  # fill replica pgdata disk with dummy file, left ~10MB and needed ~>30MB
  docker exec -u postgres "$REPLICA" dd if=/dev/zero of=/var/lib/postgresql/data/bigfile bs=1M count=90
  run docker exec -u postgres "$REPLICA" bash -c "export PGPASSWORD=postgres; \
    pgclone --pghost pg-primary --pguser postgres \
      --primary-pgdata /var/lib/postgresql/data \
      --replica-pgdata /var/lib/postgresql/data \
      --ssh-key /tmp/id_rsa --ssh-user postgres \
      --insecure-ssh \
      --slot \
      --verbose"
  assert_failure
  assert_output --partial "Insufficient disk space"
}

#
# B-5 – postmaster.pid exists in replica PGDATA
#
@test "fails when postgres already running in replica pgdata" {
  start_primary 15
  start_replica 15
  docker exec -u postgres "$REPLICA" bash -c "export PGPASSWORD=postgres; \
    pgclone --pghost pg-primary --pguser postgres \
      --primary-pgdata /var/lib/postgresql/data \
      --replica-pgdata /var/lib/postgresql/data \
      --ssh-key /tmp/id_rsa --ssh-user postgres \
      --insecure-ssh \
      --slot \
      --verbose"
  run start_pg_on_replica
  assert_success
  run docker exec -u postgres "$REPLICA" bash -c "export PGPASSWORD=postgres; \
    pgclone --pghost pg-primary --pguser postgres \
      --primary-pgdata /var/lib/postgresql/data \
      --replica-pgdata /var/lib/postgresql/data \
      --ssh-key /tmp/id_rsa --ssh-user postgres \
      --insecure-ssh \
      --slot \
      --verbose"
  assert_failure
  assert_output --partial "Seems like PostgreSQL instance already running or stale postmaster.pid has found"
}

#
# B-6 – run pgclone from user root
#
@test "fails when pgclone run from user root" {
  start_replica 15
  run docker exec -u root "$REPLICA" bash -c "export PGPASSWORD=postgres; \
    pgclone --pghost pg-primary --pguser postgres \
      --primary-pgdata /var/lib/postgresql/data \
      --replica-pgdata /var/lib/postgresql/data \
      --ssh-key /tmp/id_rsa --ssh-user postgres \
      --insecure-ssh \
      --slot \
      --verbose"
  assert_failure
  assert_output --partial "This script must not be run as root"
}

#
# B-7 – fails when permission denied for function pg_backup_start 
#
@test "fails when permission denied for function pg_backup_start" {
  start_primary 15
  start_replica 15
  docker exec -u postgres "$PRIMARY" bash -c "export PGPASSWORD=postgres; \
    psql -U postgres -h 127.0.0.1 -c \"CREATE USER test WITH PASSWORD 'password';\"; \
    psql -U postgres -h 127.0.0.1 -c \"ALTER ROLE test WITH REPLICATION;\""
  run docker exec -u postgres "$REPLICA" bash -c "export PGPASSWORD=password; \
    export PGDATABASE=postgres; \
    pgclone --pghost pg-primary --pguser test \
      --primary-pgdata /var/lib/postgresql/data \
      --replica-pgdata /var/lib/postgresql/data \
      --ssh-key /tmp/id_rsa --ssh-user postgres \
      --insecure-ssh \
      --slot \
      --verbose"
  assert_failure
  assert_output --partial "permission denied for function pg_backup_start"
}

#
# B-8 – fails when primary host key unknown and strict ssh
#
@test "fails when primary host key unknown and strict ssh" {
  start_primary 15
  start_replica 15
  run docker exec -u postgres "$REPLICA" bash -c "export PGPASSWORD=postgres; \
    pgclone --pghost pg-primary --pguser postgres \
      --primary-pgdata /var/lib/postgresql/data \
      --replica-pgdata /var/lib/postgresql/data \
      --ssh-key /tmp/id_rsa --ssh-user postgres \
      --slot \
      --verbose"
  assert_failure
  assert_output --partial "SSH test failed"
}

# ------------------------------------------------------------------------------
# B-9 – one rsync worker fails  ⇒  pgclone exits with non-zero status
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
