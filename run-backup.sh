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

# Cron memakai PATH minimal; pastikan rc / rclone ikut terbaca, baik yang dipasang
# sebagai root (/usr/local/bin) maupun sebagai user biasa (~/.local/bin)
export PATH="${HOME:+$HOME/.local/bin:}/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "[ERROR] File $CONFIG_FILE tidak ditemukan. Jalankan install.sh terlebih dahulu."
    exit 1
fi

if [ ! -r "$CONFIG_FILE" ]; then
    echo "[ERROR] File $CONFIG_FILE tidak dapat dibaca oleh user $(id -un) (pemilik: $(stat -c %U "$CONFIG_FILE" 2>/dev/null))."
    echo "        Jalankan sebagai pemiliknya, atau minta admin: sudo chown $(id -un): \"$CONFIG_FILE\""
    exit 1
fi

# shellcheck disable=SC1090
. "$CONFIG_FILE"
export S3_REMOTE RCLONE_EXTRA_ARGS MYDUMPER_THREADS EXCLUDE_DBS COMPRESS COMPRESS_LEVEL COMPRESS_THREADS

# Upload file tertentu; tanpa argumen file -> upload semua isi result/
upload() {
    case "$STORAGE_TYPE" in
        rustfs) "$SCRIPT_DIR/upload-rustfs.sh" "$RUSTFS_ALIAS" "${TARGET_BUCKET:-$RUSTFS_BUCKET}" "$@" ;;
        s3)     "$SCRIPT_DIR/upload-s3.sh" "${TARGET_BUCKET:-$S3_BUCKET}" "$S3_PREFIX" "$@" ;;
        local)  return 0 ;;
        *)      echo "[ERROR] STORAGE_TYPE tidak dikenal: '$STORAGE_TYPE'"; return 1 ;;
    esac
}

# Upload ulang file yang tertinggal di result/ ke bucket masing-masing
# (bucket custom dari result/.targets, sisanya ke bucket default), lalu bersihkan history
sweep() {
    local result_dir="$SCRIPT_DIR/result" targets="$SCRIPT_DIR/result/.targets"
    declare -A file_bucket=()
    local name bucket

    if [ -f "$targets" ]; then
        while IFS=$'\t' read -r name bucket; do
            [ -n "$name" ] && [ -n "$bucket" ] && file_bucket["$name"]="$bucket"
        done < "$targets"
    fi

    # Kelompokkan file per bucket
    declare -A groups=()
    local default_files=() f
    for f in "$result_dir"/*; do
        [ -f "$f" ] || continue
        name=$(basename "$f")
        bucket="${file_bucket[$name]}"
        if [ -n "$bucket" ]; then
            groups["$bucket"]+="$f"$'\n'
        else
            default_files+=("$f")
        fi
    done

    local files=()
    for bucket in "${!groups[@]}"; do
        mapfile -t files < <(printf '%s' "${groups[$bucket]}")
        echo "[INFO] Sweep: ${#files[@]} file ke bucket '$bucket'"
        TARGET_BUCKET="$bucket" upload "${files[@]}"
    done
    if [ "${#default_files[@]}" -gt 0 ]; then
        echo "[INFO] Sweep: ${#default_files[@]} file ke bucket default"
        TARGET_BUCKET="" upload "${default_files[@]}"
    fi

    # Pangkas .targets: simpan hanya entri yang filenya masih ada
    if [ -f "$targets" ]; then
        local tmp="$targets.tmp"
        : > "$tmp"
        for name in "${!file_bucket[@]}"; do
            [ -f "$result_dir/$name" ] && printf '%s\t%s\n' "$name" "${file_bucket[$name]}" >> "$tmp"
        done
        mv "$tmp" "$targets"
        [ -s "$targets" ] || rm -f "$targets"
    fi

    # Hapus folder history lokal yang lebih lama dari 3 hari
    find "$SCRIPT_DIR/history" -mindepth 1 -maxdepth 1 -type d -mtime +3 -exec rm -rf {} + 2>/dev/null
}

# Mode hook: dipanggil oleh backupdb.sh untuk setiap DB yang selesai
# (TARGET_BUCKET dari environment menentukan bucket tujuan)
if [ $# -gt 0 ]; then
    upload "$@"
    exit $?
fi

# Cegah dua proses backup berjalan bersamaan (misal cron tumpang tindih)
if ! exec 9> "$LOCK_FILE"; then
    echo "[ERROR] Tidak dapat membuka lock file $LOCK_FILE sebagai user $(id -un)."
    echo "        Kemungkinan file/folder milik user lain (misal root). Perbaiki: sudo chown -R $(id -un): \"$SCRIPT_DIR\""
    exit 1
fi
if ! flock -n 9; then
    echo "[WARN] [$(date '+%Y-%m-%d %H:%M:%S')] Backup lain masih berjalan, proses ini dilewati."
    exit 0
fi

echo "=== [$(date '+%Y-%m-%d %H:%M:%S')] Mulai run-backup (storage: $STORAGE_TYPE) ==="

# Satu file log upload untuk seluruh run ini
CURRENT_DATE=$(date +%Y%m%d)
if ! mkdir -p "$SCRIPT_DIR/history/$CURRENT_DATE" || [ ! -w "$SCRIPT_DIR/history/$CURRENT_DATE" ]; then
    echo "[ERROR] Folder $SCRIPT_DIR/history/$CURRENT_DATE tidak dapat ditulis oleh user $(id -un)."
    echo "        Perbaiki: sudo chown -R $(id -un): \"$SCRIPT_DIR/history\""
    exit 1
fi
export UPLOAD_LOG_FILE="$SCRIPT_DIR/history/$CURRENT_DATE/upload_log_$(date +%H%M%S).log"

if [ "$STORAGE_TYPE" != "local" ]; then
    export POST_DB_HOOK="$SCRIPT_DIR/run-backup.sh"
fi

"$SCRIPT_DIR/backupdb.sh" 9>&-

if [ "$STORAGE_TYPE" = "local" ]; then
    echo "[INFO] Mode lokal: hasil backup tetap di $SCRIPT_DIR/result"
else
    echo "[INFO] Sweep: upload sisa file di result/ dan bersihkan history lama..."
    sweep 9>&-
fi

echo "=== [$(date '+%Y-%m-%d %H:%M:%S')] Selesai run-backup ==="
