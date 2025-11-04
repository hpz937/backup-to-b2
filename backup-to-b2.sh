#!/usr/bin/env bash
# backup-to-b2.sh
# Config-driven backups of files + docker volumes to Restic (Backblaze B2), plus DR helpers.

set -Eeuo pipefail

#####################################
#            CONFIG PATHS           #
#####################################
RESTIC_DIR="/etc/restic"
ENV_FILE="${RESTIC_DIR}/env"
FILES_LIST="${RESTIC_DIR}/files.list"       # one absolute path per line
VOLUMES_LIST="${RESTIC_DIR}/volumes.list"   # one docker volume name per line
EXCLUDES_FILE="${RESTIC_DIR}/excludes.txt"  # optional

# Staging & logs
STAGING_DIR="/var/backups/staging"
VOL_ARCHIVE_DIR="${STAGING_DIR}/volumes"
CONFIG_ARCHIVE_DIR="/var/backups/restic-config"
LOG_DIR="/var/log/backup"
LOCK_FILE="/var/lock/backup-to-b2.lock"

# Snapshot tag:
BACKUP_NAME="$(hostname)-$(date +%Y%m%d_%H%M%S)"

# Retention
KEEP_DAILY=7
KEEP_WEEKLY=4
KEEP_MONTHLY=12
KEEP_YEARLY=2

# Extra tags
EXTRA_TAGS="prod,server"

#####################################
#        AUTO-LOAD RESTIC ENV       #
#####################################
if [ -f "${ENV_FILE}" ]; then
  # shellcheck source=/dev/null
  source "${ENV_FILE}"
fi

#####################################
#           HELPER FUNCS            #
#####################################
log() { mkdir -p "$LOG_DIR"; echo "[$(date -Is)] $*" | tee -a "${LOG_DIR}/backup.log"; }
require_bin() { command -v "$1" >/dev/null 2>&1 || { echo "Missing required binary: $1"; exit 1; }; }
check_env() {
  : "${RESTIC_REPOSITORY:?Set in ${ENV_FILE} (e.g., b2:bucket:prefix)}"
  : "${RESTIC_PASSWORD:?Set in ${ENV_FILE}}"
  : "${B2_ACCOUNT_ID:?Set in ${ENV_FILE}}"
  : "${B2_ACCOUNT_KEY:?Set in ${ENV_FILE}}"
}
ensure_repo() { restic snapshots >/dev/null 2>&1 || { log "Initializing restic repo..."; restic init; }; }
make_dirs() { mkdir -p "$VOL_ARCHIVE_DIR" "$CONFIG_ARCHIVE_DIR"; }

# Read non-empty, non-comment lines
read_list() {
  local file="$1"
  [ -f "$file" ] || { echo ""; return 0; }
  grep -v '^\s*#' "$file" | sed '/^\s*$/d'
}

# ---------- INLINE DOCKER VOLUME BACKUP/RESTORE (FIXED) ----------
# Writes a tar.gz of <volume> to <dest_tar_gz>, handling absolute paths safely.
backup_docker_volume() {
  local volume="$1" dest_tar="$2"
  local dest_dir dest_base
  dest_dir="$(dirname "$dest_tar")"; dest_base="$(basename "$dest_tar")"
  [ -n "$dest_base" ] && [ "$dest_base" != "." ] && [ "$dest_base" != "/" ] || { echo "Invalid dest: $dest_tar"; return 1; }
  mkdir -p "$dest_dir"
  docker run --rm \
    --env DEST="$dest_base" \
    --mount "type=volume,source=${volume},target=/volume,readonly" \
    --mount "type=bind,src=${dest_dir},dst=/backup" \
    busybox sh -c 'set -e; tar czf "/backup/${DEST}" -C /volume .'
}

# Restores a tar.gz file into <volume>
restore_docker_volume() {
  local volume="$1" src_tar="$2"
  local src_dir src_base
  src_dir="$(dirname "$src_tar")"; src_base="$(basename "$src_tar")"
  [ -n "$src_base" ] && [ "$src_base" != "." ] && [ "$src_base" != "/" ] || { echo "Invalid src: $src_tar"; return 1; }
  docker volume inspect "$volume" >/dev/null 2>&1 || docker volume create "$volume" >/dev/null
  docker run --rm \
    --env SRC="$src_base" \
    --mount "type=volume,source=${volume},target=/volume" \
    --mount "type=bind,src=${src_dir},dst=/backup,readonly" \
    busybox sh -c 'set -e; cd /volume && tar xzf "/backup/${SRC}"'
}
# ---------------------------------------------------------------

