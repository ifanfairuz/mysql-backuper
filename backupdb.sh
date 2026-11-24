#!/usr/bin/env bash

# ==============================================================================
# Konfigurasi & Direktori Utama
# ==============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/dbs"
RESULT_DIR="$SCRIPT_DIR/result"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
# Mapping file -> bucket custom, dipakai run-backup.sh saat sweep jika upload per DB gagal
TARGETS_FILE="$RESULT_DIR/.targets"
GLOBAL_LOG_FILE="$RESULT_DIR/backup_global_${TIMESTAMP}.log"

# Pengaturan opsional via environment:
#   MYDUMPER_THREADS    jumlah thread mydumper (default 4)
#   MYDUMPER_EXTRA_ARGS argumen tambahan mydumper, dipisah spasi
#   EXCLUDE_DBS         DB yang dilewati saat auto-discover (baris dbs dengan nama '*'), dipisah spasi
#   COMPRESS            xz (default, paling kecil) | zstd | gzip | none
#   COMPRESS_LEVEL      level kompresi (default: xz 6, zstd 19, gzip 9)
#   COMPRESS_THREADS    thread kompresor xz/zstd (default 0 = semua core)
#   POST_DB_HOOK        perintah yang dipanggil setelah arsip satu DB selesai:
#                       TARGET_BUCKET=<bucket> "$POST_DB_HOOK" <archive> <db.log>
#                       (TARGET_BUCKET kosong = bucket default; contoh: upload langsung per DB)
#
# Format dbs (per baris): DB_HOST DB_NAME DB_USER DB_PASS [BUCKET]
#   DB_NAME '*' = semua DB di host tsb; BUCKET kosong = bucket default dari .config
MYDUMPER_THREADS="${MYDUMPER_THREADS:-4}"
COMPRESS="${COMPRESS:-xz}"
COMPRESS_THREADS="${COMPRESS_THREADS:-0}"
SYSTEM_DBS="information_schema performance_schema mysql sys"

# Buat direktori result jika belum ada & pastikan dapat ditulis user saat ini
if ! mkdir -p "$RESULT_DIR" || [ ! -w "$RESULT_DIR" ] || [ ! -x "$RESULT_DIR" ]; then
    echo "[ERROR] Folder $RESULT_DIR tidak dapat ditulis oleh user $(id -un)." >&2
    echo "        Kemungkinan milik user lain (misal root). Perbaiki: sudo chown -R $(id -un): \"$RESULT_DIR\"" >&2
    exit 1
fi

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

# Tentukan perintah kompresor (COMP_CMD) & ekstensi arsip (COMP_EXT) sekali di awal
resolve_compression() {
    local algo="$COMPRESS" level="$COMPRESS_LEVEL" min max default

    case "$algo" in
        xz|zstd|gzip|none) ;;
        *) log_global "[WARN] COMPRESS='$algo' tidak dikenal, memakai xz."; algo="xz" ;;
    esac

    if [ "$algo" != "none" ] && [ "$algo" != "gzip" ] && ! command -v "$algo" &> /dev/null; then
        log_global "[WARN] Binary '$algo' tidak ditemukan, fallback ke gzip."
        algo="gzip"; level=""
    fi

    case "$algo" in
        xz)   min=0; max=9;  default=6 ;;
        zstd) min=1; max=19; default=19 ;;
        gzip) min=1; max=9;  default=9 ;;
    esac
    if [ "$algo" != "none" ]; then
        if [ -z "$level" ]; then
            level="$default"
        elif ! [[ "$level" =~ ^[0-9]+$ ]] || [ "$level" -lt "$min" ] || [ "$level" -gt "$max" ]; then
            log_global "[WARN] COMPRESS_LEVEL='$level' tidak valid untuk $algo ($min-$max), memakai $default."
            level="$default"
        fi
    fi

    case "$algo" in
        xz)   COMP_CMD=(xz -T"$COMPRESS_THREADS" -"$level" -c); COMP_EXT="tar.xz" ;;
        zstd) COMP_CMD=(zstd -T"$COMPRESS_THREADS" -"$level" --long=27 -q -c); COMP_EXT="tar.zst" ;;
        gzip)
            if command -v pigz &> /dev/null; then COMP_CMD=(pigz -"$level" -c); else COMP_CMD=(gzip -"$level" -c); fi
            COMP_EXT="tar.gz" ;;
        none) COMP_CMD=(); COMP_EXT="tar"; level="" ;;
    esac

    log_global "[INFO] Kompresi: $algo${level:+ level $level} -> .$COMP_EXT"
}

