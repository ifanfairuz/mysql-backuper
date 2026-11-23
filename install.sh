#!/usr/bin/env bash

# ==============================================================================
# Installer interaktif mysql-backuper (Debian / Ubuntu)
#
# - Menanyakan pengaturan (storage tujuan, daftar database, jadwal cron)
# - Menginstal dependensi (mydumper, pigz, rc / rclone, cron)
# - Menyimpan pengaturan ke .config dan daftar database ke dbs
#
# Jalankan sebagai user yang nantinya menjalankan backup (bukan wajib root);
# sudo hanya dipakai untuk instalasi paket.
# ==============================================================================

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/.config"
DBS_FILE="$SCRIPT_DIR/dbs"
RUNNER="$SCRIPT_DIR/run-backup.sh"
CRON_MARKER="# mysql-backuper"
RC_FALLBACK_VERSION="v0.1.30"

# ==============================================================================
# Helper tampilan & input
# ==============================================================================

c_info="\033[1;34m"; c_ok="\033[1;32m"; c_warn="\033[1;33m"; c_err="\033[1;31m"; c_off="\033[0m"

info()  { echo -e "${c_info}[INFO]${c_off} $*"; }
ok()    { echo -e "${c_ok}[OK]${c_off} $*"; }
warn()  { echo -e "${c_warn}[WARN]${c_off} $*"; }
die()   { echo -e "${c_err}[ERROR]${c_off} $*" >&2; exit 1; }
title() { echo; echo -e "${c_info}==== $* ====${c_off}"; }

# ask "Pertanyaan" "default" -> echo jawaban
ask() {
    local prompt="$1" default="$2" answer
    if [ -n "$default" ]; then
        read -r -p "$prompt [$default]: " answer
    else
        read -r -p "$prompt: " answer
    fi
    echo "${answer:-$default}"
}

# ask_required "Pertanyaan" "default" -> tidak boleh kosong
ask_required() {
    local answer
    while true; do
        answer=$(ask "$1" "$2")
        [ -n "$answer" ] && { echo "$answer"; return; }
        echo "  Nilai tidak boleh kosong." >&2
    done
}

# ask_secret "Pertanyaan" -> input tersembunyi, tidak boleh kosong
ask_secret() {
    local answer
    while true; do
        read -r -s -p "$1: " answer
        echo >&2
        [ -n "$answer" ] && { echo "$answer"; return; }
        echo "  Nilai tidak boleh kosong." >&2
    done
}

# ask_yes_no "Pertanyaan" "y|n" -> return 0 jika ya
ask_yes_no() {
    local prompt="$1" default="${2:-y}" answer hint
    [ "$default" = "y" ] && hint="Y/n" || hint="y/N"
    while true; do
        read -r -p "$prompt [$hint]: " answer
        answer="${answer:-$default}"
        case "${answer,,}" in
            y|ya|yes) return 0 ;;
            n|no|tidak) return 1 ;;
        esac
    done
}

# Tidak boleh mengandung spasi (format file dbs dipisah spasi)
no_space() {
    local label="$1" value="$2"
    if [[ "$value" =~ [[:space:]] ]]; then
        echo "  $label tidak boleh mengandung spasi." >&2
        return 1
    fi
}

# ==============================================================================
# Pemeriksaan sistem
# ==============================================================================

check_os() {
    [ -f /etc/os-release ] || die "Tidak dapat mendeteksi OS (/etc/os-release tidak ada)."
    # shellcheck disable=SC1091
    . /etc/os-release
    if [[ " $ID $ID_LIKE " != *" debian "* && " $ID $ID_LIKE " != *" ubuntu "* ]]; then
        die "Installer ini hanya untuk keluarga Debian/Ubuntu (terdeteksi: ${PRETTY_NAME:-$ID})."
    fi
    ok "OS terdeteksi: ${PRETTY_NAME:-$ID}"
}

setup_sudo() {
    if [ "$EUID" -eq 0 ]; then
        SUDO=""
        warn "Berjalan sebagai root: konfigurasi rc/rclone dan cron akan dibuat untuk user root."
    elif command -v sudo &> /dev/null; then
        SUDO="sudo"
        info "Perintah instalasi paket akan memakai sudo."
        sudo -v || die "Gagal mendapatkan akses sudo."
    else
        die "sudo tidak tersedia. Jalankan sebagai root atau install sudo terlebih dahulu."
    fi
}

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)  ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        *) die "Arsitektur $(uname -m) tidak didukung." ;;
    esac
}

