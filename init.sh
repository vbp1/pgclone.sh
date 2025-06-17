#!/bin/bash

cp /pg_hba.conf "$PGDATA/pg_hba.conf"
chmod 0600 "$PGDATA/pg_hba.conf"
chown postgres:postgres "$PGDATA/pg_hba.conf"

cp /postgresql.conf "$PGDATA/postgresql.conf"
chmod 0600 "$PGDATA/postgresql.conf"
chown postgres:postgres "$PGDATA/postgresql.conf"

pg_ctl -D "$PGDATA" restart