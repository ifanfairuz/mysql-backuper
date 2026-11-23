# MySQL Backup & RustFS Automation Scripts

Kumpulan skrip otomatisasi berbasis Bash untuk melakukan _backup_ database MySQL/MariaDB menggunakan **mydumper**, melakukan kompresi arsip, mengunggah hasilnya ke objek storage menggunakan **RustFS client (`rc`)**, serta mengelola riwayat (_history_) arsip dan log secara otomatis.

---

## 🚀 Instalasi Cepat (Debian / Ubuntu)

```bash
./install.sh
```

Installer akan menanyakan secara interaktif lalu:

1. Memilih tujuan upload: **RustFS**, **S3 / S3-compatible**, atau **lokal saja**.
2. Menginstal dependensi via `apt` (`mydumper`, `default-mysql-client`, `xz-utils`, `zstd`, `pigz`, `cron`, dll) serta `rc` (RustFS CLI) atau `rclone` (S3) versi terbaru sesuai pilihan.
3. Mengatur kredensial storage (`rc alias set` / `rclone config create`) dan menguji koneksi.
4. Mendaftarkan database ke file `dbs` (permission 600): **semua DB di satu server (auto-discover)** atau per database, plus daftar DB yang dikecualikan.
5. Menentukan jumlah thread `mydumper` serta algoritma & level kompresi (default **xz**).
6. Memasang **cronjob** di jam tertentu (bisa beberapa jam, mis. `02:00,14:00`) dan hari tertentu (mis. `1-5`). Log cron di `cron.log`.
7. Menyimpan pengaturan ke `.config`.

Jalankan ulang `./install.sh` kapan saja untuk mengubah pengaturan; nilai lama dipakai sebagai default. Backup manual: `./run-backup.sh`.

## 🔁 Alur Backup (pipeline per database)

`run-backup.sh` (yang dijalankan cron) memproses database **satu per satu** dan langsung meng-upload hasilnya:

```text
DB A: dump -> tar.xz -> upload -> pindah ke history/
DB B: dump -> tar.xz -> upload -> pindah ke history/
...
Sweep: upload sisa file di result/ (yang gagal + log global), hapus history > 3 hari
```

- Disk lokal cukup untuk 1 DB terbesar, bukan total semua DB.
- Jika satu DB/upload gagal, DB lain tetap diproses; file yang gagal tetap di `result/` dan dicoba lagi saat sweep / run berikutnya.
- Lock (`flock`) mencegah dua backup berjalan bersamaan.

### Format `dbs`

```text
# DB_HOST   DB_NAME  DB_USER  DB_PASS
10.0.0.5    *        backup   rahasia     # semua DB di server (kecuali system DB & EXCLUDE_DBS)
10.0.0.6    app      app_user rahasia2    # satu DB tertentu
```

### Pengaturan di `.config`

| Variabel | Keterangan |
|---|---|
| `STORAGE_TYPE` | `rustfs`, `s3`, atau `local` |
| `EXCLUDE_DBS` | DB yang dilewati saat auto-discover (`*`), dipisah spasi |
| `MYDUMPER_THREADS` | Jumlah thread mydumper per DB (default 4) |
| `COMPRESS` | `xz` (default) / `zstd` / `gzip` / `none` |
| `COMPRESS_LEVEL` | Level kompresi (default: xz 6, zstd 19, gzip 9) |
| `COMPRESS_THREADS` | Thread kompresor xz/zstd (default 0 = semua core; turunkan jika RAM terbatas) |

### Kompresi

Setiap DB dibungkus menjadi **satu arsip** (satu stream `tar | kompresor`) agar rasio kompresinya maksimal. Log global mencatat ukuran sebelum & sesudah kompresi beserta rasionya, misalnya `Ukuran: 12GiB -> 1.4GiB (rasio 8.6x, 410s)`.