load_existing_config() {
    if [ -f "$CONFIG_FILE" ]; then
        # shellcheck disable=SC1090
        . "$CONFIG_FILE"
        PREV_COMPRESS="$COMPRESS"
        info "Konfigurasi lama ditemukan di .config, dipakai sebagai nilai default."
    fi
}

# ==============================================================================
# Pertanyaan pengaturan
# ==============================================================================

choose_storage() {
    title "1. Tujuan Upload Backup"
    echo "  1) RustFS (client 'rc')"
    echo "  2) S3 / S3-compatible (rclone) - AWS, Cloudflare R2, MinIO, Wasabi, dll"
    echo "  3) Lokal saja (tanpa upload)"

    local default_choice=1
    case "$STORAGE_TYPE" in
        s3) default_choice=2 ;;
        local) default_choice=3 ;;
    esac

    local choice
    while true; do
        choice=$(ask "Pilih tujuan" "$default_choice")
        case "$choice" in
            1) STORAGE_TYPE="rustfs"; break ;;
            2) STORAGE_TYPE="s3"; break ;;
            3) STORAGE_TYPE="local"; break ;;
        esac
    done
    ok "Tujuan upload: $STORAGE_TYPE"
}

# ==============================================================================
# Instalasi dependensi
# ==============================================================================

install_apt_packages() {
    title "2. Instalasi Dependensi"
    local pkgs=(mydumper default-mysql-client xz-utils zstd pigz tar gzip curl ca-certificates cron util-linux)
    [ "$STORAGE_TYPE" = "s3" ] && pkgs+=(unzip)

    info "Menjalankan apt-get update..."
    $SUDO apt-get update -y || die "apt-get update gagal."

    info "Menginstal paket: ${pkgs[*]}"
    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}" \
        || die "Instalasi paket gagal."

    # Pastikan layanan cron aktif
    if command -v systemctl &> /dev/null; then
        $SUDO systemctl enable --now cron &> /dev/null || warn "Tidak dapat mengaktifkan layanan cron via systemctl."
    fi
    ok "Paket dasar terinstal (mydumper $(mydumper --version 2>/dev/null | head -n1 | awk '{print $2}'))."
}

