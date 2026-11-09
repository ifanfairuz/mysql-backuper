#!/usr/bin/env bash

# ==============================================================================
# Konfigurasi & Direktori Utama
# ==============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/dbs"
RESULT_DIR="$SCRIPT_DIR/result"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
GLOBAL_LOG_FILE="$RESULT_DIR/backup_global_${TIMESTAMP}.log"

# Buat direktori result jika belum ada
mkdir -p "$RESULT_DIR"

# ==============================================================================
# Fungsi Pendukung
# ==============================================================================

log_global() {
    local message="$1"
    echo -e "$message" | tee -a "$GLOBAL_LOG_FILE"
}

check_dependencies() {
    if ! command -v mydumper &> /dev/null; then
        log_global "[ERROR] Binary 'mydumper' tidak ditemukan di sistem."
        log_global "Silakan install terlebih dahulu:"
        log_global "  sudo apt-get install mydumper  # Ubuntu/Debian"
        log_global "  sudo yum install mydumper      # RHEL/CentOS"
        exit 1
    fi
}

process_database() {
    local host="$1"
    local db_name="$2"
    local user="$3"
    local pass="$4"

    local temp_backup_dir="$RESULT_DIR/temp_${db_name}_${TIMESTAMP}"
    local archive_name="$RESULT_DIR/backup_${db_name}_${TIMESTAMP}.tar.gz"
    local db_log_file="$RESULT_DIR/backup_${db_name}_${TIMESTAMP}.log"

    log_global "--------------------------------------------------"
    log_global "[INFO] Memproses database: '$db_name' di host '$host'"
    log_global "[INFO] Log khusus database ini disimpan di: $(basename "$db_log_file")"

    # Inisialisasi file log database
    {
        echo "=== Log Mydumper untuk Database: $db_name ==="
        echo "Waktu Mulai: $(date)"
    } > "$db_log_file"

    # Buat direktori sementara
    mkdir -p "$temp_backup_dir"

    # Eksekusi Mydumper
    log_global "[INFO] Menjalankan mydumper untuk $db_name (Verbose 3)..."
    mydumper \
        --host="$host" \
        --database="$db_name" \
        --user="$user" \
        --password="$pass" \
        --outputdir="$temp_backup_dir" \
        --verbose=3 >> "$db_log_file" 2>&1

    if [ $? -eq 0 ]; then
        log_global "[SUCCESS] Mydumper selesai untuk database: $db_name"
        echo "[SUCCESS] Mydumper selesai tanpa error." >> "$db_log_file"

        # Kompresi Arsip (.tar.gz)
        log_global "[INFO] Mengompresi ke $(basename "$archive_name")..."
        if command -v pigz &> /dev/null; then
            tar -I pigz -cf "$archive_name" -C "$(dirname "$temp_backup_dir")" "$(basename "$temp_backup_dir")" >> "$db_log_file" 2>&1
        else
            tar -czf "$archive_name" -C "$(dirname "$temp_backup_dir")" "$(basename "$temp_backup_dir")" >> "$db_log_file" 2>&1
        fi

        if [ $? -eq 0 ]; then
            log_global "[SUCCESS] Arsip berhasil dibuat: $(basename "$archive_name")"
            echo "[SUCCESS] Kompresi arsip berhasil." >> "$db_log_file"
        else
            log_global "[ERROR] Gagal mengompresi arsip untuk $db_name."
            echo "[ERROR] Gagal mengompresi arsip." >> "$db_log_file"
        fi
    else
        log_global "[ERROR] Mydumper gagal untuk database: $db_name. Periksa log terkait."
        echo "[ERROR] Proses mydumper gagal." >> "$db_log_file"
    fi

    # Bersihkan folder sementara
    [ -d "$temp_backup_dir" ] && rm -rf "$temp_backup_dir"

    echo "Waktu Selesai: $(date)" >> "$db_log_file"
}

# ==============================================================================
# Eksekusi Utama
# ==============================================================================

main() {
    log_global "=== Memulai Proses Backup Multi-Database ==="

    # 1. Cek dependensi sistem
    check_dependencies

    # 2. Cek file konfigurasi dbs
    if [ ! -f "$CONFIG_FILE" ]; then
        log_global "[ERROR] File konfigurasi '$CONFIG_FILE' tidak ditemukan!"
        log_global "Buat file dengan format per baris: host dbname user pass"
        exit 1
    fi

    # 3. Baca file dbs baris per baris
    while read -r db_host db_name db_user db_pass || [ -n "$db_host" ]; do
        # Lewati baris kosong atau komentar
        [[ -z "$db_host" || "$db_host" =~ ^# ]] && continue

        process_database "$db_host" "$db_name" "$db_user" "$db_pass"
    done < "$CONFIG_FILE"

    log_global "--------------------------------------------------"
    log_global "=== Semua Proses Backup Selesai. Hasil disimpan di: $RESULT_DIR ==="
}

# Jalankan fungsi utama
main
