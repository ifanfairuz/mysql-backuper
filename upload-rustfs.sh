#!/usr/bin/env bash

# ==============================================================================
# Konfigurasi & Direktori Utama
# ==============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env.rustfs"
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

load_environment() {
    if [ ! -f "$ENV_FILE" ]; then
        log_message "[ERROR] File konfigurasi '$ENV_FILE' tidak ditemukan!"
        log_message "Buat file .env.rustfs berisi variabel seperti RUSTFS_ENDPOINT, RUSTFS_ACCESS_KEY, RUSTFS_SECRET_KEY, dan RUSTFS_BUCKET."
        exit 1
    fi

    # Muat variabel environment secara aman
    set -a
    source "$ENV_FILE"
    set +a

    if [ -z "$RUSTFS_BUCKET" ]; then
        log_message "[ERROR] Variabel RUSTFS_BUCKET tidak didefinisikan di dalam $ENV_FILE."
        exit 1
    fi
}

process_uploads() {
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

            log_message "--------------------------------------------------"
            log_message "[INFO] Memproses file: $file_name"

            # Eksekusi upload menggunakan client 'rc'
            log_message "[INFO] Mengunggah $file_name ke RustFS..."
            rc cp "$file_path" "rustfs://$RUSTFS_BUCKET/$file_name" >> "$UPLOAD_LOG_FILE" 2>&1

            if [ $? -eq 0 ]; then
                log_message "[SUCCESS] Berhasil mengunggah $file_name ke RustFS."

                # Pindahkan file ke folder history/tanggal
                log_message "[INFO] Memindahkan $file_name ke $(basename "$HISTORY_DIR")/..."
                mv "$file_path" "$HISTORY_DIR/"

                if [ $? -eq 0 ]; then
                    log_message "[SUCCESS] File berhasil dipindahkan ke history."
                else
                    log_message "[ERROR] Gagal memindahkan file ke folder history."
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
        log_message "[INFO] Membersihkan folder history yang lebih lama dari 3 hari..."

        # Cari dan hapus direktori di dalam folder history yang umurnya > 3 hari
        find "$HISTORY_PARENT" -mindepth 1 -maxdepth 1 -type d -mtime +3 -exec rm -rf {} +

        log_message "[SUCCESS] Pembersihan history lama selesai."
    fi
}

# ==============================================================================
# Eksekusi Utama
# ==============================================================================

main() {
    log_message "=== Memulai Proses Upload ke RustFS & Arsip History ==="
    log_message "Waktu Mulai: $(date)"

    check_dependencies
    load_environment
    process_uploads
    cleanup_old_history

    log_message "--------------------------------------------------"
    log_message "=== Proses Selesai. Log disimpan di: $UPLOAD_LOG_FILE ==="
}

# Jalankan fungsi utama
main