install_rc() {
    if command -v rc &> /dev/null; then
        ok "rc sudah terinstal: $(rc --version 2>/dev/null | head -n1)"
        ask_yes_no "Install ulang / update rc ke versi terbaru?" "n" || return
    fi

    local version
    version=$(curl -fsSLI -o /dev/null -w '%{url_effective}' https://github.com/rustfs/cli/releases/latest 2>/dev/null | sed -n 's#.*/tag/\(v[^/]*\)$#\1#p')
    if [ -z "$version" ]; then
        warn "Gagal mendeteksi versi terbaru rc, memakai $RC_FALLBACK_VERSION."
        version="$RC_FALLBACK_VERSION"
    fi

    local archive="rustfs-cli-linux-${ARCH}-${version}.tar.gz"
    local url="https://github.com/rustfs/cli/releases/download/${version}/${archive}"
    local tmp
    tmp=$(mktemp -d)

    info "Mengunduh rc $version ($ARCH)..."
    curl -fL --progress-bar -o "$tmp/$archive" "$url" || { rm -rf "$tmp"; die "Gagal mengunduh $url"; }
    tar -xzf "$tmp/$archive" -C "$tmp" || { rm -rf "$tmp"; die "Gagal mengekstrak $archive"; }

    local bin
    bin=$(find "$tmp" -type f -name rc | head -n1)
    [ -n "$bin" ] || { rm -rf "$tmp"; die "Binary rc tidak ditemukan di dalam arsip."; }

    $SUDO install -m 0755 "$bin" /usr/local/bin/rc || { rm -rf "$tmp"; die "Gagal memasang rc ke /usr/local/bin."; }
    rm -rf "$tmp"
    ok "rc terinstal: $(/usr/local/bin/rc --version 2>/dev/null | head -n1)"
}

install_rclone() {
    if command -v rclone &> /dev/null; then
        ok "rclone sudah terinstal: $(rclone version 2>/dev/null | head -n1)"
        ask_yes_no "Install ulang / update rclone ke versi terbaru?" "n" || return
    fi

    local tmp
    tmp=$(mktemp -d)
    info "Mengunduh rclone versi terbaru ($ARCH)..."
    curl -fL --progress-bar -o "$tmp/rclone.zip" "https://downloads.rclone.org/rclone-current-linux-${ARCH}.zip" \
        || { rm -rf "$tmp"; die "Gagal mengunduh rclone."; }
    unzip -q "$tmp/rclone.zip" -d "$tmp" || { rm -rf "$tmp"; die "Gagal mengekstrak rclone."; }

    local bin
    bin=$(find "$tmp" -type f -name rclone | head -n1)
    [ -n "$bin" ] || { rm -rf "$tmp"; die "Binary rclone tidak ditemukan di dalam arsip."; }
    $SUDO install -m 0755 "$bin" /usr/local/bin/rclone || { rm -rf "$tmp"; die "Gagal memasang rclone ke /usr/local/bin."; }
    rm -rf "$tmp"
    hash -r
    ok "rclone terinstal: $(/usr/local/bin/rclone version 2>/dev/null | head -n1)"
}

# ==============================================================================
# Konfigurasi storage
# ==============================================================================

configure_rustfs() {
    title "3. Konfigurasi RustFS"
    RUSTFS_ALIAS=$(ask_required "Nama alias rc" "${RUSTFS_ALIAS:-backup}")
    RUSTFS_BUCKET=$(ask_required "Nama bucket" "$RUSTFS_BUCKET")

    local configure=0
    if rc alias list 2>/dev/null | grep -qw -- "$RUSTFS_ALIAS"; then
        ask_yes_no "Alias '$RUSTFS_ALIAS' sudah ada. Atur ulang endpoint & kredensial?" "n" && configure=1
    else
        configure=1
    fi

    if [ "$configure" -eq 1 ]; then
        local endpoint access secret
        endpoint=$(ask_required "Endpoint RustFS (contoh: http://10.0.0.5:9000)" "")
        access=$(ask_required "Access key" "")
        secret=$(ask_secret "Secret key")
        rc alias set "$RUSTFS_ALIAS" "$endpoint" "$access" "$secret" || die "Gagal menyimpan alias rc."
        ok "Alias '$RUSTFS_ALIAS' disimpan."
    fi

    info "Menguji koneksi (rc ping $RUSTFS_ALIAS)..."
    if rc ping "$RUSTFS_ALIAS" &> /dev/null; then
        ok "Server RustFS dapat dijangkau."
    else
        warn "Ping ke '$RUSTFS_ALIAS' gagal. Periksa endpoint/kredensial, lalu jalankan installer lagi bila perlu."
    fi
}

configure_s3() {
    title "3. Konfigurasi S3 (rclone)"
    S3_REMOTE=$(ask_required "Nama remote rclone" "${S3_REMOTE:-s3backup}")
    S3_BUCKET=$(ask_required "Nama bucket" "$S3_BUCKET")
    S3_PREFIX=$(ask "Prefix folder di bucket (kosongkan jika tidak ada)" "$S3_PREFIX")

    local configure=0
    if rclone listremotes 2>/dev/null | grep -qxF "${S3_REMOTE}:"; then
        ask_yes_no "Remote '$S3_REMOTE' sudah ada. Atur ulang provider & kredensial?" "n" && configure=1
    else
        configure=1
    fi

    if [ "$configure" -eq 1 ]; then
        echo "  Provider S3:"
        echo "    1) AWS S3"
        echo "    2) Cloudflare R2"
        echo "    3) MinIO"
        echo "    4) Wasabi"
        echo "    5) DigitalOcean Spaces"
        echo "    6) Lainnya (S3-compatible)"
        local choice provider default_region endpoint_hint
        while true; do
            choice=$(ask "Pilih provider" "1")
            case "$choice" in
                1) provider="AWS";          default_region="ap-southeast-1"; endpoint_hint="kosongkan untuk AWS" ;;
                2) provider="Cloudflare";   default_region="auto";           endpoint_hint="https://<account_id>.r2.cloudflarestorage.com" ;;
                3) provider="Minio";        default_region="us-east-1";      endpoint_hint="http://10.0.0.5:9000" ;;
                4) provider="Wasabi";       default_region="ap-southeast-1"; endpoint_hint="https://s3.ap-southeast-1.wasabisys.com" ;;
                5) provider="DigitalOcean"; default_region="sgp1";           endpoint_hint="https://sgp1.digitaloceanspaces.com" ;;
                6) provider="Other";        default_region="us-east-1";      endpoint_hint="https://s3.example.com" ;;
                *) continue ;;
            esac
            break
        done

        local access secret region endpoint
        access=$(ask_required "Access key ID" "")
        secret=$(ask_secret "Secret access key")
        region=$(ask_required "Region" "$default_region")
        if [ "$provider" = "AWS" ]; then
            endpoint=$(ask "Endpoint ($endpoint_hint)" "")
        else
            endpoint=$(ask_required "Endpoint ($endpoint_hint)" "")
        fi

        local params=(provider="$provider" access_key_id="$access" secret_access_key="$secret" region="$region" no_check_bucket=true)
        [ -n "$endpoint" ] && params+=(endpoint="$endpoint")

        rclone config delete "$S3_REMOTE" &> /dev/null
        rclone config create "$S3_REMOTE" s3 "${params[@]}" --non-interactive > /dev/null \
            || die "Gagal membuat remote rclone '$S3_REMOTE'."
        chmod 600 "$(rclone config file 2>/dev/null | tail -n1)" 2>/dev/null
        ok "Remote '$S3_REMOTE' ($provider) disimpan di $(rclone config file 2>/dev/null | tail -n1)."
    fi

    check_s3_bucket "$S3_BUCKET"
}

