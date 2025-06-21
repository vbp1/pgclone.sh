#!/usr/bin/env bats
# Covers scenarios A-2 … A-7 (parameters & variants)

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'
load '../common.sh'

setup()   { network_up; }
teardown() { stop_cluster; check_clean; }

#
# A-2  – external tablespaces
#
@test "clone with two external tablespaces" {
  build_image 15
  start_primary 15
  start_replica 15

  # prepare two tablespaces on primary
  docker exec "$PRIMARY" bash -eu - <<'SH'
    mkdir -p /tblspc1 /tblspc2
    chown postgres:postgres /tblspc1 /tblspc2
    su - postgres -c "psql -c \"CREATE TABLESPACE t1 LOCATION '/tblspc1'; \
                                  CREATE TABLESPACE t2 LOCATION '/tblspc2'; \
                                  CREATE TABLE t_in_t1(id int) TABLESPACE t1; \
                                  CREATE TABLE t_in_t2(id int) TABLESPACE t2;\""
SH

  run_pgclone

  # verify tablespaces copied
  docker exec "$REPLICA" test -d /tblspc1
  docker exec "$REPLICA" test -d /tblspc2
}

#
# A-3 – custom --replica-waldir
#
@test "clone with custom replica waldir" {
  build_image 15
  start_primary 15
  start_replica 15

  export REPLICA_WALDIR_CUSTOM="/custom_wal"
  docker exec "$REPLICA" mkdir -p "$REPLICA_WALDIR_CUSTOM"

  run docker exec "$REPLICA" bash -c "
    set -euo pipefail
    export PGPASSWORD=postgres
    pgclone \
      --pghost pg-primary \
      --pgport 5432 \
      --pguser postgres \
      --primary-pgdata /var/lib/postgresql/data \
      --replica-pgdata /var/lib/postgresql/data \
      --replica-waldir $REPLICA_WALDIR_CUSTOM \
      --temp-waldir /tmp/pg_wal \
      --ssh-key /root/.ssh/id_rsa \
      --ssh-user root \
      --parallel 4"
  assert_success
  docker exec "$REPLICA" test -L /var/lib/postgresql/data/pg_wal          # symlink
  docker exec "$REPLICA" test -f "$REPLICA_WALDIR_CUSTOM"/$(ls "$REPLICA_WALDIR_CUSTOM" | head -1)
}

#
# A-4 – custom --temp-waldir is removed afterwards
#
@test "temp-waldir directory is cleaned" {
  build_image 15
  start_primary 15
  start_replica 15
  docker exec "$REPLICA" mkdir -p /tmp/my_temp_wal

  run docker exec "$REPLICA" bash -c "
    set -euo pipefail
    export PGPASSWORD=postgres
    pgclone \
      --pghost pg-primary \
      --pgport 5432 \
      --pguser postgres \
      --primary-pgdata /var/lib/postgresql/data \
      --replica-pgdata /var/lib/postgresql/data \
      --replica-waldir /var/lib/postgresql/data/pg_wal \
      --temp-waldir /tmp/my_temp_wal \
      --ssh-key /root/.ssh/id_rsa \
      --ssh-user root \
      --parallel 4"
  assert_success
  # directory exists but must be empty
  docker exec "$REPLICA" bash -c '[[ $(find /tmp/my_temp_wal -mindepth 1 | wc -l) -eq 0 ]]'
}

#
# A-5 – primary on non-default port 5444
#
@test "clone from primary on port 5444" {
  build_image 15
  # run primary mapping internal 5432 → exposed 5444 inside network
  docker run -d --name "$PRIMARY" --network "$NETWORK" \
    -e POSTGRES_PASSWORD=postgres -e ROLE=primary \
    -p 5444:5432 \
    -v "$PWD/test-key.pub":/tmp/test-key.pub:ro \
    "${IMAGE_BASE}:15" >/dev/null
  start_replica 15

  run docker exec "$REPLICA" bash -c "
    set -euo pipefail
    export PGPASSWORD=postgres
    pgclone --pghost pg-primary --pgport 5444 \
      --pguser postgres --primary-pgdata /var/lib/postgresql/data \
      --replica-pgdata /var/lib/postgresql/data \
      --ssh-key /root/.ssh/id_rsa --ssh-user root"
  assert_success
}

#
# A-6 – PARALLEL=1 and PARALLEL=8 just complete successfully
#
@test "PARALLEL=1 works" {
  build_image 15; start_primary 15; start_replica 15
  run docker exec "$REPLICA" bash -c "export PGPASSWORD=postgres; pgclone --pghost pg-primary --pguser postgres --primary-pgdata /var/lib/postgresql/data --replica-pgdata /var/lib/postgresql/data --parallel 1 --ssh-key /root/.ssh/id_rsa --ssh-user root"
  assert_success
}
@test "PARALLEL=8 works" {
  build_image 15; start_primary 15; start_replica 15
  run docker exec "$REPLICA" bash -c "export PGPASSWORD=postgres; pgclone --pghost pg-primary --pguser postgres --primary-pgdata /var/lib/postgresql/data --replica-pgdata /var/lib/postgresql/data --parallel 8 --ssh-key /root/.ssh/id_rsa --ssh-user root"
  assert_success
}

#
# A-7 – fixed --rsync-port
#
@test "clone with fixed rsync port" {
  build_image 15; start_primary 15; start_replica 15
  run docker exec "$REPLICA" bash -c "export PGPASSWORD=postgres; pgclone --pghost pg-primary --pguser postgres --primary-pgdata /var/lib/postgresql/data --replica-pgdata /var/lib/postgresql/data --rsync-port 45055 --ssh-key /root/.ssh/id_rsa --ssh-user root"
  assert_success
}
