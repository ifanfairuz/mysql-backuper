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

# Pastikan folder history harian ada terlebih dahulu untuk menampung log
mkdir -p "$HISTORY_DIR"
UPLOAD_LOG_FILE="$HISTORY_DIR/upload_log_${CURRENT_TIME}.log"

# Argumen tambahan untuk aws CLI (misal: --endpoint-url untuk S3-compatible)
AWS_ARGS=()
if [ -n "$S3_ENDPOINT_URL" ]; then
    AWS_ARGS+=(--endpoint-url "$S3_ENDPOINT_URL")
fi

# ==============================================================================
# Fungsi Pendukung
# ==============================================================================

log_message() {
    local message="$1"
    echo -e "$message" | tee -a "$UPLOAD_LOG_FILE"
}

check_dependencies() {
    if ! command -v aws &> /dev/null; then
        log_message "[ERROR] Binary 'aws' (AWS CLI) tidak ditemukan di sistem."
        log_message "Pastikan AWS CLI sudah terinstal dan terdaftar di PATH sistem."
        exit 1
    fi
}

validate_bucket() {
    local bucket_name="$1"

    log_message "[INFO] Memeriksa akses ke bucket '$bucket_name' via 'aws s3api head-bucket'..."
    if ! aws "${AWS_ARGS[@]}" s3api head-bucket --bucket "$bucket_name" >> "$UPLOAD_LOG_FILE" 2>&1; then
        log_message "[ERROR] Bucket '$bucket_name' tidak dapat diakses (bucket tidak ada atau kredensial salah)."
        exit 1
    fi

    log_message "[SUCCESS] Bucket '$bucket_name' valid dan siap digunakan."
}

process_uploads() {
    local base_target="$1"

    if [ ! -d "$RESULT_DIR" ]; then
        log_message "[INFO] Folder result '$RESULT_DIR' tidak ditemukan. Tidak ada file untuk di-upload."
        return
    fi

    # Hitung jumlah file di dalam folder result
    local file_count
    file_count=$(find "$RESULT_DIR" -maxdepth 1 -type f | wc -l)

    if [ "$file_count" -eq 0 ]; then
        log_message "[INFO] Tidak ada file ditemukan di dalam folder result."
        return
    fi

    for file_path in "$RESULT_DIR"/*; do
        if [ -f "$file_path" ]; then
            local file_name
            file_name=$(basename "$file_path")

            # Target tujuan di S3: s3://bucket[/prefix]/tanggal/filename
            local remote_target="$base_target/$file_name"

            log_message "--------------------------------------------------"
            log_message "[INFO] Memproses file: $file_name"

            log_message "[INFO] Mengunggah ke S3 -> $remote_target..."
            if aws "${AWS_ARGS[@]}" s3 cp "$file_path" "$remote_target" --only-show-errors >> "$UPLOAD_LOG_FILE" 2>&1; then
                log_message "[SUCCESS] Berhasil mengunggah $file_name ke S3."

                # Pindahkan file ke folder history/tanggal lokal
                log_message "[INFO] Memindahkan $file_name ke $(basename "$HISTORY_DIR")/..."
                if mv "$file_path" "$HISTORY_DIR/"; then
                    log_message "[SUCCESS] File berhasil dipindahkan ke history lokal."
                else
                    log_message "[ERROR] Gagal memindahkan file ke folder history lokal."
                fi
            else
                log_message "[ERROR] Gagal mengunggah $file_name ke S3. File tetap di folder result."
            fi
        fi
    done
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
        echo "Cara penggunaan: $0 <nama_bucket> [prefix]"
        echo "Contoh: $0 my-backup-bucket mysql"
        echo "Env opsional: AWS_PROFILE, S3_ENDPOINT_URL (untuk S3-compatible seperti MinIO/R2/Wasabi)"
        exit 1
    fi

    local S3_BUCKET="$1"
    # Hapus slash di awal/akhir prefix
    local S3_PREFIX="${2#/}"
    S3_PREFIX="${S3_PREFIX%/}"

    local BASE_TARGET="s3://$S3_BUCKET"
    if [ -n "$S3_PREFIX" ]; then
        BASE_TARGET="$BASE_TARGET/$S3_PREFIX"
    fi
    BASE_TARGET="$BASE_TARGET/$CURRENT_DATE"

    log_message "=== Memulai Proses Upload ke S3 & Arsip History ==="
    log_message "Waktu Mulai  : $(date)"
    log_message "Target Bucket: $S3_BUCKET"
    log_message "Target Path  : $BASE_TARGET/"
    [ -n "$AWS_PROFILE" ] && log_message "AWS Profile  : $AWS_PROFILE"
    [ -n "$S3_ENDPOINT_URL" ] && log_message "Endpoint URL : $S3_ENDPOINT_URL"

    check_dependencies
    validate_bucket "$S3_BUCKET"
    process_uploads "$BASE_TARGET"
    cleanup_old_history

    log_message "--------------------------------------------------"
    log_message "=== Proses Selesai. Log disimpan di: $UPLOAD_LOG_FILE ==="
}

main "$@"