# Cek akses bucket S3 via rclone, tawarkan membuatnya jika belum ada
check_s3_bucket() {
    local bucket="$1"
    info "Menguji akses bucket '$bucket'..."
    if rclone lsf "$S3_REMOTE:$bucket" --max-depth 1 --dirs-only &> /dev/null; then
        ok "Bucket '$bucket' dapat diakses."
    elif ask_yes_no "Bucket '$bucket' tidak dapat diakses. Coba buat bucket?" "n"; then
        if rclone mkdir "$S3_REMOTE:$bucket"; then
            ok "Bucket '$bucket' dibuat."
        else
            warn "Gagal membuat bucket '$bucket'. Periksa kredensial/permission."
        fi
    else
        warn "Lanjut tanpa verifikasi bucket '$bucket'."
    fi
}

# Bucket default sesuai storage yang dipilih
default_bucket() {
    case "$STORAGE_TYPE" in
        rustfs) echo "$RUSTFS_BUCKET" ;;
        s3)     echo "$S3_BUCKET" ;;
    esac
}

# Tanya bucket tujuan per baris dbs; echo kosong = pakai bucket default
ask_bucket() {
    [ "$STORAGE_TYPE" = "local" ] && return
    local def bucket
    def=$(default_bucket)
    while true; do
        bucket=$(ask "Bucket tujuan (kosongkan = default '$def')" "")
        no_space "Bucket" "$bucket" && break
    done
    [ "$bucket" = "$def" ] && bucket=""
    if [ -n "$bucket" ] && [ "$STORAGE_TYPE" = "s3" ]; then
        check_s3_bucket "$bucket" >&2
    fi
    echo "$bucket"
}

# ==============================================================================
# Konfigurasi database
# ==============================================================================

