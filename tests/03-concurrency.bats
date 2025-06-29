#!/usr/bin/env bats
# Scenarios C-1 / C-2 – locking & parallel clones

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'
load 'common.sh'

setup()   { build_image 15; network_up; }
teardown() { stop_test_env; network_rm; }

@test "second pgclone in same PGDATA is rejected (lock)" {
  start_primary 15; start_replica 15
  # first clone async (background)
  docker exec -u postgres "$REPLICA" bash -c '
  export PGPASSWORD=postgres; \
  sed "/^exit 0/i sleep 3600" /usr/bin/pgclone > /tmp/pgclone.debug && \
  chmod +x /tmp/pgclone.debug && \
  nohup /tmp/pgclone.debug \
    --pghost pg-primary \
    --pguser postgres \
    --primary-pgdata /var/lib/postgresql/data \
    --replica-pgdata /var/lib/postgresql/data \
    --ssh-key /tmp/id_rsa --ssh-user postgres \
    --insecure-ssh \
    --slot \
    --verbose \
  > /tmp/pgclone.log 2>&1 &  
  '
  sleep 3
  # second clone should fail quickly
  run docker exec -u postgres "$REPLICA" bash -c "export PGPASSWORD=postgres; \
    pgclone --pghost pg-primary --pguser postgres \
    --primary-pgdata /var/lib/postgresql/data \
    --replica-pgdata /var/lib/postgresql/data \
    --ssh-key /tmp/id_rsa --ssh-user postgres \
    --insecure-ssh \
    --slot \
    --verbose"
  assert_failure
  assert_output --partial "Another pgclone is running"
}

@test "two independent target directories run in parallel" {
  start_primary 15
  start_replica 15
  # run clones concurrently
  docker exec -u postgres "$REPLICA" bash -c "export PGPASSWORD=postgres; \
    pgclone --pghost pg-primary --pguser postgres \
      --primary-pgdata /var/lib/postgresql/data \
      --replica-pgdata /var/lib/postgresql/replica1 \
      --ssh-key /tmp/id_rsa --ssh-user postgres \
      --insecure-ssh \
      --slot \
      --verbose" &
  sleep 2
  docker exec -u postgres "$REPLICA" bash -c "export PGPASSWORD=postgres; \
    pgclone --pghost pg-primary --pguser postgres \
      --primary-pgdata /var/lib/postgresql/data \
      --replica-pgdata /var/lib/postgresql/replica2 \
      --ssh-key /tmp/id_rsa --ssh-user postgres \
      --insecure-ssh \
      --slot \
      --verbose" &
  wait

  # basic artefact check
  docker exec -u postgres "$REPLICA" test -f /var/lib/postgresql/replica1/backup_label
  docker exec -u postgres "$REPLICA" test -f /var/lib/postgresql/replica2/backup_label
}
