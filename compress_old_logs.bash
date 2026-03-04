#!/usr/bin/env bash
set -Eeuo pipefail

#############################################
# CONFIG
#############################################

LOGS_ROOT="/home/heiro/cre-logs"
ARCHIVE_ROOT="/home/heiro/cre-logs-archive"
RUN_LOG="/var/log/cre-logs-compress.log"

#############################################
# INTERNALS
#############################################

LOCK_FILE="/var/run/cre-logs-compress.lock"
DATE_REGEX='[0-9]{4}-[0-9]{2}-[0-9]{2}'
THRESHOLD_DATE="$(date -d "2 months ago" +%F)"

FOLDERS=(
  "apsara-costumer"
  "billing"
  "cloud-adapter"
  "customer"
  "flyway"
  "ingateway"
  "component"
)

log() { echo "[$(date '+%F %T')] $*" | tee -a "$RUN_LOG"; }
trap 'log "ERROR at line $LINENO: $BASH_COMMAND"' ERR

require_cmd() { command -v "$1" >/dev/null 2>&1 || { log "Missing command: $1"; exit 1; }; }

acquire_lock() {
  exec 9>"$LOCK_FILE"
  flock -n 9 || { log "Another instance is running (lock: $LOCK_FILE)"; exit 1; }
}

init() {
  require_cmd find
  require_cmd sort
  require_cmd grep
  require_cmd gzip
  require_cmd date
  require_cmd flock

  [[ -d "$LOGS_ROOT" ]] || { log "LOGS_ROOT not found: $LOGS_ROOT"; exit 1; }
  mkdir -p "$ARCHIVE_ROOT"
  touch "$RUN_LOG"
}

# file_date <= threshold_date
is_date_older_or_equal() {
  local d1="$1" d2="$2"
  [[ "$d1" < "$d2" || "$d1" == "$d2" ]]
}

resolve_folder_dir() {
  local folder="$1"
  find "$LOGS_ROOT" -maxdepth 1 -mindepth 1 -type d -iname "$folder" -print -quit
}

compress_folder() {
  local folder="$1" src_dir="$2"
  local archive_dir="${ARCHIVE_ROOT}/${folder}"
  mkdir -p "$archive_dir"

  log ""
  log "Processing folder: $folder (resolved: $src_dir)"

  local files=()
  mapfile -t files < <( (find "$src_dir" -maxdepth 1 -type f -iname "*.log" -print | sort) || true )

  if (( ${#files[@]} == 0 )); then
    log "  No .log files found"
    return 0
  fi

  local compressed_count=0

  for f in "${files[@]}"; do
    local base file_date out_gz
    base="$(basename "$f")"
    file_date="$(echo "$base" | grep -oE "$DATE_REGEX" || true)"
    [[ -n "$file_date" ]] || continue

    if is_date_older_or_equal "$file_date" "$THRESHOLD_DATE"; then
      out_gz="${archive_dir}/${base}.gz"
      [[ -f "$out_gz" ]] && continue

      gzip -c "$f" > "$out_gz"
      log "  compressed: $base -> $(basename "$out_gz")"
      ((++compressed_count))
    fi
  done

  log "  Compressed $compressed_count file(s)"
}

main() {
  acquire_lock
  init

  log "============================================================"
  log "Compression job started"
  log "LOGS_ROOT      = $LOGS_ROOT"
  log "ARCHIVE_ROOT   = $ARCHIVE_ROOT"
  log "THRESHOLD_DATE = $THRESHOLD_DATE (inclusive)"
  log "============================================================"

  for folder in "${FOLDERS[@]}"; do
    local dir
    dir="$(resolve_folder_dir "$folder" || true)"
    if [[ -z "${dir:-}" || ! -d "$dir" ]]; then
      log "Folder missing, skipping: ${LOGS_ROOT}/${folder}"
      continue
    fi
    compress_folder "$folder" "$dir"
  done

  log "============================================================"
  log "Compression job finished"
  log "============================================================"
}

main "$@"