configure_databases() {
    title "4. Daftar Database"

    local mode="new"
    if [ -f "$DBS_FILE" ] && grep -qvE '^\s*(#|$)' "$DBS_FILE"; then
        echo "Database yang sudah terdaftar:"
        grep -vE '^\s*(#|$)' "$DBS_FILE" | awk -v def="$(default_bucket)" '{
            b = ($5 != "" && $5 !~ /^#/) ? $5 : "(default" (def != "" ? ": " def : "") ")"
            printf "  - %s@%s (user: %s) -> bucket %s\n", $2, $1, $3, b
        }'
        echo "  1) Pertahankan  2) Tambah  3) Ganti semua"
        local choice
        while true; do
            choice=$(ask "Pilih" "1")
            case "$choice" in
                1) ok "Daftar database dipertahankan."; return ;;
                2) mode="append"; break ;;
                3) mode="new"; break ;;
            esac
        done
    fi

    echo "Mode pendaftaran database:"
    echo "  1) Semua database di satu server (auto-discover, cocok untuk server dengan banyak DB)"
    echo "  2) Input per database"
    local reg_mode
    while true; do
        reg_mode=$(ask "Pilih" "1")
        [[ "$reg_mode" =~ ^[12]$ ]] && break
    done

    local entries=() host name user pass bucket
    if [ "$reg_mode" = "1" ]; then
        while true; do
            echo
            while host=$(ask_required "Host server database" "localhost"); ! no_space "Host" "$host"; do :; done
            while user=$(ask_required "User (disarankan user khusus backup)" ""); ! no_space "User" "$user"; do :; done
            while pass=$(ask_secret "Password"); ! no_space "Password" "$pass"; do :; done

            info "Menguji koneksi dan mengambil daftar database..."
            local list
            if list=$(MYSQL_PWD="$pass" mysql -h "$host" -u "$user" -N -B -e "SHOW DATABASES" 2>&1); then
                list=$(echo "$list" | grep -vxE 'information_schema|performance_schema|mysql|sys')
                ok "Terhubung. Database yang akan di-backup ($(echo "$list" | grep -c .)):"
                echo "$list" | sed 's/^/    - /'
            else
                warn "Koneksi gagal: $list"
                ask_yes_no "Tetap simpan host ini?" "n" || continue
            fi

            bucket=$(ask_bucket)
            entries+=("$host * $user $pass${bucket:+ $bucket}")
            ask_yes_no "Tambah server database lain?" "n" || break
        done

        EXCLUDE_DBS=$(ask "Database yang dikecualikan (pisahkan spasi, kosongkan jika tidak ada)" "$EXCLUDE_DBS")
    fi

    while [ "$reg_mode" = "2" ]; do
        echo
        while host=$(ask_required "Host database" "localhost"); ! no_space "Host" "$host"; do :; done
        while name=$(ask_required "Nama database" ""); ! no_space "Nama database" "$name"; do :; done
        while user=$(ask_required "User" ""); ! no_space "User" "$user"; do :; done
        while pass=$(ask_secret "Password"); ! no_space "Password" "$pass"; do :; done
        bucket=$(ask_bucket)
        entries+=("$host $name $user $pass${bucket:+ $bucket}")
        ok "Ditambahkan: $name@$host -> bucket ${bucket:-default}"
        ask_yes_no "Tambah database lain?" "n" || break
    done

    umask 077
    if [ "$mode" = "new" ]; then
        echo "# DB_HOST DB_NAME DB_USER DB_PASS [BUCKET]" > "$DBS_FILE"
    fi
    printf '%s\n' "${entries[@]}" >> "$DBS_FILE"
    chmod 600 "$DBS_FILE"
    ok "Daftar database disimpan di dbs (permission 600)."
}

configure_tuning() {
    title "5. Performa & Kompresi"
    local cpus threads
    cpus=$(nproc 2>/dev/null || echo 4)
    echo "  Jumlah thread mydumper per database. CPU di mesin ini: $cpus."
    echo "  Lebih besar = lebih cepat, tetapi beban ke server database juga lebih tinggi."
    while true; do
        threads=$(ask "Jumlah thread" "${MYDUMPER_THREADS:-4}")
        [[ "$threads" =~ ^[1-9][0-9]*$ ]] && break
        echo "  Masukkan angka >= 1." >&2
    done
    MYDUMPER_THREADS="$threads"
    ok "mydumper memakai $MYDUMPER_THREADS thread."

    echo
    echo "  Kompresi arsip (satu file per database):"
    echo "    1) xz   - ukuran paling kecil, restore cukup tar + xz (bawaan Debian/Ubuntu)"
    echo "    2) zstd - hampir sekecil xz & lebih cepat, restore butuh paket zstd"
    echo "    3) gzip - paling kompatibel, ukuran paling besar"
    echo "    4) tanpa kompresi"
    local default_choice=1 choice
    case "$COMPRESS" in zstd) default_choice=2 ;; gzip) default_choice=3 ;; none) default_choice=4 ;; esac
    while true; do
        choice=$(ask "Pilih kompresi" "$default_choice")
        case "$choice" in
            1) COMPRESS="xz";   local min=0 max=9  def=6 ;;
            2) COMPRESS="zstd"; local min=1 max=19 def=19 ;;
            3) COMPRESS="gzip"; local min=1 max=9  def=9 ;;
            4) COMPRESS="none" ;;
            *) continue ;;
        esac
        break
    done

    if [ "$COMPRESS" = "none" ]; then
        COMPRESS_LEVEL=""
        ok "Arsip tidak dikompres (.tar)."
        return
    fi

    # Pakai level lama hanya jika algoritmanya sama dengan sebelumnya
    local prev_level=""
    [ "$COMPRESS" = "$PREV_COMPRESS" ] && prev_level="$COMPRESS_LEVEL"
    local level
    while true; do
        level=$(ask "Level kompresi $COMPRESS ($min-$max, lebih tinggi = lebih kecil tapi lebih lambat)" "${prev_level:-$def}")
        [[ "$level" =~ ^[0-9]+$ ]] && [ "$level" -ge "$min" ] && [ "$level" -le "$max" ] && break
        echo "  Masukkan angka $min-$max." >&2
    done
    COMPRESS_LEVEL="$level"
    ok "Kompresi: $COMPRESS level $COMPRESS_LEVEL."
}

