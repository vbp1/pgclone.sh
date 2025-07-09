#!/usr/bin/env bats
# Covers scenarios A-2 … A-7 (parameters & variants)

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'
load 'common.sh'

setup()   { build_image 15; network_up; }
teardown() { stop_test_env; network_rm; }

#
# A-2  – external tablespaces
#
@test "clone with two external tablespaces and read data" {
  start_primary 15
  start_replica 15

  # prepare two tablespaces on primary
  docker exec -i "$PRIMARY" bash -eux - <<'SH'
    mkdir -p /tblspc1 /tblspc2
    chown postgres:postgres /tblspc1 /tblspc2
SH
   run_psql pg-primary 5432 "CREATE TABLE t_default(id int);"
   run_psql pg-primary 5432 "CREATE TABLESPACE t1 LOCATION '/tblspc1';"
   run_psql pg-primary 5432 "CREATE TABLESPACE t2 LOCATION '/tblspc2';"
   run_psql pg-primary 5432 "CREATE TABLE t_in_t1(id int) TABLESPACE t1;"
   run_psql pg-primary 5432 "CREATE TABLE t_in_t2(id int) TABLESPACE t2;"
   run_psql pg-primary 5432 "INSERT INTO t_default SELECT generate_series(1, 100);"
   run_psql pg-primary 5432 "INSERT INTO t_in_t1 SELECT generate_series(1, 10000);"
   run_psql pg-primary 5432 "INSERT INTO t_in_t2 SELECT generate_series(10001, 15000);"

  docker exec -i "$REPLICA" bash -eux - <<'SH'
    mkdir -p /tblspc1 /tblspc2
    chown postgres:postgres /tblspc1 /tblspc2
SH

  run_pgclone

  # verify tablespaces copied
  docker exec -u postgres "$REPLICA" test -d /tblspc1
  docker exec -u postgres "$REPLICA" test -d /tblspc2

  for spc in /tblspc1 /tblspc2; do
    docker exec -u postgres "$REPLICA" bash -c "
      for link in /var/lib/postgresql/data/pg_tblspc/*; do
        target=\$(readlink -f \"\$link\")
        if [[ \"\$target\" == \"$spc\" ]]; then
          exit 0
        fi
      done
      echo 'No link points to $spc'
      exit 1
    "
  done

  start_pg_on_replica

  run docker exec -u postgres "$REPLICA" psql -Atc "SELECT sum(id) FROM t_default;"
  assert_success
  assert_output "5050"

  run docker exec -u postgres "$REPLICA" psql -Atc "SELECT sum(id) FROM t_in_t1;"
  assert_success
  assert_output "50005000"

  run docker exec -u postgres "$REPLICA" psql -Atc "SELECT sum(id) FROM t_in_t2;"
  assert_success
  assert_output "62502500"
}

#
# A-3 – custom --replica-waldir
#
@test "clone with custom replica waldir" {
  start_primary 15
  start_replica 15

  REPLICA_WALDIR_CUSTOM=/custom_wal
  docker exec "$REPLICA" mkdir -p "$REPLICA_WALDIR_CUSTOM"
  docker exec "$REPLICA" chown postgres:postgres "$REPLICA_WALDIR_CUSTOM"
  docker exec "$REPLICA" chmod 700 "$REPLICA_WALDIR_CUSTOM"

  run docker exec -u postgres "$REPLICA" bash -c "
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
      --ssh-key /tmp/id_rsa --ssh-user postgres \
      --insecure-ssh \
      --slot \
      --parallel 4 \
      --verbose"
  assert_success

  run  docker exec -u postgres "$REPLICA" test -L /var/lib/postgresql/data/pg_wal          # symlink
  assert_success
  run docker exec -u postgres "$REPLICA" bash -c "test \"\$(readlink -f /var/lib/postgresql/data/pg_wal)\" = \"$REPLICA_WALDIR_CUSTOM\""
  assert_success
  run docker exec -u postgres "$REPLICA" find "$REPLICA_WALDIR_CUSTOM" -type f -print -quit
  assert_success
  [[ -n "$output" ]]
}

#
# A-4 – custom --temp-waldir is removed afterwards
#
@test "temp-waldir directory is cleaned" {
  start_primary 15
  start_replica 15
  docker exec -u postgres "$REPLICA" mkdir -p /tmp/my_temp_wal

  run docker exec -u postgres "$REPLICA" bash -c "
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
      --ssh-key /tmp/id_rsa --ssh-user postgres \
      --insecure-ssh \
      --slot \
      --parallel 4 \
      --verbose"
  assert_success
  # directory exists but must be empty
  run docker exec -u postgres "$REPLICA" bash -c '[[ $(find /tmp/my_temp_wal -mindepth 1 | wc -l) -eq 0 ]]'
  assert_success
}

#
# A-5 – primary on non-default port 5444
#
@test "clone from primary on port 5444" {
  start_primary 15
  docker exec "$PRIMARY" bash -c "printf '\n%s\n' \"echo 'port = 5444' >> \$PGDATA/postgresql.conf\" >> /docker-entrypoint-initdb.d/init.sh"
  docker exec "$PRIMARY" bash -c "printf '\n%s\n' \"pg_ctl -D \\\"\$PGDATA\\\" restart\" >> /docker-entrypoint-initdb.d/init.sh"
  docker restart "$PRIMARY"
  for i in {1..3000}; do
    docker exec "$PRIMARY" pg_isready -U postgres -p 5444 -q && break
    sleep 1
  done
  docker exec "$PRIMARY" pg_isready -U postgres -p 5444 -q || {
    echo "[common.sh] Primary did not become ready in 30 s" >&2
    exit 1
  }
  start_replica 15

  run docker exec -u postgres "$REPLICA" bash -c "
    set -euo pipefail
    export PGPASSWORD=postgres
    pgclone --pghost pg-primary --pgport 5444 \
      --pguser postgres --primary-pgdata /var/lib/postgresql/data \
      --replica-pgdata /var/lib/postgresql/data \
      --ssh-key /tmp/id_rsa --ssh-user postgres \
      --insecure-ssh \
      --slot \
      --verbose"
  assert_success
}

#
# A-6 – PARALLEL=1 and PARALLEL=8 just complete successfully
#
@test "PARALLEL=1 works" {
  start_primary 15; start_replica 15
  run docker exec -u postgres "$REPLICA" bash -c "export PGPASSWORD=postgres; \
    pgclone --pghost pg-primary --pguser postgres \
      --primary-pgdata /var/lib/postgresql/data \
      --replica-pgdata /var/lib/postgresql/data \
      --ssh-key /tmp/id_rsa --ssh-user postgres \
      --insecure-ssh \
      --slot \
      --parallel 1 \
      --verbose"
  assert_success
}

@test "PARALLEL=8 works" {
  start_primary 15; start_replica 15
  run docker exec -u postgres "$REPLICA" bash -c "export PGPASSWORD=postgres; \
    pgclone --pghost pg-primary --pguser postgres \
      --primary-pgdata /var/lib/postgresql/data \
      --replica-pgdata /var/lib/postgresql/data \
      --ssh-key /tmp/id_rsa --ssh-user postgres \
      --insecure-ssh \
      --slot \
      --parallel 8 \
      --verbose"
  assert_success
}

#
# A-7 – Authentication via ~/.pgpass
#
@test "Authentication via ~/.pgpass" {
  local pgver=15
  build_image "$pgver"
  network_up
  start_primary "$pgver"
  start_replica  "$pgver"

  # prepare ~/.pgpass inside replica container and unset PGPASSWORD
  docker exec -u postgres "$REPLICA" bash -c '
    unset PGPASSWORD
    echo "pg-primary:5432:*:postgres:postgres" > ~/.pgpass
    chmod 600 ~/.pgpass
  '

  # Run pgclone without PGPASSWORD
  run docker exec -u postgres "$REPLICA" bash -c '
    set -euo pipefail
    pgclone \
      --pghost pg-primary \
      --pguser postgres \
      --primary-pgdata /var/lib/postgresql/data \
      --replica-pgdata /var/lib/postgresql/data \
      --ssh-key /tmp/id_rsa \
      --ssh-user postgres \
      --insecure-ssh \
      --parallel 2 \
      --slot \
      --verbose
  '
  assert_success
} 