#!/usr/bin/env bats
# Locale coverage tests – ensure pgclone works correctly under different locales
# Uses minimal dataset (no external tablespaces)

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'
load 'common.sh'

setup()   { build_image 15; network_up; }
teardown() { stop_test_env; network_rm; }

# Helper: run pgclone under given locale and return combined output
# $1 – locale string, e.g. C, en_US.UTF-8, ru_RU.UTF-8
run_pgclone_locale() {
  local locale=$1
  # ensure locale exists in the replica container
  docker exec "$REPLICA" bash -c "locale -a | grep -qx \"$locale\" || localedef -i ${locale%%.*} -f UTF-8 $locale || true"

  run docker exec -u postgres "$REPLICA" bash -c "set -euo pipefail; \
    export LANG=$locale; export LC_ALL=$locale; export PGPASSWORD=postgres; \
    pgclone --pghost pg-primary --pguser postgres \
       --primary-pgdata /var/lib/postgresql/data \
       --replica-pgdata /var/lib/postgresql/data \
       --ssh-key /tmp/id_rsa --ssh-user postgres \
       --insecure-ssh \
       --slot \
       --parallel 1 \
       --progress=bar \
       --verbose"
}

# convert human-readable size like 3.4TB / 50.1MB to bytes (bash)
bytes_to_int() {
  local s=${1,,}
  s=${s// /}; s=${s//,/./};
  local unit=${s: -2}; local num=${s::-2}
  local mul=1
  case $unit in
    kb) mul=1024;;
    mb) mul=$((1024**2));;
    gb) mul=$((1024**3));;
    tb) mul=$((1024**4));;
    pb) mul=$((1024**5));;
    b)  mul=1; num=${s::-1};;
  esac
  printf '%d' "$(awk -v n="$num" -v m=$mul 'BEGIN{printf "%.0f", n*m}')"
}

run_locale_case() {
  local loc=$1
  start_primary 15; start_replica 15

  # prepare data on primary
  run_psql pg-primary 5432 "CREATE TABLE IF NOT EXISTS t_locale(id int);"
  run_psql pg-primary 5432 "TRUNCATE t_locale;"
  run_psql pg-primary 5432 "INSERT INTO t_locale SELECT generate_series(1,100);"

  run_pgclone_locale "$loc"
  assert_success

  # extract progress total bytes (100% line) and summary Total bytes received
  local prog_line summary_line
  prog_line=$(echo "$output" | grep -E "\] 100 % +\(" | tail -1)
  summary_line=$(echo "$output" | grep -E "Total bytes received:" | tail -1)

  [[ -n $prog_line ]] || fail "progress line not found for locale $loc"
  [[ -n $summary_line ]] || fail "summary line not found for locale $loc"

  local prog_bytes summary_bytes diff
  prog_bytes=$(echo "$prog_line" | sed -E 's/.*\] 100 % \(([0-9.,A-Za-z]+) \/.*/\1/')
  summary_bytes=$(echo "$summary_line" | awk '{print $(NF)}')

  prog_int=$(bytes_to_int "$prog_bytes")
  summ_int=$(bytes_to_int "$summary_bytes")

  diff=$(( prog_int - summ_int ))
  diff=${diff#-}   # abs
  # allow 1% difference (protocol overhead)
  thresh=$(( prog_int / 100 ))
  if (( diff > thresh )); then
    echo "Progress bytes=$prog_int summary bytes=$summ_int diff=$diff >1%" >&2
    return 1
  fi

  # ensure Postgres on replica starts and SELECT works
  start_pg_on_replica
  run docker exec -u postgres "$REPLICA" psql -Atc "SELECT 1;"
  assert_success
  assert_output "1"

  # verify data present on replica
  run docker exec -u postgres "$REPLICA" psql -Atc "SELECT sum(id) FROM t_locale;"
  assert_success
  assert_output "5050"

  stop_test_env; network_rm
}

@test "locale C works" {
  run_locale_case C
}

@test "locale en_US.UTF-8 works" {
  run_locale_case en_US.UTF-8
}

@test "locale ru_RU.UTF-8 works" {
  run_locale_case ru_RU.UTF-8
} 