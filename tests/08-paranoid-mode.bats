#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'
load 'common.sh'

setup()   { build_image 15; network_up; }
teardown() { stop_test_env; network_rm; }

# Helper: run pgclone with supplied extra args
run_pgclone_paranoid() {
  docker exec -u postgres "$REPLICA" bash -c '
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
      --slot \
      --parallel 4 \
      --paranoid \
      --verbose'
}

@test "paranoid detects same-size, same-mtime file modification" {
  start_primary 15
  start_replica 15

  # 1. Create custom file on primary (v1)
  orig_epoch=$(docker exec -u postgres "$PRIMARY" bash -e -u -c '
    printf AAAAAAA > /var/lib/postgresql/data/global/custom.txt &&
    stat -c %Y /var/lib/postgresql/data/global/custom.txt
  ') || { echo "Error executing docker command" >&2; exit 1; }
  # 2. First clone (non-paranoid)
  run_pgclone
  run docker exec -u postgres "$REPLICA" test -f /var/lib/postgresql/data/backup_label
  assert_success
  run docker exec -u postgres "$REPLICA" cat /var/lib/postgresql/data/global/custom.txt
  assert_success
  assert_output "AAAAAAA"

  # 3. Modify file on primary to v2 but keep size and mtime
  docker exec -u postgres "$PRIMARY" bash -eu -c "
printf 'BBBBBBB' > /var/lib/postgresql/data/global/custom.txt
touch -m -d @${orig_epoch} /var/lib/postgresql/data/global/custom.txt
"

  # 4. Second clone without paranoid (should NOT copy change)
  run_pgclone
  run docker exec -u postgres "$REPLICA" test -f /var/lib/postgresql/data/backup_label
  assert_success
  run docker exec -u postgres "$REPLICA" cat /var/lib/postgresql/data/global/custom.txt
  assert_success
  assert_output "AAAAAAA"  # unchanged

  # 5. Third clone with --paranoid (should detect and copy)
  run_pgclone_paranoid
  run docker exec -u postgres "$REPLICA" test -f /var/lib/postgresql/data/backup_label
  assert_success
  run docker exec -u postgres "$PRIMARY" cat /var/lib/postgresql/data/global/custom.txt
  assert_success
  assert_output "BBBBBBB"
  run docker exec -u postgres "$REPLICA" cat /var/lib/postgresql/data/global/custom.txt
  assert_success
  assert_output "BBBBBBB"  # updated

  check_clean
} 