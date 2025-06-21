#!/usr/bin/env bats
# Covers scenarios B-1 … B-5 (expected failure cases)

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'
load '../common.sh'

setup()   { network_up; }
teardown() { stop_cluster; check_clean; }

build_image 15   # reuse PG15 for all error tests

#
# B-1 – missing PGPASSWORD
#
@test "fails without PGPASSWORD" {
  start_primary 15; start_replica 15
  run docker exec "$REPLICA" bash -c "unset PGPASSWORD; pgclone --pghost pg-primary --pguser postgres --primary-pgdata /var/lib/postgresql/data --replica-pgdata /var/lib/postgresql/data --ssh-key /root/.ssh/id_rsa --ssh-user root || true"
  assert_failure
  assert_output --partial "PGPASSWORD env variable is required"
}

#
# B-2 – primary PostgreSQL < 15
#
@test "fails on PG14 primary" {
  build_image 14
  docker tag "${IMAGE_BASE}:14" "${IMAGE_BASE}:tmp14"
  start_primary tmp14
  build_image 15; start_replica 15
  run docker exec "$REPLICA" bash -c "export PGPASSWORD=postgres; pgclone --pghost pg-primary --pguser postgres --primary-pgdata /var/lib/postgresql/data --replica-pgdata /var/lib/postgresql/data --ssh-key /root/.ssh/id_rsa --ssh-user root || true"
  assert_failure
  assert_output --partial "PostgreSQL >= 15 required"
}

#
# B-3 – wrong SSH key
#
@test "fails with wrong ssh key" {
  start_primary 15
  # replica gets empty key
  docker run -d --name "$REPLICA" --network "$NETWORK" \
      -e POSTGRES_PASSWORD=postgres -e ROLE=replica \
      -v "$PWD/pgclone":/usr/bin/pgclone:ro \
      "${IMAGE_BASE}:15" >/dev/null
  run docker exec "$REPLICA" bash -c "export PGPASSWORD=postgres; pgclone --pghost pg-primary --pguser postgres --primary-pgdata /var/lib/postgresql/data --replica-pgdata /var/lib/postgresql/data --ssh-key /root/.ssh/id_rsa --ssh-user root || true"
  assert_failure
  assert_output --partial "SSH test failed"
}

#
# B-4 – not enough disk
#
@test "fails when replica has no free space" {
  start_primary 15; start_replica 15
  # fill replica disk with 90% dummy file (only in CI runner tmpfs, so fine)
  docker exec "$REPLICA" dd if=/dev/zero of=/bigfile bs=1M count=200 2>/dev/null
  run docker exec "$REPLICA" bash -c "export PGPASSWORD=postgres; pgclone --pghost pg-primary --pguser postgres --primary-pgdata /var/lib/postgresql/data --replica-pgdata /var/lib/postgresql/data --ssh-key /root/.ssh/id_rsa --ssh-user root || true"
  assert_failure
  assert_output --partial "Insufficient disk space"
}

#
# B-5 – postmaster.pid exists in replica PGDATA
#
@test "fails when postgres already running in replica pgdata" {
  start_primary 15
  start_replica 15
  docker exec -u postgres "$REPLICA" pg_ctl -D /var/lib/postgresql/data start -w -t 60
  run docker exec "$REPLICA" bash -c "export PGPASSWORD=postgres; pgclone --pghost pg-primary --pguser postgres --primary-pgdata /var/lib/postgresql/data --replica-pgdata /var/lib/postgresql/data --ssh-key /root/.ssh/id_rsa --ssh-user root || true"
  assert_failure
  assert_output --partial "PostgreSQL appears to be running"
}
