#!/usr/bin/env bash
set -Eeuo pipefail
#kheiro
#############################################
# CONFIG
#############################################

LOGS_ROOT="/home/heiro/cre-logs"

# Failed uploads go here
QUARANTINE_ROOT="/home/heiro/cre-logs-quarantine"

OSS_DEST_ROOT="oss://images/logs"
OSSUTIL_BIN="/usr/bin/ossutil"
OSSUTIL_CONFIG="${HOME}/.ossutilconfig"

RUN_LOG="/var/log/cre-logs-upload-delete.log"
DRY_RUN=0

#############################################
# INTERNALS
#############################################

LOCK_FILE="/var/run/cre-logs-upload-delete.lock"
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
  require_cmd date
  require_cmd rm
  require_cmd mv
  require_cmd mkdir
  require_cmd flock

  [[ -d "$LOGS_ROOT" ]] || { log "LOGS_ROOT not found: $LOGS_ROOT"; exit 1; }
  [[ -x "$OSSUTIL_BIN" ]] || { log "ossutil not executable or not found: $OSSUTIL_BIN"; exit 1; }
  [[ -f "$OSSUTIL_CONFIG" ]] || { log "ossutil config not found: $OSSUTIL_CONFIG"; exit 1; }

  mkdir -p "$QUARANTINE_ROOT"
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

quarantine_file() {
  local folder="$1" file_path="$2"

  local qdir="${QUARANTINE_ROOT}/${folder}"
  mkdir -p "$qdir"

  local base ts dest
  base="$(basename "$file_path")"
  ts="$(date +%Y%m%d-%H%M%S)"
  dest="${qdir}/${base}"

  # Avoid overwrite
  if [[ -e "$dest" ]]; then
    dest="${qdir}/${base}.failed-${ts}"
  fi

  if (( DRY_RUN == 1 )); then
    log "  [DRY] would quarantine: $file_path -> $dest"
    return 0
  fi

  mv -- "$file_path" "$dest"
  log "  moved to quarantine: $(basename "$dest")"
  return 0
}

upload_and_handle() {
  local folder="$1" file_path="$2"
  local base file_date dest out

  base="$(basename "$file_path")"
  file_date="$(echo "$base" | grep -oE "$DATE_REGEX" || true)"
  [[ -n "$file_date" ]] || return 0

  # Only handle files older/equal to threshold
  if ! is_date_older_or_equal "$file_date" "$THRESHOLD_DATE"; then
    return 0
  fi

  dest="${OSS_DEST_ROOT}/${folder}/${base}"

  if (( DRY_RUN == 1 )); then
    log "  [DRY] would upload   : $file_path -> $dest"
    log "  [DRY] would delete   : $file_path (on success)"
    log "  [DRY] would quarantine on failure"
    return 0
  fi

  out="$("$OSSUTIL_BIN" --config-file "$OSSUTIL_CONFIG" cp "$file_path" "$dest" 2>&1)" || {
    log "  ERROR: upload failed: $base"
    log "  ERROR: $out"
    quarantine_file "$folder" "$file_path"
    return 1
  }

  rm -f -- "$file_path"
  log "  uploaded+deleted: $base -> ${folder}/"
  return 0
}

main() {
  acquire_lock
  init

  log "============================================================"
  log "Upload+Delete job started (ORIGINAL .log files)"
  log "LOGS_ROOT        = $LOGS_ROOT"
  log "QUARANTINE_ROOT  = $QUARANTINE_ROOT"
  log "OSS_DEST_ROOT    = $OSS_DEST_ROOT"
  log "THRESHOLD_DATE   = $THRESHOLD_DATE (inclusive)"
  log "DRY_RUN          = $DRY_RUN"
  log "============================================================"

  local total_candidates=0
  local total_uploaded_deleted=0
  local total_failed_quarantined=0

  for folder in "${FOLDERS[@]}"; do
    local dir
    dir="$(resolve_folder_dir "$folder" || true)"
    if [[ -z "${dir:-}" || ! -d "$dir" ]]; then
      log "Folder missing, skipping: ${LOGS_ROOT}/${folder}"
      continue
    fi

    log ""
    log "Processing folder: $folder (resolved: $dir)"

    local files=()
    mapfile -t files < <( (find "$dir" -maxdepth 1 -type f -iname "*.log" -print | sort) || true )

    if (( ${#files[@]} == 0 )); then
      log "  No .log files found"
      continue
    fi

    for f in "${files[@]}"; do
      local d
      d="$(basename "$f" | grep -oE "$DATE_REGEX" || true)"
      if [[ -n "$d" ]] && is_date_older_or_equal "$d" "$THRESHOLD_DATE"; then
        total_candidates=$((total_candidates + 1))
        if upload_and_handle "$folder" "$f"; then
          total_uploaded_deleted=$((total_uploaded_deleted + 1))
        else
          total_failed_quarantined=$((total_failed_quarantined + 1))
        fi
      fi
    done
  done

  log ""
  log "============================================================"
  log "Job finished"
  log "Candidates (<= threshold): $total_candidates"
  log "Uploaded+Deleted         : $total_uploaded_deleted"
  log "Failed+Quarantined       : $total_failed_quarantined"
  log "Run log                  : $RUN_LOG"
  log "============================================================"
}

main "$@"