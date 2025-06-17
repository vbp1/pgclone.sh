FROM postgres:15

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
    mkdir -p /root/.ssh && \
    cp /tmp/test-key.pub /root/.ssh/authorized_keys && \
    chown root:root /root/.ssh/authorized_keys && \
    chmod 700 /root/.ssh && chmod 600 /root/.ssh/authorized_keys && \
    echo '[primary] Starting PostgreSQL...'; \
    exec docker-entrypoint.sh postgres; \
  else \
    echo '[replica] PostgreSQL is disabled, waiting...'; \
    tail -f /dev/null; \
  fi"]
