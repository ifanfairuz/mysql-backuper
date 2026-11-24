#!/usr/bin/env bash

# ==============================================================================
# Konfigurasi & Direktori Utama
# ==============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULT_DIR="$SCRIPT_DIR/result"
HISTORY_PARENT="$SCRIPT_DIR/history"

CURRENT_DATE=$(date +%Y%m%d)
CURRENT_TIME=$(date +%H%M%S)
HISTORY_DIR="$HISTORY_PARENT/$CURRENT_DATE"

# rclone bisa terpasang di /usr/local/bin (root) atau ~/.local/bin (user biasa)
export PATH="${HOME:+$HOME/.local/bin:}/usr/local/bin:$PATH"

# Pastikan folder history harian ada terlebih dahulu untuk menampung log
if ! mkdir -p "$HISTORY_DIR" || [ ! -w "$HISTORY_DIR" ]; then
    echo "[ERROR] Folder $HISTORY_DIR tidak dapat ditulis oleh user $(id -un)." >&2
    echo "        Perbaiki: sudo chown -R $(id -un): \"$HISTORY_PARENT\"" >&2
    exit 1
fi
UPLOAD_LOG_FILE="${UPLOAD_LOG_FILE:-$HISTORY_DIR/upload_log_${CURRENT_TIME}.log}"

# Nama remote rclone (dibuat oleh install.sh / `rclone config`)
S3_REMOTE="${S3_REMOTE:-s3backup}"

# Opsi rclone: retry otomatis, multipart untuk file besar, tanpa cek/buat bucket
# (agar cukup dengan permission PutObject). Tambahan via RCLONE_EXTRA_ARGS.
RCLONE_ARGS=(
    --retries 3
    --low-level-retries 10
    --s3-no-check-bucket
    --s3-chunk-size 64M
    --s3-upload-concurrency 4
    --stats-one-line
    -v
)
# shellcheck disable=SC2206
[ -n "$RCLONE_EXTRA_ARGS" ] && RCLONE_ARGS+=($RCLONE_EXTRA_ARGS)

# ==============================================================================
# Fungsi Pendukung
# ==============================================================================

log_message() {
    local message="$1"
    echo -e "$message" | tee -a "$UPLOAD_LOG_FILE"
}

check_dependencies() {
    if ! command -v rclone &> /dev/null; then
        log_message "[ERROR] Binary 'rclone' tidak ditemukan di sistem."
        log_message "Jalankan install.sh atau install manual: https://rclone.org/install/"
        exit 1
    fi

    if ! rclone listremotes 2>/dev/null | grep -qxF "${S3_REMOTE}:"; then
        log_message "[ERROR] Remote rclone '$S3_REMOTE' belum dikonfigurasi (cek: rclone listremotes)."
        exit 1
    fi
}

validate_bucket() {
    local bucket_name="$1"

    log_message "[INFO] Memeriksa akses ke bucket '$bucket_name' via rclone..."
    if ! rclone lsf "$S3_REMOTE:$bucket_name" --max-depth 1 --dirs-only >> "$UPLOAD_LOG_FILE" 2>&1; then
        log_message "[ERROR] Bucket '$bucket_name' tidak dapat diakses (bucket tidak ada atau kredensial salah)."
        exit 1
    fi

    log_message "[SUCCESS] Bucket '$bucket_name' valid dan siap digunakan."
}

# Upload satu file lalu pindahkan ke history lokal. Return 1 jika gagal.
upload_one() {
    local base_target="$1" file_path="$2"
    local file_name
    file_name=$(basename "$file_path")

    # Target tujuan: remote:bucket/tanggal[/prefix]/filename
    local remote_target="$base_target/$file_name"

    log_message "--------------------------------------------------"
    log_message "[INFO] Memproses file: $file_name"

    if [ ! -f "$file_path" ]; then
        log_message "[ERROR] File '$file_path' tidak ditemukan."
        return 1
    fi

    log_message "[INFO] Mengunggah ke S3 -> $remote_target..."
    if ! rclone copyto "$file_path" "$remote_target" "${RCLONE_ARGS[@]}" >> "$UPLOAD_LOG_FILE" 2>&1; then
        log_message "[ERROR] Gagal mengunggah $file_name ke S3. File tetap di tempat semula."
        return 1
    fi
    log_message "[SUCCESS] Berhasil mengunggah $file_name ke S3."

    log_message "[INFO] Memindahkan $file_name ke $(basename "$HISTORY_DIR")/..."
    if mv "$file_path" "$HISTORY_DIR/"; then
        log_message "[SUCCESS] File berhasil dipindahkan ke history lokal."
    else
        log_message "[ERROR] Gagal memindahkan file ke folder history lokal."
    fi
}