# Restore a Docker volume by fetching its tar.gz from restic (snapshot or latest)
restore_volume_from_repo() {
  local volume="$1" snap="${2:-latest}"
  local rel_path="${VOL_ARCHIVE_DIR#/}/"    # ensure leading slash
  rel_path="/$(echo "$rel_path" | sed 's#^/*##')"  # normalize
  rel_path="${rel_path%/}/"                  # trailing slash
  rel_path="${rel_path}${volume}.tar.gz"

  require_bin restic; require_bin docker
  local tmpdir outfile; tmpdir="$(mktemp -d)"; outfile="${tmpdir}/${volume}.tar.gz"
  log "Fetching '${rel_path}' from snapshot '${snap}'..."
  if ! restic dump "${snap}" "${rel_path}" > "${outfile}"; then
    log "ERROR: ${rel_path} not found in snapshot ${snap}. Try: restic ls ${snap} | grep volumes/"
    rm -rf "${tmpdir}"; exit 1
  fi
  log "Restoring into Docker volume '${volume}'..."
  restore_docker_volume "${volume}" "${outfile}"
  log "Restore complete for volume '${volume}'."
  rm -rf "${tmpdir}"
}

# Build restic sources from files.list and staged volume tarballs
build_restic_sources() {
  RESTIC_SRC_ARGS=()
  local p
  while IFS= read -r p; do
    [ -e "$p" ] || { log "WARN: path not found (skipped): $p"; continue; }
    RESTIC_SRC_ARGS+=("$p")
  done < <(read_list "$FILES_LIST")

  if [ -d "$VOL_ARCHIVE_DIR" ] && compgen -G "${VOL_ARCHIVE_DIR}/*.tar.gz" >/dev/null; then
    RESTIC_SRC_ARGS+=("$VOL_ARCHIVE_DIR")
  fi

  [ "${#RESTIC_SRC_ARGS[@]}" -gt 0 ] || { echo "No sources to back up. Fill ${FILES_LIST} and/or ${VOLUMES_LIST}."; exit 1; }
}

dump_volumes() {
  local any=0
  require_bin docker
  while IFS= read -r vol; do
    [ -n "$vol" ] || continue
    any=1
    local out="${VOL_ARCHIVE_DIR}/${vol}.tar.gz"
    log "Dumping volume '${vol}' => ${out}"
    backup_docker_volume "$vol" "$out"
    log "Volume '${vol}' backed up."
  done < <(read_list "$VOLUMES_LIST" || true)
  [ "$any" -eq 1 ] || log "No Docker volumes listed in ${VOLUMES_LIST} — skipping."
}

do_backup() {
  check_env; require_bin restic; make_dirs
  dump_volumes
  ensure_repo
  build_restic_sources

  local tags="name=${BACKUP_NAME}"; [ -n "$EXTRA_TAGS" ] && tags="${tags},${EXTRA_TAGS}"

  log "Starting restic backup..."
  set +e
  if [ -f "$EXCLUDES_FILE" ]; then
    restic backup --tag "$tags" --exclude-file "$EXCLUDES_FILE" --one-file-system --verbose "${RESTIC_SRC_ARGS[@]}"
  else
    restic backup --tag "$tags" --one-file-system --verbose "${RESTIC_SRC_ARGS[@]}"
  fi
  local rc=$?; set -e
  [ $rc -eq 0 ] || { log "Restic backup FAILED ($rc)"; exit $rc; }
  log "Restic backup completed."

  log "Running restic check..."
  restic check --with-cache

  log "Applying prune policy (D=$KEEP_DAILY W=$KEEP_WEEKLY M=$KEEP_MONTHLY Y=$KEEP_YEARLY)..."
  restic forget --prune \
    --keep-daily "${KEEP_DAILY}" \
    --keep-weekly "${KEEP_WEEKLY}" \
    --keep-monthly "${KEEP_MONTHLY}" \
    --keep-yearly "${KEEP_YEARLY}"

  log "Backup run finished successfully."
}

clean_staging() { log "Cleaning ${STAGING_DIR}..."; rm -rf "${STAGING_DIR:?}/"* || true; }

