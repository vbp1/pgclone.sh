#!/usr/bin/env bats
# Covers scenarios A-2 … A-7 (parameters & variants)

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'
load 'common.sh'

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
  docker exec -i "$PRIMARY" bash -eux - <<'SH'
    mkdir -p /tblspc1 /tblspc2
    chown postgres:postgres /tblspc1 /tblspc2
SH
   run_psql pg-primary 5432 "CREATE TABLESPACE t1 LOCATION '/tblspc1';"
   run_psql pg-primary 5432 "CREATE TABLESPACE t2 LOCATION '/tblspc2';"
   run_psql pg-primary 5432 "CREATE TABLE t_in_t1(id int) TABLESPACE t1;"
   run_psql pg-primary 5432 "CREATE TABLE t_in_t2(id int) TABLESPACE t2;"
   run_psql pg-primary 5432 "INSERT INTO t_in_t1 SELECT generate_series(1, 10000);"
   run_psql pg-primary 5432 "INSERT INTO t_in_t2 SELECT generate_series(10001, 20000);"

  docker exec -i "$REPLICA" bash -eux - <<'SH'
    mkdir -p /tblspc1 /tblspc2
    chown postgres:postgres /tblspc1 /tblspc2
SH

  run_pgclone

  # verify tablespaces copied
  docker exec -u postgres "$REPLICA" test -d /tblspc1
  docker exec -u postgres "$REPLICA" test -d /tblspc2

  for spc in tblspc1 tblspc2; do
    primary_hash=$(docker exec -u postgres "$PRIMARY" find "/$spc" -type f -exec md5sum {} + | sort | md5sum)
    replica_hash=$(docker exec -u postgres "$REPLICA" find "/$spc" -type f -exec md5sum {} + | sort | md5sum)
    echo "primary_hash=$primary_hash, replica_hash=$replica_hash"
    [[ "$primary_hash" = "$replica_hash" ]]
  done


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
}

#
# A-3 – custom --replica-waldir
#
@test "clone with custom replica waldir" {
  build_image 15
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
      --parallel 4 \
      --verbose"
  assert_success
  docker exec -u postgres "$REPLICA" test -L /var/lib/postgresql/data/pg_wal          # symlink
  docker exec -u postgres "$REPLICA" bash -c "test \"\$(readlink -f /var/lib/postgresql/data/pg_wal)\" = \"$REPLICA_WALDIR_CUSTOM\""
  docker exec -u postgres "$REPLICA" find "$REPLICA_WALDIR_CUSTOM" -type f -print -quit | grep -q .
}

#
# A-4 – custom --temp-waldir is removed afterwards
#
@test "temp-waldir directory is cleaned" {
  build_image 15
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
      --parallel 4 \
      --verbose"
  assert_success
  # directory exists but must be empty
  docker exec -u postgres "$REPLICA" bash -c '[[ $(find /tmp/my_temp_wal -mindepth 1 | wc -l) -eq 0 ]]'
}

#
# A-5 – primary on non-default port 5444
#
@test "clone from primary on port 5444" {
  build_image 15
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
      --verbose"
  assert_success
}

#
# A-6 – PARALLEL=1 and PARALLEL=8 just complete successfully
#
@test "PARALLEL=1 works" {
  build_image 15; start_primary 15; start_replica 15
  run docker exec -u postgres "$REPLICA" bash -c "export PGPASSWORD=postgres; \
    pgclone --pghost pg-primary --pguser postgres \
      --primary-pgdata /var/lib/postgresql/data \
      --replica-pgdata /var/lib/postgresql/data \
      --parallel 1 \
      --ssh-key /tmp/id_rsa --ssh-user postgres \
      --verbose"
  assert_success
}

@test "PARALLEL=8 works" {
  build_image 15; start_primary 15; start_replica 15
  run docker exec -u postgres "$REPLICA" bash -c "export PGPASSWORD=postgres; \
    pgclone --pghost pg-primary --pguser postgres \
      --primary-pgdata /var/lib/postgresql/data \
      --replica-pgdata /var/lib/postgresql/data \
      --parallel 8 \
      --ssh-key /tmp/id_rsa --ssh-user postgres \
      --verbose"
  assert_success
}

