#!/usr/bin/env bats
# Additional cleanliness check after normal run (D-1 / D-2)

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'
load '../common.sh'

setup()   { network_up; }
teardown() { stop_cluster; }

@test "no stray processes or tmp files after successful clone" {
  build_image 15; start_primary 15; start_replica 15
  run_pgclone
  check_clean   # assert inside common.sh
}