| `COMPRESS` | Arsip | Ukuran | Kecepatan | Butuh apa saat restore |
|---|---|---|---|---|
| `xz` (default) | `.tar.xz` | paling kecil | lambat (multi-thread) | `tar` + `xz` (bawaan Debian/Ubuntu) |
| `zstd` | `.tar.zst` | hampir setara xz | cepat | paket `zstd` |
| `gzip` | `.tar.gz` | paling besar | sedang (pigz) | `tar` + `gzip` (ada di semua sistem) |
| `none` | `.tar` | mentah | paling cepat | `tar` |
| `CRON_TIME` / `CRON_DAYS` | Jadwal cronjob (mis. `02:00,14:00` / `*` atau `1-5`) |

## 📁 Struktur Direktori Proyek

```text
.
├── install.sh             # Installer interaktif (Debian/Ubuntu): deps + pengaturan + cron
├── run-backup.sh          # Runner: backup lalu upload sesuai .config (dipakai cron)
├── backupdb.sh            # Skrip utama untuk backup database
├── upload-rustfs.sh       # Skrip untuk upload hasil backup ke RustFS
├── upload-s3.sh           # Skrip untuk upload hasil backup ke S3 / S3-compatible (rclone)
├── dbs                    # File konfigurasi daftar database
├── .config                # Pengaturan hasil install.sh
├── result/                # Folder penyimpanan sementara dan hasil backup lokal
└── history/               # Arsip file backup dan log harian (format: YYYYMMDD/)
```

## ☁️ Upload ke S3 (`upload-s3.sh`)

