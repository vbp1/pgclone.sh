#!/usr/bin/env bats
# Scenarios E-1 … E-3 – abrupt termination & watchdog

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'
load '../common.sh'

setup()   { network_up; }
teardown() { stop_cluster; check_clean; }

build_image 15

#
# E-1 – kill pgclone mid-rsync on replica
#
@test "watchdog cleans up after pgclone forced kill" {
  start_primary 15; start_replica 15

  # start clone in bg, capture pid
  docker exec "$REPLICA" bash -c "
    export PGPASSWORD=postgres
    pgclone --pghost pg-primary --pguser postgres --primary-pgdata /var/lib/postgresql/data --replica-pgdata /var/lib/postgresql/data --ssh-key /root/.ssh/id_rsa --ssh-user root" &
  CLONE_HOST_PID=$!

  sleep 5   # reach rsync stage
  kill -9 "$CLONE_HOST_PID"
  wait || true                             # we expect non-0

  # inside container no rsync/pg_receivewal processes should remain
  docker exec "$REPLICA" bash -c '! pgrep -f "(pg_receivewal|rsync.*--daemon)"'
}

#
# E-2 – kill ssh tunnel (rsyncd) on primary
#
@test "rsyncd watchdog stops when ssh tunnel killed" {
  start_primary 15; start_replica 15

  docker exec "$REPLICA" bash -c "
    export PGPASSWORD=postgres
    pgclone --pghost pg-primary --pguser postgres --primary-pgdata /var/lib/postgresql/data --replica-pgdata /var/lib/postgresql/data --ssh-key /root/.ssh/id_rsa --ssh-user root" &
  sleep 7
  # kill ssh PID (there is only one root@pg-primary ssh in replica)
  SSH_PID=$(docker exec "$REPLICA" pgrep -f 'ssh .* pg-primary')
  docker exec "$REPLICA" kill -9 "$SSH_PID"
  wait || true
  docker exec "$REPLICA" bash -c '! pgrep -f "rsync.*--daemon"'
}

#
# E-3 – network outage during pg_receivewal
#
@test "network loss triggers timeout, all processes gone" {
  start_primary 15; start_replica 15

  # use iptables inside replica to drop traffic after 3 s
  docker exec "$REPLICA" bash -c "apt-get update -qq && apt-get install -y iptables > /dev/null"

  docker exec "$REPLICA" bash -c "
    (sleep 3 && iptables -A OUTPUT -d pg-primary -j DROP) & 
    export PGPASSWORD=postgres
    pgclone --pghost pg-primary --pguser postgres --primary-pgdata /var/lib/postgresql/data --replica-pgdata /var/lib/postgresql/data --ssh-key /root/.ssh/id_rsa --ssh-user root" || true

  docker exec "$REPLICA" bash -c '! pgrep -f "(pg_receivewal|ssh .* pg-primary)"'
}
