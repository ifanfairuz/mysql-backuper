# MySQL Backup & RustFS Automation Scripts

Kumpulan skrip otomatisasi berbasis Bash untuk melakukan _backup_ database MySQL/MariaDB menggunakan **mydumper**, melakukan kompresi arsip, mengunggah hasilnya ke objek storage menggunakan **RustFS client (`rc`)**, serta mengelola riwayat (_history_) arsip dan log secara otomatis.

---

## 🚀 Instalasi Cepat (Debian / Ubuntu)

```bash
./install.sh
```

Installer akan menanyakan secara interaktif lalu:

1. Memilih tujuan upload: **RustFS**, **S3 / S3-compatible**, atau **lokal saja**.
2. Menginstal dependensi via `apt` (`mydumper`, `default-mysql-client`, `pigz`, `cron`, dll) serta `rc` (RustFS CLI) atau AWS CLI v2 sesuai pilihan.
3. Mengatur kredensial storage (`rc alias set` / `aws configure --profile`) dan menguji koneksi.
4. Mendaftarkan database ke file `dbs` (permission 600): **semua DB di satu server (auto-discover)** atau per database, plus daftar DB yang dikecualikan.
5. Menentukan jumlah thread `mydumper`.
6. Memasang **cronjob** di jam tertentu (bisa beberapa jam, mis. `02:00,14:00`) dan hari tertentu (mis. `1-5`). Log cron di `cron.log`.
7. Menyimpan pengaturan ke `.config`.

Jalankan ulang `./install.sh` kapan saja untuk mengubah pengaturan; nilai lama dipakai sebagai default. Backup manual: `./run-backup.sh`.

## 🔁 Alur Backup (pipeline per database)

`run-backup.sh` (yang dijalankan cron) memproses database **satu per satu** dan langsung meng-upload hasilnya:

```text
DB A: dump -> tar.gz -> upload -> pindah ke history/
DB B: dump -> tar.gz -> upload -> pindah ke history/
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
| `CRON_TIME` / `CRON_DAYS` | Jadwal cronjob (mis. `02:00,14:00` / `*` atau `1-5`) |

## 📁 Struktur Direktori Proyek

```text
.
├── install.sh             # Installer interaktif (Debian/Ubuntu): deps + pengaturan + cron
├── run-backup.sh          # Runner: backup lalu upload sesuai .config (dipakai cron)
├── backupdb.sh            # Skrip utama untuk backup database
├── upload-rustfs.sh       # Skrip untuk upload hasil backup ke RustFS
├── upload-s3.sh           # Skrip untuk upload hasil backup ke S3 / S3-compatible (AWS CLI)
├── dbs                    # File konfigurasi daftar database
├── .config                # Pengaturan hasil install.sh
├── result/                # Folder penyimpanan sementara dan hasil backup lokal
└── history/               # Arsip file backup dan log harian (format: YYYYMMDD/)
```

## ☁️ Upload ke S3 (`upload-s3.sh`)

Membutuhkan **AWS CLI (`aws`)** yang sudah dikonfigurasi kredensialnya (`aws configure`).

```bash
./upload-s3.sh <nama_bucket> [prefix]

# Contoh: upload ke s3://my-backup-bucket/mysql/YYYYMMDD/
./upload-s3.sh my-backup-bucket mysql

# S3-compatible (MinIO, Cloudflare R2, Wasabi, dll) dengan profile tertentu
AWS_PROFILE=backup S3_ENDPOINT_URL=https://s3.example.com ./upload-s3.sh my-backup-bucket
```

File di `result/` yang berhasil di-upload dipindahkan ke `history/YYYYMMDD/`, log upload disimpan di folder yang sama, dan history lebih dari 3 hari dihapus otomatis.
