# pgclone

**pgclone** is a Bash utility for creating a physical replica of PostgreSQL 15+ via `rsync` and streaming WAL. It features parallel file synchronization.

---

## Features

- **Physical replication only** (PostgreSQL 15+)
- No replication slot needed for `pg_receivewal`
- **Parallel database sync via rsync+rsyncd**
- Streaming WAL with `pg_receivewal`
- Automated testing/demo via Docker (`docker-test.sh`)

---

## Requirements

- Bash 4+
- PostgreSQL 15 or newer (no `pg_basebackup` required)
- Tools: `psql`, `pg_receivewal`, `rsync`, `ssh`, `awk`, `find`, `du`, `split`, `sha256sum`, `od`
- SSH key-based access to the primary server (no password prompt)
- Sufficient privileges (root or postgres) on both servers

---

## Installation

1. **Get the script:**
    ```bash
    cd /path/to/dir
    curl https://raw.githubusercontent.com/vbp1/pgclone.sh/refs/heads/main/pgclone
    chmod +x ./pgclone
    ```

2. **Adjust variables/configuration** as needed for your environment.

---

## Usage Example

```bash
export PGPASSWORD=your_pg_password

./pgclone   
    --pghost <primary_host>  \
    --pgport 5432            \
    --pguser postgres        \
    --primary-pgdata /var/lib/postgresql/data  \
    --replica-pgdata /var/lib/postgresql/data  \
    --temp-waldir /tmp/pg_wal \
    --ssh-key /path/to/id_rsa \
    --ssh-user root \
    --parallel 4    \
    --verbose
```

**Parameters:**
- `--pghost`           — address of the primary server
- `--pguser`           — user with replication and backup privileges
- `--primary-pgdata`   — path to PGDATA on the primary
- `--replica-pgdata`   — path to PGDATA on the replica
- `--ssh-key`          — private SSH key
- `--ssh-user`         — SSH user
- `--parallel`         — number of parallel rsync jobs
- `--temp-waldir`      - temporary directory for storing WAL files streamed by `pg_receivewal` during the clone.  After the copy is finished, all files from this directory are moved to the replica's `pg_wal` directory. This ensures no WAL segment is lost or overwritten during the initial sync.


**Note:**  
You must set `PGPASSWORD` in the environment for database authentication.

---

## Quick Demo/Test via Docker

A sample script [`docker-test.sh`](./docker-test.sh) is provided to test the workflow in a self-contained Docker environment with two containers: `primary` and `replica`.

### To run the test:

```bash
git clone https://github.com/vbp1/pgclone.sh 
cd pgclone.sh
./docker-test.sh
```
This will:
- Build a test Docker image
- Launch primary and replica containers
- Run `pgclone` from the replica to clone from primary
- Show results (e.g., PG_VERSION on the replica)
- Optionally configure and start the replica in standby mode

> After the test, you can remove the containers interactively.

---