# Create encrypted bundle of critical config + script; optionally upload
make_config_backup() {
  require_bin openssl
  make_dirs

  local script_path; script_path="$(readlink -f "$0")"
  local ts; ts="$(date +%Y%m%d_%H%M%S)"
  local tarball="${CONFIG_ARCHIVE_DIR}/restic-config-${ts}.tar.gz"
  local enc="${tarball}.enc"

  # Build the tarball (include env, lists, excludes, script, cron drop-in if exists)
  local cron_file="/etc/cron.d/backup-to-b2"
  log "Bundling config into ${tarball} ..."
  tar czf "${tarball}" \
    -C / \
    "$(realpath --relative-to=/ "$ENV_FILE")" \
    "$(realpath --relative-to=/ "$FILES_LIST" 2>/dev/null || true)" \
    "$(realpath --relative-to=/ "$VOLUMES_LIST" 2>/dev/null || true)" \
    "$(realpath --relative-to=/ "$EXCLUDES_FILE" 2>/dev/null || true)" \
    "$(realpath --relative-to=/ "$script_path")" \
    "$(realpath --relative-to=/ "$cron_file" 2>/dev/null || true)"

  # Encrypt it — use env CONFIG_ARCHIVE_PASSPHRASE if set, else prompt
  if [ -n "${CONFIG_ARCHIVE_PASSPHRASE:-}" ]; then
    log "Encrypting archive (env passphrase) -> ${enc}"
    openssl enc -aes-256-cbc -salt -pbkdf2 -pass env:CONFIG_ARCHIVE_PASSPHRASE -in "${tarball}" -out "${enc}"
  else
    log "Encrypting archive (will prompt for passphrase) -> ${enc}"
    openssl enc -aes-256-cbc -salt -pbkdf2 -in "${tarball}" -out "${enc}"
  fi
  shred -u "${tarball}" || rm -f "${tarball}"
  log "Encrypted config bundle written to ${enc}"

  # Optional upload priority 1: B2 CLI, if CONFIG_BACKUP_B2_URL=b2://bucket/prefix
  if [ -n "${CONFIG_BACKUP_B2_URL:-}" ] && command -v b2 >/dev/null 2>&1; then
    require_bin b2
    log "Uploading encrypted bundle to ${CONFIG_BACKUP_B2_URL}..."
    # Parse b2://bucket/prefix
    local url="${CONFIG_BACKUP_B2_URL#b2://}"
    local bucket="${url%%/*}" prefix="${url#*/}"
    b2 authorize-account
    b2 upload-file "$bucket" "${enc}" "${prefix%/}/$(basename "${enc}")"
    log "Upload via B2 CLI complete."
    return 0
  fi

  # Optional upload fallback: store inside your Restic repo
  if [ -n "${RESTIC_REPOSITORY:-}" ] && command -v restic >/dev/null 2>&1; then
    log "Backing up config bundle into restic repo..."
    restic backup --tag "config-bundle" "${enc}"
    log "Config bundle stored in restic."
  else
    log "No upload target configured; keep ${enc} safe (copy off-box)."
  fi
}

# ---------------------------------------------------------------
# Decrypt an encrypted config bundle (.tar.gz.enc)
# Usage: decrypt-config-backup <file.enc> [--restore]
# ---------------------------------------------------------------
decrypt_config_backup() {
  require_bin openssl
  local enc_file="$1"
  local mode="${2:-}"

  [ -f "$enc_file" ] || { echo "File not found: $enc_file"; exit 1; }

  local ts tmpdir outdir tarfile
  ts="$(date +%Y%m%d_%H%M%S)"
  tmpdir="/tmp/restic-config-restore-${ts}"
  outdir="${tmpdir}/decrypted"
  tarfile="${tmpdir}/bundle.tar.gz"

  mkdir -p "$outdir"

  log "Decrypting ${enc_file}..."
  if [ -n "${CONFIG_ARCHIVE_PASSPHRASE:-}" ]; then
    openssl enc -d -aes-256-cbc -pbkdf2 -pass env:CONFIG_ARCHIVE_PASSPHRASE -in "$enc_file" -out "$tarfile"
  else
    openssl enc -d -aes-256-cbc -pbkdf2 -in "$enc_file" -out "$tarfile"
  fi

  log "Extracting contents to ${outdir}..."
  tar xzf "$tarfile" -C "$outdir"
  rm -f "$tarfile"

  echo
  log "✅ Decrypted configuration extracted to: ${outdir}"
  echo
  tree "$outdir" 2>/dev/null || ls -R "$outdir"

  if [ "$mode" = "--restore" ]; then
    echo
    read -r -p "⚠️  This will overwrite files under /etc/restic and your backup script. Continue? [y/N] " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
      log "Restoring configuration to system paths..."
      sudo cp -v -r "$outdir/etc/restic/"* /etc/restic/ 2>/dev/null || true
      [ -f "$outdir/usr/local/bin/backup-to-b2.sh" ] && sudo cp -v "$outdir/usr/local/bin/backup-to-b2.sh" /usr/local/bin/
      [ -f "$outdir/etc/cron.d/backup-to-b2" ] && sudo cp -v "$outdir/etc/cron.d/backup-to-b2" /etc/cron.d/
      sudo chmod 600 /etc/restic/env
      sudo chmod +x /usr/local/bin/backup-to-b2.sh
      log "Configuration restored."
    else
      log "Skipped restoring; files remain in ${outdir}."
    fi
  fi
}