Memakai **[rclone](https://rclone.org/)**: satu binary, mendukung AWS S3 dan semua S3-compatible (Cloudflare R2, MinIO, Wasabi, DigitalOcean Spaces, dll), dengan multipart upload dan retry otomatis untuk file backup besar. Remote dibuat oleh `install.sh` (atau manual lewat `rclone config`).

```bash
./upload-s3.sh <nama_bucket> [prefix] [file...]

# Contoh: upload semua isi result/ ke s3backup:my-backup-bucket/mysql/YYYYMMDD/
./upload-s3.sh my-backup-bucket mysql

# Memakai remote rclone lain dan opsi tambahan
S3_REMOTE=r2 RCLONE_EXTRA_ARGS="--bwlimit 20M" ./upload-s3.sh my-backup-bucket
```

| Env | Keterangan |
|---|---|
| `S3_REMOTE` | Nama remote rclone (default `s3backup`) |
| `RCLONE_EXTRA_ARGS` | Opsi tambahan rclone, mis. `--bwlimit 20M` untuk membatasi bandwidth |

File yang berhasil di-upload dipindahkan ke `history/YYYYMMDD/`, log upload disimpan di folder yang sama, dan history lebih dari 3 hari dihapus otomatis.

## ♻️ Restore Database

Isi arsip adalah output mydumper (file SQL biasa): `<db>-schema-create.sql`, `<db>.<tabel>-schema.sql`, `<db>.<tabel>.00000.sql`, dan `metadata`. Restore paling cepat memakai **myloader** (terpasang bersama paket `mydumper`).

### 1. Cari file backup

Backup 3 hari terakhir masih ada di lokal: `history/YYYYMMDD/backup_<db>_<timestamp>.tar.xz`.

Yang lebih lama bisa diambil dari storage:

```bash
# S3 (rclone)
rclone lsf s3backup:my-backup-bucket/mysql/                    # daftar tanggal
rclone lsf s3backup:my-backup-bucket/mysql/20261123/           # daftar file pada tanggal tsb

# RustFS (rc)
rc ls backup/my-backup-bucket/20261123/                        # lihat `rc --help` untuk perintah list
```

### 2. Download

```bash
mkdir -p ~/restore && cd ~/restore

# S3 (rclone)
rclone copy s3backup:my-backup-bucket/mysql/20261123/backup_app_20261123_020000.tar.xz . -P

# RustFS (rc)
rc object copy backup/my-backup-bucket/20261123/backup_app_20261123_020000.tar.xz ./
```

### 3. Ekstrak

GNU `tar` mendeteksi format kompresi secara otomatis:

```bash
tar -xf backup_app_20261123_020000.tar.xz        # juga untuk .tar.gz, .tar, dan .tar.zst (jika zstd terpasang)
```

Atau secara eksplisit per format:

```bash
tar -xJf backup_app_*.tar.xz                                   # xz
zstd -d --long=27 -c backup_app_*.tar.zst | tar -xf -          # zstd
tar -xzf backup_app_*.tar.gz                                   # gzip
```

Hasilnya berupa folder `temp_app_20261123_020000/`.

### 4. Restore dengan myloader

**Disarankan:** restore ke database baru dulu, periksa hasilnya, baru alihkan aplikasi. Cara ini lebih aman daripada langsung menimpa DB produksi.

```bash
myloader \
  --host=10.0.0.5 --user=root --ask-password \
  --directory=temp_app_20261123_020000 \
  --source-db=app \
  --database=app_restore \
  --threads=4 \
  --verbose=3
```

- `--source-db` adalah nama DB di backup, sedangkan `--database` adalah nama DB tujuan (dibuat otomatis jika belum ada).
- Untuk **menimpa** DB yang sudah ada (tabel di-drop lalu dibuat ulang), pakai `--database=app --overwrite-tables`.
- Jika `--ask-password` tidak tersedia di versi myloader Anda, pakai `--password='...'`.
- myloader secara default tidak menulis ke binlog. Tambahkan `--enable-binlog` jika hasil restore perlu ikut tereplikasi ke replica.

### 5. Verifikasi

```bash
mysql -h 10.0.0.5 -u root -p -e "
  SELECT table_name, table_rows
  FROM information_schema.tables
  WHERE table_schema = 'app_restore'
  ORDER BY table_name;"
```

Bandingkan jumlah tabel dan baris dengan DB asli. Posisi binlog/GTID saat backup diambil tercatat di file `temp_app_*/metadata`; ini berguna untuk point-in-time recovery.

### Restore satu tabel saja

```bash
mkdir one_table
cp temp_app_*/metadata temp_app_*/app-schema-create.sql one_table/ 2>/dev/null
cp temp_app_*/app.orders-schema.sql temp_app_*/app.orders.*.sql one_table/

myloader --host=10.0.0.5 --user=root --ask-password \
  --directory=one_table --source-db=app --database=app_restore --threads=4
```

### Restore darurat tanpa myloader

File di dalam arsip berupa SQL biasa, jadi bisa di-import dengan client `mysql`:

```bash
cd temp_app_20261123_020000
mysql -h 10.0.0.5 -u root -p -e "CREATE DATABASE IF NOT EXISTS app_restore"
for f in *-schema.sql;     do mysql -h 10.0.0.5 -u root -p"$PASS" app_restore < "$f"; done   # struktur tabel
for f in *.[0-9]*.sql;     do mysql -h 10.0.0.5 -u root -p"$PASS" app_restore < "$f"; done   # data
```

Cara ini lebih lambat (tanpa paralel) dan view/trigger/routine (`*-schema-view.sql`, `*-schema-triggers.sql`, `*-schema-post.sql`) perlu di-import manual setelah data.

### Restore semua DB dari satu tanggal

```bash
for f in backup_*_20261123_*.tar.xz; do tar -xf "$f"; done
for d in temp_*_20261123_*/; do
  db=$(basename "$d" | sed -E 's/^temp_(.*)_[0-9]{8}_[0-9]{6}$/\1/')
  myloader --host=10.0.0.5 --user=root --password="$PASS" \
    --directory="$d" --source-db="$db" --database="$db" --overwrite-tables --threads=4
done
```

> 💡 Lakukan uji restore secara berkala (misalnya sebulan sekali) ke server staging. Backup yang tidak pernah diuji restore belum terbukti bisa dipakai.
