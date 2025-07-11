#!/usr/bin/env bats
# Progress indicator modes

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'
load 'common.sh'

setup()   { build_image 15; network_up; }
teardown() { stop_test_env; network_rm; }

# Helper to run pgclone quickly – minimal dataset
pgclone_quick() {
  docker exec -u postgres "$REPLICA" bash -c "export PGPASSWORD=postgres; \
    pgclone --pghost pg-primary --pguser postgres \
      --primary-pgdata /var/lib/postgresql/data \
      --replica-pgdata /var/lib/postgresql/data \
      --ssh-key /tmp/id_rsa --ssh-user postgres \
      --insecure-ssh \
      --slot \
      --parallel 1 \
      --verbose \
      $*"
}

@test "progress bar mode prints dynamic bar" {
  start_primary 15; start_replica 15
  run pgclone_quick --progress=bar
  assert_success
  assert_output --partial "100 % ("
}

@test "progress plain mode prints ETA lines" {
  start_primary 15; start_replica 15
  run pgclone_quick --progress=plain --progress-interval=1
  assert_success
  assert_output --partial "100 % ("
  refute_output --partial $'\r'
}

@test "progress none mode suppresses bar" {
  start_primary 15; start_replica 15
  run pgclone_quick --progress=none
  assert_success
  refute_output --partial "100 % ("
} 