usage() {
  cat <<EOF
Usage: $0 [run|dry-run|clean|restore-volume <volume> <path/to/backup.tar.gz>|restore-volume-from-repo <volume> [snapshot|latest]|make-config-backup]

Commands:
  run                          Dump volumes listed in ${VOLUMES_LIST}, restic-backup files from ${FILES_LIST} + prune.
  dry-run                      Show intended sources (no repo writes).
  clean                        Remove staged volume tarballs.
  restore-volume               Restore a tar.gz archive into a Docker volume (no restic).
  restore-volume-from-repo     Restore a volume by pulling its tar.gz from the restic repo (snapshot id or 'latest').
  make-config-backup           Create encrypted tar of env/lists/excludes/script (+ optional upload).
  decrypt-config-backup <file.enc> [--restore]   Decrypt and optionally restore a config bundle


Config files:
  ${ENV_FILE}         # exports for RESTIC_REPOSITORY, RESTIC_PASSWORD, B2_ACCOUNT_ID, B2_ACCOUNT_KEY
  ${FILES_LIST}       # absolute paths (one per line), '#' for comments
  ${VOLUMES_LIST}     # docker volume names (one per line), '#' for comments
  ${EXCLUDES_FILE}    # optional restic exclude patterns

Environment (optional):
  CONFIG_ARCHIVE_PASSPHRASE   # passphrase for make-config-backup (otherwise prompted)
  CONFIG_BACKUP_B2_URL        # e.g. b2://my-bucket/config-bundles
EOF
}

dry_run() {
  make_dirs
  echo "Would dump volumes from ${VOLUMES_LIST}:"
  while IFS= read -r vol; do [ -n "$vol" ] && echo "  - ${vol} => ${VOL_ARCHIVE_DIR}/${vol}.tar.gz"; done < <(read_list "$VOLUMES_LIST" || true)
  echo
  echo "Would back up these file paths from ${FILES_LIST}:"
  while IFS= read -r p; do [ -n "$p" ] && echo "  - $p"; done < <(read_list "$FILES_LIST" || true)
  echo
  echo "Exclude file: ${EXCLUDES_FILE} $( [ -f "$EXCLUDES_FILE" ] && echo '(FOUND)' || echo '(not present)' )"
  echo "Prune policy: daily=${KEEP_DAILY}, weekly=${KEEP_WEEKLY}, monthly=${KEEP_MONTHLY}, yearly=${KEEP_YEARLY}"
}

main() {
  mkdir -p "$(dirname "$LOCK_FILE")"
  exec 9>"$LOCK_FILE" || { echo "Cannot open lock file: $LOCK_FILE"; exit 1; }
  flock -n 9 || { echo "Another backup is running. Exiting."; exit 1; }
  trap 'echo "Error on line $LINENO"; exit 1' ERR

  case "${1:-}" in
    run)                     do_backup ;;
    dry-run|--dry-run)       dry_run ;;
    clean)                   clean_staging ;;
    restore-volume)
      require_bin docker
      [[ $# -eq 3 ]] || { echo "Usage: $0 restore-volume <volume> <path/to/backup.tar.gz>"; exit 1; }
      restore_docker_volume "$2" "$3"
      log "Restore complete into volume: $2"
      ;;
    restore-volume-from-repo)
      [[ $# -ge 2 && $# -le 3 ]] || { echo "Usage: $0 restore-volume-from-repo <volume> [snapshot|latest]"; exit 1; }
      check_env; restore_volume_from_repo "$2" "${3:-latest}"
      ;;
    make-config-backup)
      make_config_backup
      ;;
    decrypt-config-backup)
      [[ $# -ge 2 && $# -le 3 ]] || { echo "Usage: $0 decrypt-config-backup <file.enc> [--restore]"; exit 1; }
      decrypt_config_backup "$2" "${3:-}"
      ;;
    *) usage ;;
  esac
}

main "$@"