# ==============================================================================
# Jadwal cron
# ==============================================================================

configure_cron() {
    title "6. Jadwal Backup Otomatis (cronjob)"
    local default_enable="y"
    [ "$CRON_ENABLED" = "no" ] && default_enable="n"

    if ! ask_yes_no "Pasang cronjob untuk menjalankan backup otomatis?" "$default_enable"; then
        CRON_ENABLED="no"
        ( crontab -l 2>/dev/null | grep -vF "$CRON_MARKER" ) | crontab - 2>/dev/null
        info "Cronjob tidak dipasang (entri lama dihapus jika ada)."
        return
    fi

    # Jam: satu atau lebih, dipisah koma
    local times t valid
    while true; do
        times=$(ask "Jam backup (HH:MM 24 jam, pisahkan koma untuk beberapa jam, contoh 02:00,14:00)" "${CRON_TIME:-02:00}")
        times="${times// /}"
        valid=1
        IFS=',' read -r -a time_list <<< "$times"
        [ "${#time_list[@]}" -gt 0 ] || valid=0
        for t in "${time_list[@]}"; do
            [[ "$t" =~ ^([01]?[0-9]|2[0-3]):[0-5][0-9]$ ]] || { valid=0; echo "  Jam tidak valid: '$t'" >&2; }
        done
        [ "$valid" -eq 1 ] && break
    done

    # Hari
    echo "  Hari backup:"
    echo "    1) Setiap hari"
    echo "    2) Hari tertentu (0=Minggu ... 6=Sabtu, contoh: 1-5 atau 0,3,5)"
    local day_choice days
    day_choice=$([ -z "$CRON_DAYS" ] || [ "$CRON_DAYS" = "*" ] && echo 1 || echo 2)
    while true; do
        day_choice=$(ask "Pilih" "$day_choice")
        [[ "$day_choice" =~ ^[12]$ ]] && break
    done
    if [ "$day_choice" = "1" ]; then
        days="*"
    else
        while true; do
            days=$(ask "Hari (format cron)" "$([ "$CRON_DAYS" != "*" ] && echo "$CRON_DAYS" || echo "1-5")")
            days="${days// /}"
            [[ "$days" =~ ^[0-7]([-,][0-7])*$ ]] && break
            echo "  Format hari tidak valid, contoh: 1-5 atau 0,3,5" >&2
        done
    fi

    CRON_ENABLED="yes"
    CRON_TIME="$times"
    CRON_DAYS="$days"

    local lines=() hour minute
    for t in "${time_list[@]}"; do
        hour=$((10#${t%%:*})); minute=$((10#${t##*:}))
        lines+=("$minute $hour * * $days \"$RUNNER\" >> \"$SCRIPT_DIR/cron.log\" 2>&1 $CRON_MARKER")
    done

    ( crontab -l 2>/dev/null | grep -vF "$CRON_MARKER"; printf '%s\n' "${lines[@]}" ) | crontab - \
        || die "Gagal memasang crontab."
    ok "Cronjob terpasang untuk user $(id -un):"
    crontab -l | grep -F "$CRON_MARKER" | sed 's/^/    /'
}

# ==============================================================================
# Simpan konfigurasi & runner
# ==============================================================================

save_config() {
    title "7. Menyimpan Konfigurasi"
    umask 077
    {
        echo "# Dibuat oleh install.sh pada $(date '+%Y-%m-%d %H:%M:%S')"
        printf 'STORAGE_TYPE=%q\n' "$STORAGE_TYPE"
        printf 'RUSTFS_ALIAS=%q\n' "$RUSTFS_ALIAS"
        printf 'RUSTFS_BUCKET=%q\n' "$RUSTFS_BUCKET"
        printf 'S3_BUCKET=%q\n' "$S3_BUCKET"
        printf 'S3_PREFIX=%q\n' "$S3_PREFIX"
        printf 'S3_REMOTE=%q\n' "$S3_REMOTE"
        printf 'CRON_ENABLED=%q\n' "${CRON_ENABLED:-no}"
        printf 'CRON_TIME=%q\n' "$CRON_TIME"
        printf 'CRON_DAYS=%q\n' "${CRON_DAYS:-*}"
        printf 'EXCLUDE_DBS=%q\n' "$EXCLUDE_DBS"
        printf 'MYDUMPER_THREADS=%q\n' "${MYDUMPER_THREADS:-4}"
        printf 'COMPRESS=%q\n' "${COMPRESS:-xz}"
        printf 'COMPRESS_LEVEL=%q\n' "$COMPRESS_LEVEL"
    } > "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
    chmod +x "$SCRIPT_DIR/backupdb.sh" "$SCRIPT_DIR/upload-rustfs.sh" "$SCRIPT_DIR/upload-s3.sh" "$RUNNER" 2>/dev/null
    mkdir -p "$SCRIPT_DIR/result" "$SCRIPT_DIR/history"
    ok "Pengaturan disimpan di .config"
}

summary() {
    title "Selesai"
    echo "  Tujuan upload : $STORAGE_TYPE"
    case "$STORAGE_TYPE" in
        rustfs) echo "  Target        : $RUSTFS_ALIAS/$RUSTFS_BUCKET/<tanggal>/" ;;
        s3)     echo "  Target        : $S3_REMOTE:$S3_BUCKET${S3_PREFIX:+/$S3_PREFIX}/<tanggal>/ (rclone)" ;;
    esac
    echo "  Thread dumper : $MYDUMPER_THREADS"
    echo "  Kompresi      : ${COMPRESS:-xz}${COMPRESS_LEVEL:+ level $COMPRESS_LEVEL}"
    [ -n "$EXCLUDE_DBS" ] && echo "  DB dikecualikan: $EXCLUDE_DBS"
    if [ "$CRON_ENABLED" = "yes" ]; then
        echo "  Cronjob       : jam $CRON_TIME, hari $([ "$CRON_DAYS" = "*" ] && echo "setiap hari" || echo "$CRON_DAYS")"
        crontab -l 2>/dev/null | grep -F "$CRON_MARKER" | sed 's/^/                  /'
    else
        echo "  Cronjob       : tidak aktif"
    fi
    echo
    echo "  Saran: gunakan user MySQL khusus backup dengan privilege minimal, contoh:"
    echo "    CREATE USER 'backup'@'<ip-server-backup>' IDENTIFIED BY '<password>';"
    echo "    GRANT SELECT, SHOW VIEW, TRIGGER, EVENT, LOCK TABLES, RELOAD, PROCESS, REPLICATION CLIENT ON *.* TO 'backup'@'<ip-server-backup>';"
    echo
    echo "  Jalankan manual : $RUNNER"
    echo "  Ubah pengaturan : jalankan ulang $SCRIPT_DIR/install.sh"
    echo

    if ask_yes_no "Jalankan backup sekarang untuk uji coba?" "n"; then
        "$RUNNER"
    fi
}

# ==============================================================================
# Eksekusi Utama
# ==============================================================================

main() {
    echo "=================================================="
    echo "   Installer mysql-backuper (Debian / Ubuntu)"
    echo "=================================================="

    [ -t 0 ] || die "Installer ini interaktif, jalankan langsung dari terminal."

    check_os
    setup_sudo
    detect_arch
    load_existing_config

    choose_storage
    install_apt_packages
    case "$STORAGE_TYPE" in
        rustfs) install_rc; configure_rustfs ;;
        s3)     install_rclone; configure_s3 ;;
        local)  title "3. Konfigurasi Storage"; info "Mode lokal: hasil backup tetap di folder result/." ;;
    esac
    configure_databases
    configure_tuning
    configure_cron
    save_config
    summary
}

main "$@"
