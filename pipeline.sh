#!/usr/bin/env bash
#kheiro
set -Eeuo pipefail

COMPRESS_SCRIPT="/home/heiro/compress_2months_old_logs.bash"
UPLOAD_DELETE_SCRIPT="/home/heiro/upload_then_delete_2months_old_logs.bash"

bash "$COMPRESS_SCRIPT"
bash "$UPLOAD_DELETE_SCRIPT"