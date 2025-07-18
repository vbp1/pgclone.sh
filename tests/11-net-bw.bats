#!/usr/bin/env bats
# Scenario N-1 – verify --limit-net-bw splits bandwidth across workers

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'
load 'common.sh'

setup()   { build_image 15; network_up; }
teardown() { stop_test_env; network_rm; }

@test "--limit-net-bw splits evenly between rsync workers" {
  start_primary 15
  start_replica 15

  # Run pgclone with known params. Keep dataset tiny (fresh cluster) so job finishes quickly.
  run docker exec -u postgres "$REPLICA" bash -c "export PGPASSWORD=postgres; \
    pgclone --pghost pg-primary --pguser postgres \
      --primary-pgdata /var/lib/postgresql/data \
      --replica-pgdata /var/lib/postgresql/data \
      --replica-waldir /var/lib/postgresql/data/pg_wal \
      --temp-waldir /tmp/pg_wal \
      --ssh-key /tmp/id_rsa --ssh-user postgres \
      --insecure-ssh \
      --slot \
      --parallel 4 \
      --limit-net-bw 400K \
      --verbose"
  assert_success

  # Extract computed per-worker limit (400K total / 4 workers = 100 KB/s)
  per=$(echo "$output" | grep -oE 'per rsync=[0-9]+' | awk -F= '{print $2}')
  assert_equal "$per" "100"

  # Extract aggregated download speed line and verify it does not exceed ~400 KB/s (+10 % tolerance)
  speed_kb=$(echo "$output" | grep -Eo 'sent .* \([0-9]+(\.[0-9]+)? [KMG]B/sec\)' | tail -n1 | awk -F'[ (]' '{print $(NF-1)" "$(NF)}' | awk '{val=$1; unit=$2; if(unit~/KB/)print val; else if(unit~/MB/)print val*1024; else if(unit~/GB/)print val*1024*1024;}')
  [ -n "$speed_kb" ] || { echo "speed not found"; false; }
  max_kb=$(( 400 + 40 ))   # 400 KB/s limit +10 % tolerance
  (( $(printf '%.0f' "$speed_kb") <= max_kb ))
}