# Upload semua file di folder result/
process_uploads() {
    local base_target="$1"

    if [ ! -d "$RESULT_DIR" ]; then
        log_message "[INFO] Folder result '$RESULT_DIR' tidak ditemukan. Tidak ada file untuk di-upload."
        return 0
    fi

    local file_count
    file_count=$(find "$RESULT_DIR" -maxdepth 1 -type f | wc -l)
    if [ "$file_count" -eq 0 ]; then
        log_message "[INFO] Tidak ada file ditemukan di dalam folder result."
        return 0
    fi

    local failed=0 file_path
    for file_path in "$RESULT_DIR"/*; do
        [ -f "$file_path" ] || continue
        upload_one "$base_target" "$file_path" || failed=1
    done
    return $failed
}

# Upload hanya file-file tertentu (dipakai pipeline per database)
process_files() {
    local base_target="$1"
    shift 1

    local failed=0 file_path
    for file_path in "$@"; do
        upload_one "$base_target" "$file_path" || failed=1
    done
    return $failed
}

cleanup_old_history() {
    if [ -d "$HISTORY_PARENT" ]; then
        log_message "--------------------------------------------------"
        log_message "[INFO] Membersihkan folder history lokal yang lebih lama dari 3 hari..."

        # Cari dan hapus direktori di dalam folder history yang umurnya > 3 hari
        find "$HISTORY_PARENT" -mindepth 1 -maxdepth 1 -type d -mtime +3 -exec rm -rf {} +

        log_message "[SUCCESS] Pembersihan history lama selesai."
    fi
}

# ==============================================================================
# Eksekusi Utama
# ==============================================================================

main() {
    if [ -z "$1" ]; then
        echo "[ERROR] Argumen kurang lengkap."
        echo "Cara penggunaan: $0 <nama_bucket> [prefix] [file...]"
        echo "Contoh: $0 my-backup-bucket mysql"
        echo "Tanpa [file...], semua file di folder result/ akan di-upload (prefix boleh \"\")."
        echo "Env opsional: S3_REMOTE (nama remote rclone, default: s3backup), RCLONE_EXTRA_ARGS"
        exit 1
    fi

    local S3_BUCKET="$1"
    # Hapus slash di awal/akhir prefix
    local S3_PREFIX="${2#/}"
    S3_PREFIX="${S3_PREFIX%/}"

    # Struktur: remote:bucket/tanggal[/prefix]
    local BASE_TARGET="$S3_REMOTE:$S3_BUCKET/$CURRENT_DATE"
    if [ -n "$S3_PREFIX" ]; then
        BASE_TARGET="$BASE_TARGET/$S3_PREFIX"
    fi

    log_message "=== Memulai Proses Upload ke S3 & Arsip History ==="
    log_message "Waktu Mulai  : $(date)"
    log_message "Target Bucket: $S3_BUCKET"
    log_message "Target Path  : $BASE_TARGET/"
    log_message "Remote rclone: $S3_REMOTE"

    local status=0

    check_dependencies
    validate_bucket "$S3_BUCKET"

    if [ $# -gt 2 ]; then
        shift 2
        process_files "$BASE_TARGET" "$@" || status=1
    else
        process_uploads "$BASE_TARGET" || status=1
        cleanup_old_history
    fi

    log_message "--------------------------------------------------"
    log_message "=== Proses Selesai. Log disimpan di: $UPLOAD_LOG_FILE ==="
    exit $status
}

main "$@"
