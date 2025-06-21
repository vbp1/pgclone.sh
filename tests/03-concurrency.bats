#!/usr/bin/env bats
# Scenarios C-1 / C-2 – locking & parallel clones

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'
load '../common.sh'

setup()   { network_up; }
teardown() { stop_cluster; check_clean; }

build_image 15

@test "second pgclone in same PGDATA is rejected (lock)" {
  start_primary 15; start_replica 15
  # first clone async (background)
  docker exec "$REPLICA" bash -c "export PGPASSWORD=postgres; pgclone --pghost pg-primary --pguser postgres --primary-pgdata /var/lib/postgresql/data --replica-pgdata /var/lib/postgresql/data --ssh-key /root/.ssh/id_rsa --ssh-user root" &
  sleep 2
  # second clone should fail quickly
  run docker exec "$REPLICA" bash -c "export PGPASSWORD=postgres; pgclone --pghost pg-primary --pguser postgres --primary-pgdata /var/lib/postgresql/data --replica-pgdata /var/lib/postgresql/data --ssh-key /root/.ssh/id_rsa --ssh-user root || true"
  assert_failure
  assert_output --partial "Another pgclone is running"
}

@test "two independent target directories run in parallel" {
  start_primary 15
  # first replica container
  docker run -d --name pg-replica1 --network "$NETWORK" \
      -e POSTGRES_PASSWORD=postgres -e ROLE=replica \
      -v "$PWD/test-key":/root/.ssh/id_rsa:ro \
      -v "$PWD/pgclone":/usr/bin/pgclone:ro \
      "${IMAGE_BASE}:15" >/dev/null
  # second replica container
  docker run -d --name pg-replica2 --network "$NETWORK" \
      -e POSTGRES_PASSWORD=postgres -e ROLE=replica \
      -v "$PWD/test-key":/root/.ssh/id_rsa:ro \
      -v "$PWD/pgclone":/usr/bin/pgclone:ro \
      "${IMAGE_BASE}:15" >/dev/null

  # run clones concurrently
  docker exec pg-replica1 bash -c "export PGPASSWORD=postgres; pgclone --pghost pg-primary --pguser postgres --primary-pgdata /var/lib/postgresql/data --replica-pgdata /var/lib/postgresql/replica1 --ssh-key /root/.ssh/id_rsa --ssh-user root" &
  docker exec pg-replica2 bash -c "export PGPASSWORD=postgres; pgclone --pghost pg-primary --pguser postgres --primary-pgdata /var/lib/postgresql/data --replica-pgdata /var/lib/postgresql/replica2 --ssh-key /root/.ssh/id_rsa --ssh-user root" &
  wait

  # basic artefact check
  docker exec pg-replica1 test -f /var/lib/postgresql/replica1/backup_label
  docker exec pg-replica2 test -f /var/lib/postgresql/replica2/backup_label
}
