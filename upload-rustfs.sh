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

# ==============================================================================
# Fungsi Pendukung
# ==============================================================================

log_message() {
    local message="$1"
    echo -e "$message" | tee -a "$UPLOAD_LOG_FILE"
}

check_dependencies() {
    if ! command -v rc &> /dev/null; then
        log_message "[ERROR] Binary 'rc' (RustFS client) tidak ditemukan di sistem."
        log_message "Pastikan 'rc' sudah terinstal dan terdaftar di PATH sistem (misal: /usr/local/bin/rc)."
        exit 1
    fi
}

validate_bucket() {
    local bucket_name="$1"

    log_message "[INFO] Memeriksa koneksi bucket via 'rc ping $bucket_name'..."
    rc ping "$bucket_name" >> "$UPLOAD_LOG_FILE" 2>&1
    if [ $? -ne 0 ]; then
        log_message "[ERROR] Gagal melakukan ping ke bucket '$bucket_name'."
        exit 1
    fi

    log_message "[INFO] Memeriksa kesiapan bucket via 'rc ready $bucket_name'..."
    rc ready "$bucket_name" >> "$UPLOAD_LOG_FILE" 2>&1
    if [ $? -ne 0 ]; then
        log_message "[ERROR] Bucket '$bucket_name' belum siap / tidak dapat diakses."
        exit 1
    fi

    log_message "[SUCCESS] Bucket '$bucket_name' valid dan siap digunakan."
}

process_uploads() {
    local bucket_name="$1"

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

            # Target tujuan di RustFS: bucket_name/tanggal/filename
            local remote_target="$bucket_name/$CURRENT_DATE/$file_name"

            log_message "--------------------------------------------------"
            log_message "[INFO] Memproses file: $file_name"

            # Eksekusi upload menggunakan client 'rc object copy'
            log_message "[INFO] Mengunggah ke RustFS -> $remote_target..."
            rc object copy "$file_path" "$remote_target" >> "$UPLOAD_LOG_FILE" 2>&1

            if [ $? -eq 0 ]; then
                log_message "[SUCCESS] Berhasil mengunggah $file_name ke RustFS."

                # Pindahkan file ke folder history/tanggal lokal
                log_message "[INFO] Memindahkan $file_name ke $(basename "$HISTORY_DIR")/..."
                mv "$file_path" "$HISTORY_DIR/"

                if [ $? -eq 0 ]; then
                    log_message "[SUCCESS] File berhasil dipindahkan ke history lokal."
                else
                    log_message "[ERROR] Gagal memindahkan file ke folder history lokal."
                fi
            else
                log_message "[ERROR] Gagal mengunggah $file_name ke RustFS. File tetap di folder result."
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
    # Validasi argument minimal 1 (nama bucket)
    if [ -z "$1" ]; then
        echo "[ERROR] Argumen bucket belum disertakan."
        echo "Cara penggunaan: $0 <nama_bucket>"
        echo "Contoh: $0 local/my-bucket"
        exit 1
    fi

    local RUSTFS_BUCKET="$1"

    log_message "=== Memulai Proses Upload ke RustFS & Arsip History ==="
    log_message "Waktu Mulai: $(date)"
    log_message "Target Bucket: $RUSTFS_BUCKET/$CURRENT_DATE/"

    check_dependencies
    validate_bucket "$RUSTFS_BUCKET"
    process_uploads "$RUSTFS_BUCKET"
    cleanup_old_history

    log_message "--------------------------------------------------"
    log_message "=== Proses Selesai. Log disimpan di: $UPLOAD_LOG_FILE ==="
}

# Jalankan fungsi utama dengan argumen pertama
main "$1"
