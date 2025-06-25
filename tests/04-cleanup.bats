#!/usr/bin/env bats
# Additional cleanliness check after normal run (D-1 / D-2)

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'
load 'common.sh'

setup()   { build_image 15; network_up; }
teardown() { stop_test_env; network_rm; }

@test "no stray processes or tmp files after successful clone" {
  start_primary 15; start_replica 15
  run_pgclone
  check_clean
}