# Bungkus direktori dump menjadi satu arsip (satu stream tar -> kompresor)
compress_archive() {
    local src="$1" dest="$2"
    (
        set -o pipefail
        if [ ${#COMP_CMD[@]} -eq 0 ]; then
            tar -cf "$dest" -C "$(dirname "$src")" "$(basename "$src")"
        else
            tar -cf - -C "$(dirname "$src")" "$(basename "$src")" | nice -n 10 "${COMP_CMD[@]}" > "$dest"
        fi
    ) || { rm -f "$dest"; return 1; }
}

human_size() {
    numfmt --to=iec --suffix=B "$1" 2>/dev/null || echo "${1}B"
}

# Ambil daftar DB dari server, tanpa system DB dan EXCLUDE_DBS
discover_databases() {
    local host="$1" user="$2" pass="$3"

    if ! command -v mysql &> /dev/null; then
        log_global "[ERROR] Client 'mysql' dibutuhkan untuk auto-discover (sudo apt-get install default-mysql-client)." >&2
        return 1
    fi

    local list
    if ! list=$(MYSQL_PWD="$pass" mysql -h "$host" -u "$user" -N -B -e "SHOW DATABASES" 2>&1); then
        log_global "[ERROR] Gagal mengambil daftar database dari '$host': $list" >&2
        return 1
    fi

    local db skip
    for db in $list; do
        for skip in $SYSTEM_DBS $EXCLUDE_DBS; do
            [ "$db" = "$skip" ] && continue 2
        done
        echo "$db"
    done
}

process_database() {
    local host="$1"
    local db_name="$2"
    local user="$3"
    local pass="$4"
    local bucket="$5"

    local temp_backup_dir="$RESULT_DIR/temp_${db_name}_${TIMESTAMP}"
    local archive_name="$RESULT_DIR/backup_${db_name}_${TIMESTAMP}.${COMP_EXT}"
    local db_log_file="$RESULT_DIR/backup_${db_name}_${TIMESTAMP}.log"

    log_global "--------------------------------------------------"
    log_global "[INFO] Memproses database: '$db_name' di host '$host' (bucket: ${bucket:-default})"
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
        --threads="$MYDUMPER_THREADS" \
        $MYDUMPER_EXTRA_ARGS \
        --verbose=3 >> "$db_log_file" 2>&1

    if [ $? -eq 0 ]; then
        log_global "[SUCCESS] Mydumper selesai untuk database: $db_name"
        echo "[SUCCESS] Mydumper selesai tanpa error." >> "$db_log_file"

        # Kompresi arsip (satu stream per DB untuk rasio terbaik)
        log_global "[INFO] Mengompresi ke $(basename "$archive_name")..."
        local raw_bytes start_ts
        raw_bytes=$(du -sb "$temp_backup_dir" 2>/dev/null | cut -f1)
        start_ts=$(date +%s)

        if compress_archive "$temp_backup_dir" "$archive_name" >> "$db_log_file" 2>&1; then
            local arc_bytes ratio
            arc_bytes=$(stat -c %s "$archive_name" 2>/dev/null || echo 0)
            ratio=$(awk -v r="${raw_bytes:-0}" -v a="$arc_bytes" 'BEGIN { if (a > 0) printf "%.1fx", r / a; else print "-" }')
            log_global "[SUCCESS] Arsip berhasil dibuat: $(basename "$archive_name")"
            log_global "[INFO] Ukuran: $(human_size "${raw_bytes:-0}") -> $(human_size "$arc_bytes") (rasio $ratio, $(( $(date +%s) - start_ts ))s)"
            echo "[SUCCESS] Kompresi arsip berhasil (rasio $ratio)." >> "$db_log_file"
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

    # Pipeline: langsung proses (misal upload) arsip DB ini sebelum lanjut ke DB berikutnya
    # Catat bucket custom agar sweep meng-upload ke bucket yang benar jika hook gagal
    if [ -n "$bucket" ]; then
        local f
        for f in "$archive_name" "$db_log_file"; do
            [ -f "$f" ] && printf '%s\t%s\n' "$(basename "$f")" "$bucket" >> "$TARGETS_FILE"
        done
    fi

    if [ -n "$POST_DB_HOOK" ] && [ -f "$archive_name" ]; then
        log_global "[INFO] Menjalankan hook untuk $(basename "$archive_name")..."
        if TARGET_BUCKET="$bucket" "$POST_DB_HOOK" "$archive_name" "$db_log_file" >> "$GLOBAL_LOG_FILE" 2>&1; then
            log_global "[SUCCESS] Hook selesai untuk database: $db_name"
        else
            log_global "[ERROR] Hook gagal untuk database: $db_name. File tetap di folder result."
        fi
    fi
}

# ==============================================================================
# Eksekusi Utama
# ==============================================================================

main() {
    log_global "=== Memulai Proses Backup Multi-Database ==="

    # 1. Cek dependensi sistem & tentukan kompresi
    check_dependencies
    resolve_compression

    # 2. Cek file konfigurasi dbs
    if [ ! -f "$CONFIG_FILE" ]; then
        log_global "[ERROR] File konfigurasi '$CONFIG_FILE' tidak ditemukan!"
        log_global "Buat file dengan format per baris: host dbname user pass [bucket]"
        log_global "Gunakan '*' sebagai dbname untuk mem-backup semua database di host tersebut."
        exit 1
    fi

    # 3. Baca file dbs baris per baris
    local db_host db_name db_user db_pass db_bucket _rest
    while read -r db_host db_name db_user db_pass db_bucket _rest <&3 || [ -n "$db_host" ]; do
        # Lewati baris kosong atau komentar
        [[ -z "$db_host" || "$db_host" =~ ^# ]] && continue
        # Kolom ke-5 yang diawali '#' adalah komentar di akhir baris
        [[ "$db_bucket" == \#* ]] && db_bucket=""

        if [ "$db_name" = "*" ]; then
            log_global "[INFO] Auto-discover database di host '$db_host'..."
            local discovered
            discovered=$(discover_databases "$db_host" "$db_user" "$db_pass") || continue
            log_global "[INFO] Ditemukan $(echo "$discovered" | grep -c .) database: $(echo $discovered)"
            local d
            for d in $discovered; do
                process_database "$db_host" "$d" "$db_user" "$db_pass" "$db_bucket"
            done
        else
            process_database "$db_host" "$db_name" "$db_user" "$db_pass" "$db_bucket"
        fi
    done 3< "$CONFIG_FILE"

    log_global "--------------------------------------------------"
    log_global "=== Semua Proses Backup Selesai. Hasil disimpan di: $RESULT_DIR ==="
}

# Jalankan fungsi utama
main
