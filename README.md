# Restic + Docker Volume Backup to Backblaze B2

A configurable, self-contained Bash utility to back up both **regular files** and **Docker volumes** using **Restic** to **Backblaze B2** cloud storage.

It supports:
- File and directory backups
- Docker volume exports as `.tar.gz`
- Encrypted configuration bundles for disaster recovery
- Automatic pruning and integrity checks
- Cron-based scheduling
- One-command restore (for both files and volumes)

---

## Features

- **Config-driven:** all backup targets defined in `/etc/restic/` files — no script edits required.  
- **Docker-aware:** automatically dumps volumes via temporary BusyBox containers.  
- **Encrypted config backup:** one-command bundle of env, config, and cron.  
- **Disaster-ready:** restore the entire backup environment on a new host in minutes.  
- **Locking + logging:** safe for cron usage; no overlapping runs.  
- **Backblaze B2 native:** works with B2 buckets via Restic’s B2 backend.

---

## Directory Structure

| Path | Purpose |
|------|----------|
| `/usr/local/bin/backup-to-b2.sh` | Main backup script |
| `/etc/restic/env` | Restic + B2 credentials |
| `/etc/restic/files.list` | Files/directories to back up |
| `/etc/restic/volumes.list` | Docker volumes to back up |
| `/etc/restic/excludes.txt` | Optional Restic exclude patterns |
| `/etc/cron.d/backup-to-b2` | Cron job definition |
| `/var/backups/staging/volumes/` | Temp tarballs of Docker volumes |
| `/var/backups/restic-config/` | Encrypted config bundle archives |
| `/var/log/backup/` | Backup logs |

---

## Installation

1. **Copy script**
   ```bash
   sudo cp backup-to-b2.sh /usr/local/bin/
   sudo chmod +x /usr/local/bin/backup-to-b2.sh
   ```

2. **Create `/etc/restic/` directory**

   ```bash
   sudo mkdir -p /etc/restic
   sudo chmod 700 /etc/restic
   ```

3. **Edit configuration files**

   `/etc/restic/env`

   ```bash
   export RESTIC_REPOSITORY="b2:my-bucket:servers/$(hostname)"
   export RESTIC_PASSWORD="super-long-passphrase"
   export B2_ACCOUNT_ID="001234567890"
   export B2_ACCOUNT_KEY="your-b2-app-key"
   ```

   `/etc/restic/files.list`

   ```
   /etc
   /home
   /var/www
   ```

   `/etc/restic/volumes.list`

   ```
   mariadb_data
   redis_cache
   ```

   `/etc/restic/excludes.txt`

   ```
   *.tmp
   **/node_modules
   *.iso
   /var/www/cache
   ```

4. **Create cron schedule**

   `/etc/cron.d/backup-to-b2`

   ```bash
   SHELL=/bin/bash
   PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
   MAILTO=""

   30 2 * * * root /usr/local/bin/backup-to-b2.sh run >> /var/log/backup/cron.log 2>&1
   ```

---

## Usage

### Run backup manually

```bash
sudo /usr/local/bin/backup-to-b2.sh run
```

### Dry run (show what would be backed up)

```bash
sudo /usr/local/bin/backup-to-b2.sh dry-run
```

### Clean staging (remove old tarballs)

```bash
sudo /usr/local/bin/backup-to-b2.sh clean
```

### Create encrypted config backup

```bash
sudo /usr/local/bin/backup-to-b2.sh make-config-backup
```

Creates `/var/backups/restic-config/restic-config-YYYYMMDD_HHMMSS.tar.gz.enc`

### Decrypt config backup

```bash
sudo /usr/local/bin/backup-to-b2.sh decrypt-config-backup /path/to/restic-config-2025XXXX.tar.gz.enc
```

Add `--restore` to overwrite `/etc/restic`, cron, and script:

```bash
sudo /usr/local/bin/backup-to-b2.sh decrypt-config-backup /path/to/file.enc --restore
```

### Restore Docker volume from latest snapshot

```bash
sudo /usr/local/bin/backup-to-b2.sh restore-volume-from-repo mariadb_data latest
```

### Restore plain tarball into volume

```bash
sudo /usr/local/bin/backup-to-b2.sh restore-volume mariadb_data /var/backups/staging/volumes/mariadb_data.tar.gz
```

---

## Environment Variables

| Variable                    | Description                                              |
| --------------------------- | -------------------------------------------------------- |
| `RESTIC_REPOSITORY`         | B2 repo URL (`b2:bucket:prefix`)                         |
| `RESTIC_PASSWORD`           | Restic encryption password                               |
| `B2_ACCOUNT_ID`             | B2 application key ID                                    |
| `B2_ACCOUNT_KEY`            | B2 application key                                       |
| `CONFIG_ARCHIVE_PASSPHRASE` | Passphrase for encrypt/decrypt config bundles (optional) |
| `CONFIG_BACKUP_B2_URL`      | Upload target for config bundles (`b2://bucket/prefix`)  |

---

## Restore a fresh system

### 1: Install dependencies

```bash
sudo apt install -y docker.io restic busybox openssl
```

### 2: Decrypt your saved config

```bash
openssl enc -d -aes-256-cbc -pbkdf2 -in restic-config-2025XXXX.tar.gz.enc -out restic-config.tar.gz
sudo tar xzf restic-config.tar.gz -C /
```

### 3: Fix permissions

```bash
sudo chmod 600 /etc/restic/env
sudo chmod +x /usr/local/bin/backup-to-b2.sh
```

### 4: Verify access

```bash
source /etc/restic/env
restic snapshots
```

### 5: Restore data

* Files:

  ```bash
  restic restore latest --target /restore
  ```
* Docker volume:

  ```bash
  ./backup-to-b2.sh restore-volume-from-repo mariadb_data latest
  ```

---

## Security Best Practices

* Keep `/etc/restic/env` `chmod 600` and owned by root.
* Store your **Restic password** offline; it cannot be recovered.
* Use unique Backblaze B2 **Application Keys** per server.
* Periodically rotate your keys and regenerate `/etc/restic/env`.
* Store your encrypted config bundle (`.enc`) offsite or in your B2 bucket under a separate prefix.

---

## Logs & Diagnostics

| File                          | Purpose                     |
| ----------------------------- | --------------------------- |
| `/var/log/backup/backup.log`  | Detailed script log         |
| `/var/log/backup/cron.log`    | Cron job output             |
| `/var/lock/backup-to-b2.lock` | Prevents concurrent backups |

View last backup:

```bash
sudo tail -n 50 /var/log/backup/backup.log
```

---

## Tips

* Test restores regularly using `--target /tmp/test-restore`.
* Run `restic check` monthly to verify repo integrity.
* You can initialize multiple hosts in the same B2 bucket with unique prefixes.
* To start over with a clean repo:

  ```bash
  b2 sync --delete /tmp/empty b2://my-bucket/servers/hostname
  restic init
  ```

---

## License

MIT © 2025
