# mysql-backup-to-r2

English | [한국어](README.ko.md)

An installation script that automatically backs up **MySQL/MariaDB**
databases\
and uploads them to **Cloudflare R2** storage.

- Stores `.sql.gz` + `.sha256` files locally with timestamp
- Keeps only the latest N sets (user-defined)
- Always uploads to the same object key (`latest.sql.gz`) on R2 → only
  the last backup is retained
- Automatically registers a cron job (runs daily at HH:MM entered by
  the user, in server timezone)
- Handles AWS CLI + R2 profile setup automatically

---

## Requirements

- Linux server (tested: Rocky/Alma/RHEL, Ubuntu, Debian, Alpine)
- Root privileges (sudo)
- Cloudflare R2 account and Access Key
- MySQL/MariaDB client (`mysql`, `mysqldump`/`mariadb-dump`)

---

## Installation

```bash
git clone https://github.com/yourname/mysql-backup-to-r2.git
cd mysql-backup-to-r2
chmod +x install_mysql_backup.sh
sudo ./install_mysql_backup.sh
```

The script will guide you through:

1.  Installing and configuring AWS CLI (entering Cloudflare R2 Access
    Key)
2.  Testing R2 connection
3.  Setting MySQL credentials (`/root/.my.cnf`)
4.  Entering local retention count (MAX_BACKUPS)
5.  Entering backup schedule time (HH:MM in server timezone)
6.  Creating and registering the backup script
    (`/usr/local/bin/mysql-backup.sh`)

---

## Manual Execution

```bash
sudo /usr/local/bin/mysql-backup.sh
```

Backups will be stored under `/root/backup`:

    /root/backup/
    ├── server1-mysqldump-20250824-0600.sql.gz
    ├── server1-mysqldump-20250824-0600.sql.gz.sha256
    ...

---

## How it Works

- **Local retention**
  - Each backup produces `.sql.gz` and `.sha256`
  - Keeps only the most recent `MAX_BACKUPS` sets
  - Older files are automatically deleted
- **R2 upload**
  - Always uploaded to the same key (`mysql/<host>/latest.sql.gz`)
  - Old file is overwritten → only the latest backup remains
- **Cron**
  - Runs daily at HH:MM (server timezone)

---

## MySQL Credentials (`/root/.my.cnf`)

```ini
[client]
user=root
password='P@ssw0rd#2025!'
host=127.0.0.1
```

- Password is always wrapped in quotes for safety.\
- Special characters (`#`, `;`, spaces, etc.) are handled properly.

---

## Logs

```bash
tail -n 100 /var/log/mysql-backup.log
```

---

## Restore

```bash
# verify checksum
sha256sum -c /root/backup/server1-mysqldump-20250824-0600.sql.gz.sha256

# restore
gunzip -c /root/backup/server1-mysqldump-20250824-0600.sql.gz | mysql --defaults-file=/root/.my.cnf
```

---

## TODO / Ideas

- [ ] Telegram/Slack notifications (success/failure)
- [ ] Retry with backoff on upload failure
- [ ] Backup from read replica (reduce load on production DB)
- [ ] Docker image packaging

---

## License

MIT License
