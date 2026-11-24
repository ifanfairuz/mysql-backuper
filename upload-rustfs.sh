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

# rc bisa terpasang di /usr/local/bin (root) atau ~/.local/bin (user biasa)
export PATH="${HOME:+$HOME/.local/bin:}/usr/local/bin:$PATH"

# Pastikan folder history harian ada terlebih dahulu untuk menampung log
if ! mkdir -p "$HISTORY_DIR" || [ ! -w "$HISTORY_DIR" ]; then
    echo "[ERROR] Folder $HISTORY_DIR tidak dapat ditulis oleh user $(id -un)." >&2
    echo "        Perbaiki: sudo chown -R $(id -un): \"$HISTORY_PARENT\"" >&2
    exit 1
fi
UPLOAD_LOG_FILE="${UPLOAD_LOG_FILE:-$HISTORY_DIR/upload_log_${CURRENT_TIME}.log}"

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
        log_message "Pastikan 'rc' sudah terinstal di PATH (misal: /usr/local/bin/rc atau ~/.local/bin/rc)."
        exit 1
    fi
}

validate_alias() {
    local alias_name="$1"

    log_message "[INFO] Memeriksa koneksi server via 'rc ping $alias_name'..."
    rc ping "$alias_name" >> "$UPLOAD_LOG_FILE" 2>&1
    if [ $? -ne 0 ]; then
        log_message "[ERROR] Gagal melakukan ping ke alias '$alias_name'."
        exit 1
    fi

    log_message "[INFO] Memeriksa kesiapan server via 'rc ready $alias_name'..."
    rc ready "$alias_name" >> "$UPLOAD_LOG_FILE" 2>&1
    if [ $? -ne 0 ]; then
        log_message "[ERROR] Server dengan alias '$alias_name' belum siap / tidak dapat diakses."
        exit 1
    fi

    log_message "[SUCCESS] Alias '$alias_name' valid dan siap digunakan."
}

# Upload satu file lalu pindahkan ke history lokal. Return 1 jika gagal.
upload_one() {
    local alias_name="$1" bucket_name="$2" file_path="$3"
    local file_name
    file_name=$(basename "$file_path")

    # Target tujuan di RustFS: alias/bucket/tanggal/filename
    local remote_target="$alias_name/$bucket_name/$CURRENT_DATE/$file_name"

    log_message "--------------------------------------------------"
    log_message "[INFO] Memproses file: $file_name"

    if [ ! -f "$file_path" ]; then
        log_message "[ERROR] File '$file_path' tidak ditemukan."
        return 1
    fi

    log_message "[INFO] Mengunggah ke RustFS -> $remote_target..."
    if ! rc object copy "$file_path" "$remote_target" >> "$UPLOAD_LOG_FILE" 2>&1; then
        log_message "[ERROR] Gagal mengunggah $file_name ke RustFS. File tetap di tempat semula."
        return 1
    fi
    log_message "[SUCCESS] Berhasil mengunggah $file_name ke RustFS."

    log_message "[INFO] Memindahkan $file_name ke $(basename "$HISTORY_DIR")/..."
    if mv "$file_path" "$HISTORY_DIR/"; then
        log_message "[SUCCESS] File berhasil dipindahkan ke history lokal."
    else
        log_message "[ERROR] Gagal memindahkan file ke folder history lokal."
    fi
}

# Upload semua file di folder result/
process_uploads() {
    local alias_name="$1"
    local bucket_name="$2"

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
        upload_one "$alias_name" "$bucket_name" "$file_path" || failed=1
    done
    return $failed
}

# Upload hanya file-file tertentu (dipakai pipeline per database)
process_files() {
    local alias_name="$1"
    local bucket_name="$2"
    shift 2

    local failed=0 file_path
    for file_path in "$@"; do
        upload_one "$alias_name" "$bucket_name" "$file_path" || failed=1
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
    # Validasi argumen minimal 2 (alias dan bucket name)
    if [ -z "$1" ] || [ -z "$2" ]; then
        echo "[ERROR] Argumen kurang lengkap."
        echo "Cara penggunaan: $0 <alias> <nama_bucket> [file...]"
        echo "Contoh: $0 local my-backup-bucket"
        echo "Tanpa [file...], semua file di folder result/ akan di-upload."
        exit 1
    fi

    local RUSTFS_ALIAS="$1"
    local RUSTFS_BUCKET="$2"
    local status=0

    log_message "=== Memulai Proses Upload ke RustFS & Arsip History ==="
    log_message "Waktu Mulai: $(date)"
    log_message "Target Alias : $RUSTFS_ALIAS"
    log_message "Target Path  : $RUSTFS_ALIAS/$RUSTFS_BUCKET/$CURRENT_DATE/"

    check_dependencies
    validate_alias "$RUSTFS_ALIAS"

    if [ $# -gt 2 ]; then
        process_files "$@" || status=1
    else
        process_uploads "$RUSTFS_ALIAS" "$RUSTFS_BUCKET" || status=1
        cleanup_old_history
    fi

    log_message "--------------------------------------------------"
    log_message "=== Proses Selesai. Log disimpan di: $UPLOAD_LOG_FILE ==="
    exit $status
}

main "$@"
