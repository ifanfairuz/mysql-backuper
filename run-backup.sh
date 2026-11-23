#!/usr/bin/env bash

# ==============================================================================
# Runner: backup database lalu upload sesuai pengaturan di .config
# (dibuat oleh install.sh, dipanggil oleh cron)
#
# Alur (pipeline per database):
#   DB A: dump -> kompres -> upload -> pindah ke history
#   DB B: dump -> kompres -> upload -> pindah ke history
#   ...
#   Sweep: upload sisa file di result/ (yang gagal + log global) & bersihkan history lama
#
# Penggunaan:
#   ./run-backup.sh              -> jalankan backup penuh
#   ./run-backup.sh <file>...    -> hanya upload file tertentu (dipakai sebagai POST_DB_HOOK)
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/.config"
LOCK_FILE="$SCRIPT_DIR/.run.lock"

# Cron memakai PATH minimal; pastikan /usr/local/bin (rc, rclone) ikut terbaca
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "[ERROR] File $CONFIG_FILE tidak ditemukan. Jalankan install.sh terlebih dahulu."
    exit 1
fi

# shellcheck disable=SC1090
. "$CONFIG_FILE"
export S3_REMOTE RCLONE_EXTRA_ARGS MYDUMPER_THREADS EXCLUDE_DBS COMPRESS COMPRESS_LEVEL COMPRESS_THREADS

# Upload file tertentu; tanpa argumen file -> upload semua isi result/
upload() {
    case "$STORAGE_TYPE" in
        rustfs) "$SCRIPT_DIR/upload-rustfs.sh" "$RUSTFS_ALIAS" "$RUSTFS_BUCKET" "$@" ;;
        s3)     "$SCRIPT_DIR/upload-s3.sh" "$S3_BUCKET" "$S3_PREFIX" "$@" ;;
        local)  return 0 ;;
        *)      echo "[ERROR] STORAGE_TYPE tidak dikenal: '$STORAGE_TYPE'"; return 1 ;;
    esac
}

# Mode hook: dipanggil oleh backupdb.sh untuk setiap DB yang selesai
if [ $# -gt 0 ]; then
    upload "$@"
    exit $?
fi

# Cegah dua proses backup berjalan bersamaan (misal cron tumpang tindih)
exec 9> "$LOCK_FILE"
if ! flock -n 9; then
    echo "[WARN] [$(date '+%Y-%m-%d %H:%M:%S')] Backup lain masih berjalan, proses ini dilewati."
    exit 0
fi

echo "=== [$(date '+%Y-%m-%d %H:%M:%S')] Mulai run-backup (storage: $STORAGE_TYPE) ==="

# Satu file log upload untuk seluruh run ini
CURRENT_DATE=$(date +%Y%m%d)
mkdir -p "$SCRIPT_DIR/history/$CURRENT_DATE"
export UPLOAD_LOG_FILE="$SCRIPT_DIR/history/$CURRENT_DATE/upload_log_$(date +%H%M%S).log"

if [ "$STORAGE_TYPE" != "local" ]; then
    export POST_DB_HOOK="$SCRIPT_DIR/run-backup.sh"
fi

"$SCRIPT_DIR/backupdb.sh" 9>&-

if [ "$STORAGE_TYPE" = "local" ]; then
    echo "[INFO] Mode lokal: hasil backup tetap di $SCRIPT_DIR/result"
else
    echo "[INFO] Sweep: upload sisa file di result/ dan bersihkan history lama..."
    upload 9>&-
fi

echo "=== [$(date '+%Y-%m-%d %H:%M:%S')] Selesai run-backup ==="
