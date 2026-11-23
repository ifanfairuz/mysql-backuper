# MySQL Backup & RustFS Automation Scripts

Kumpulan skrip otomatisasi berbasis Bash untuk melakukan _backup_ database MySQL/MariaDB menggunakan **mydumper**, melakukan kompresi arsip, mengunggah hasilnya ke objek storage menggunakan **RustFS client (`rc`)**, serta mengelola riwayat (_history_) arsip dan log secara otomatis.

---

## 📁 Struktur Direktori Proyek

```text
.
├── backupdb.sh            # Skrip utama untuk backup database
├── upload-rustfs.sh       # Skrip untuk upload hasil backup ke RustFS
├── upload-s3.sh           # Skrip untuk upload hasil backup ke S3 / S3-compatible (AWS CLI)
├── dbs                    # File konfigurasi daftar database
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
