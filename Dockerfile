ARG PG_MAJOR=15
FROM postgres:${PG_MAJOR}

RUN apt-get update && apt-get install -y rsync openssh-server && \
    mkdir -p /run/sshd /root/.ssh

COPY pg_hba.conf /pg_hba.conf
COPY postgresql.conf /postgresql.conf
COPY init.sh /docker-entrypoint-initdb.d/init.sh
RUN chmod +x /docker-entrypoint-initdb.d/init.sh

CMD ["bash", "-c", "\
  service ssh start && \
  if [[ \"$ROLE\" == \"primary\" ]]; then \
    rm -rf /var/lib/postgresql/data/* && \
    chmod 700 /var/lib/postgresql && \
    echo '[primary] Starting PostgreSQL...'; \
    exec docker-entrypoint.sh postgres; \
  else \
    echo '[replica] PostgreSQL is disabled, waiting...'; \
    cp /id_rsa /tmp/id_rsa && \
    chown postgres:postgres /tmp/id_rsa && \
    chmod 0600 /tmp/id_rsa && \
    chown postgres:postgres /tmp/id_rsa && \
    tail -f /dev/null; \
  fi"]
