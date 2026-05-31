# Smart Modem Watchdog for OpenWrt + ModemManager

Script watchdog untuk OpenWrt yang bertugas memantau dan memulihkan koneksi modem seluler secara otomatis, khususnya untuk modem rakitan yang kadang mengalami:

* koneksi lost connection,
* IP operator berubah,
* `tethering` down,
* `wwan0` down,
* bearer ModemManager bengong,
* modem USB tidak merespons,
* koneksi terlihat aktif tetapi tidak bisa ping internet.

Script utama: `reboot.sh`

---

## Fitur

* Cek koneksi otomatis setiap 1 menit melalui cron.
* Memaksa logical interface OpenWrt hidup ulang.
* Memaksa device `wwan0` aktif ulang.
* Recovery ringan lebih dahulu sebelum reset modem berat.
* Mendukung ModemManager recovery.
* Mendukung AT command fallback.
* Mendukung USB reauthorization fallback.
* Menggunakan lock file agar tidak terjadi proses ganda.
* Menggunakan fail counter agar tidak reset karena ping gagal sesaat.
* Menggunakan cooldown agar modem tidak di-reset terus-menerus saat operator gangguan.
* Tidak melakukan `uci commit` setiap menit sehingga lebih aman untuk flash OpenWrt.
* Menyediakan mode status dan reset state.

---

## Instalasi

Salin file `reboot.sh` ke `/root/reboot.sh`.

Lalu jalankan:

```sh
chmod +x /root/reboot.sh
sh /root/reboot.sh --install-cron
sh /root/reboot.sh --reset-state
```

Cek cron:

```sh
crontab -l
```

Cron yang benar:

```sh
* * * * sh /root/reboot.sh
```

Jangan menggunakan cron seperti ini:

```sh
* * * * sh /root/reboot.sh --install-cron
```

---

## Konfigurasi Utama

Sesuaikan bagian ini jika nama interface perangkat Anda berbeda:

```sh
NETIF="tethering"
PHYSDEV="wwan0"
TTYDEV="/dev/ttyUSB0"
```

Cek interface ModemManager:

```sh
uci show network | grep modemmanager
```

Cek device modem:

```sh
ip link
```

Cek port AT modem:

```sh
ls /dev/ttyUSB*
```

Tes AT command:

```sh
echo AT | atinout - /dev/ttyUSB0 -
```

---

## Perintah Operasional

Cek status:

```sh
sh /root/reboot.sh --status
```

Reset state:

```sh
sh /root/reboot.sh --reset-state
```

Perbaiki konfigurasi UCI:

```sh
sh /root/reboot.sh --fix-uci
```

Install cron:

```sh
sh /root/reboot.sh --install-cron
```

---

## Monitoring Log

Pantau log:

```sh
tail -f /tmp/reboot.log
```

Contoh log normal:

```text
=== Watchdog check started ===
Force bringing up logical interface: tethering
Connection healthy
```

Contoh log saat recovery ringan berhasil:

```text
Connectivity failed 1/2
Waiting next cycle before deep recovery
Connectivity failed 2/2
RECOVERED via force_tethering_up
```

---

## Tes Manual

Tes `tethering` down:

```sh
ifdown tethering
sleep 5
sh /root/reboot.sh
tail -n 80 /tmp/reboot.log
```

Tes `wwan0` down:

```sh
ip link set wwan0 down
sleep 5
sh /root/reboot.sh
tail -n 80 /tmp/reboot.log
```

Hasil ideal:

```text
RECOVERED via force_tethering_up
```

---

## Parameter Penting

Nilai stabil untuk pemakaian harian:

```sh
FAILS_REQUIRED=2
COOLDOWN_SECONDS=180
PING_TARGETS="1.1.1.1 8.8.8.8 104.17.3.81"
```

Jika ingin recovery lebih agresif:

```sh
FAILS_REQUIRED=1
```

Jika operator sering gangguan lama:

```sh
COOLDOWN_SECONDS=300
```

---

## Urutan Recovery

```text
1. Cek koneksi
2. Paksa logical interface tethering hidup
3. Paksa wwan0 hidup
4. Cek IP dan ping
5. Jika gagal 1 kali, tunggu siklus berikutnya
6. Jika gagal 2 kali, mulai recovery
7. force_tethering_up
8. ModemManager disconnect/disable/enable
9. Restart daemon ModemManager
10. mmcli modem reset
11. AT+CFUN=4 lalu AT+CFUN=1
12. AT+CFUN=1,1
13. USB reauthorization
14. Restart network service
```

---

## Troubleshooting Singkat

Jika cron terus menulis `Cron installed`, cek:

```sh
crontab -l
```

Pastikan hanya ada:

```sh
* * * * sh /root/reboot.sh
```

Jika `wwan0` tidak muncul:

```sh
ip link
mmcli -L
/etc/init.d/modemmanager restart
```

Jika AT command tidak merespons:

```sh
ls /dev/ttyUSB*
echo AT | atinout - /dev/ttyUSB0 -
echo AT | atinout - /dev/ttyUSB1 -
echo AT | atinout - /dev/ttyUSB2 -
```

Jika koneksi aktif tetapi tidak bisa internet:

```sh
ip addr show wwan0
ip route
ping -I wwan0 -c 3 1.1.1.1
nslookup google.com
```

---

## Catatan Penting

* Jangan menjalankan `--install-cron` di cron.
* Jangan terlalu sering melakukan `uci commit` karena dapat membebani flash.
* Script hanya melakukan commit saat `--install-cron` atau `--fix-uci`.
* Recovery ringan lebih aman daripada langsung `AT+CFUN=1,1`.
* Jika menggunakan ModemManager, AT command sebaiknya menjadi fallback, bukan tahap pertama.
* Jika `wwan0` hilang total, masalah biasanya berada di deteksi modem USB atau ModemManager, bukan hanya interface OpenWrt.

---

## Lisensi

Bebas digunakan dan dimodifikasi untuk kebutuhan pribadi.
::: 

Dibuat oleh : Galuh Adi Insani
