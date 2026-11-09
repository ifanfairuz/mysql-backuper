# MySQL Backup & RustFS Automation Scripts

Kumpulan skrip otomatisasi berbasis Bash untuk melakukan _backup_ database MySQL/MariaDB menggunakan **mydumper**, melakukan kompresi arsip, mengunggah hasilnya ke objek storage menggunakan **RustFS client (`rc`)**, serta mengelola riwayat (_history_) arsip dan log secara otomatis.

---

## 📁 Struktur Direktori Proyek

```text
.
├── backupdb.sh            # Skrip utama untuk backup database
├── upload-rustfs.sh       # Skrip untuk upload hasil backup ke RustFS
├── dbs                    # File konfigurasi daftar database
├── result/                # Folder penyimpanan sementara dan hasil backup lokal
└── history/               # Arsip file backup dan log harian (format: YYYYMMDD/)
```
