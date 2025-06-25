#!/bin/bash

cp /pg_hba.conf "$PGDATA/pg_hba.conf"
chmod 0600 "$PGDATA/pg_hba.conf"
chown postgres:postgres "$PGDATA/pg_hba.conf"

cp /postgresql.conf "$PGDATA/postgresql.conf"
chmod 0600 "$PGDATA/postgresql.conf"
chown postgres:postgres "$PGDATA/postgresql.conf"

mkdir -p /var/lib/postgresql/.ssh
cp /tmp/test-key.pub /var/lib/postgresql/.ssh/authorized_keys
chown postgres:postgres /var/lib/postgresql/.ssh/authorized_keys
chmod 700 /var/lib/postgresql/.ssh
chmod 600 /var/lib/postgresql/.ssh/authorized_keys

pg_ctl -D "$PGDATA" restart

touch "$PGDATA"/ready
