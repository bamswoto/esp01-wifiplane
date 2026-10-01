# esp01-wifiplane

Kode hasil modifikasi untuk ESP-12E yang menjalankan [WIFI-CONTROLLED-RC-PLANE](https://www.instructables.com/id/WIFI-CONTROLLED-RC-PLANE/) buatan [RAVI_BUTANI](https://www.instructables.com/member/RAVI_BUTANI/), pesawat RC DIY termurah, yang disetel untuk jangkauan maksimal.

**Perangkat keras**

* ESP-12E (atau ESP-12F, NodeMCU, Wemos D1 mini) dirangkai seperti [skema asli](Hardware/original-electronics.png), LED status di gpio2.

* Motor sesuai skema asli: motor kanan di gpio4 (T2, `MOTOR_KANAN`), motor kiri di gpio5 (T1, `MOTOR_KIRI`). HP dimiringkan ke kiri membuat motor kanan lebih kencang, sehingga pesawat belok kiri. Tombol trim kiri menambah motor kanan (trim ke kiri), tombol trim kanan menambah motor kiri.

* Tegangan baterai dibaca di A0 lewat pembagi tegangan 33k / 8.2k.

* PWM motor: bip saat menyala memakai nada yang terdengar (nada startup, lalu bip koneksi 1 kHz). Setelah bip koneksi selesai, PWM pindah ke 20 kHz (`PWM_FREQ_TERBANG`), di atas batas pendengaran, supaya motor coreless tidak berdenging saat terbang. Yang masih terdengar adalah suara putaran motor dan baling-baling. Isi `1000` untuk kembali ke perilaku lama.

* Skema asli tidak punya dioda flyback di motor. Disarankan memasang dioda Schottky paralel dengan tiap motor: katoda (sisi bergaris) ke + baterai, anoda ke kaki motor yang tersambung ke drain MOSFET. 1N5819 (40 V, 1 A, Schottky sehingga cocok untuk PWM 20 kHz) sudah cukup untuk motor coreless 820 di baterai 1S: arus rata-rata yang lewat dioda hanya sekitar 0,2–0,35 A. Versi SMD-nya, B5819W (atau SS14), sifatnya setara dan lebih ringan dari 1N5819 (DO-41, sekitar 0,3 g per buah). Pasang dengan kaki sependek mungkin, dekat motor atau MOSFET. Tanpa dioda, MOSFET menahan lonjakan tegangan setiap kali mati, dan di 20 kHz itu terjadi 20 kali lebih sering daripada di 1 kHz. Setelah uji gas penuh di darat (baling-baling dilepas), raba MOSFET: kalau terlalu panas dan belum ada dioda, pasang dioda atau turunkan `PWM_FREQ_TERBANG`.

**Sebelum flashing**

* Di sketch, isi `ssid_sta` / `pass_sta` (WiFi rumah untuk OTA, atau hotspot HP), `pass_ap` (minimal 8 karakter) dan `OTA_PASSWORD`. Jangan commit password asli.

* Samakan `BIND_ID` di sketch dan aplikasi, supaya HP atau pesawat lain yang memakai kode ini tidak bisa mengendalikan pesawat Anda.

* Build ulang aplikasi dari `ProcessingAndroidApp/wifiplane/wifiplane.pde` di Processing (mode Android). File `wifiplane.apk` bawaan adalah versi lama dan tidak bisa dipakai dengan firmware ini. Izin yang dibutuhkan aplikasi ada di `AndroidManifest.xml`, dan izin yang kurang ditampilkan di layar. File itu juga berisi `android:configChanges` supaya aplikasi tidak restart saat ganti mode MIRING / MANUAL. Kalau Anda menyalin kode ke sketch sendiri, salin juga `AndroidManifest.xml` ke folder sketch itu (atau tambahkan atribut `android:configChanges` dari file ini ke `<activity>` di manifest Anda). Tanpa itu, ganti mode tetap jalan tapi Android membuat ulang aplikasi, sehingga BG/EX kembali ke BG (trim tetap, karena disimpan).

**Flashing ke ESP-12E (Flash Size 4MB, FS:1MB OTA:~1019KB)**

Flashing pertama lewat flasher/burner USB, sekali saja. Setelah itu semua update lewat OTA.

1. Siapkan Arduino IDE:
   * File > Preferences > Additional boards manager URLs: `https://arduino.esp8266.com/stable/package_esp8266com_index.json`
   * Tools > Board > Boards Manager: pasang **esp8266 by ESP8266 Community versi 3.1.2** (versi yang dipakai untuk meng-compile dan menguji firmware ini). ESP8266WiFi, ArduinoOTA dan LittleFS sudah termasuk; tidak perlu library lain.
   * Di Linux/macOS, pastikan `python3` terpasang: core 3.1.2 memakainya untuk compile dan upload (di Windows sudah dibawa oleh core).

2. Buka `Arduino/wifiplane_esp8266/wifiplane_esp8266.ino` dan isi pengaturan di bagian **Sebelum flashing**.

3. Pengaturan menu Tools:

   | Menu | Pilihan |
   |---|---|
   | Board | Generic ESP8266 Module (atau NodeMCU 1.0 (ESP-12E Module); keduanya menghasilkan firmware yang setara) |
   | Flash Size | **4MB (FS:1MB OTA:~1019KB)** |
   | Flash Mode | DIO |
   | Flash Frequency | 40MHz |
   | CPU Frequency | 80 MHz |
   | Crystal Frequency | 26 MHz |
   | Reset Method | dtr (aka nodemcu) |
   | Upload Speed | 115200 (921600 kalau flasher Anda sanggup) |
   | Erase Flash | **All Flash Contents** untuk flashing USB pertama, setelah itu Only Sketch |

   Pada Generic ESP8266 Module, yang wajib diubah dari default hanya **Flash Size** (default 1MB) dan **Flash Mode** (default DOUT; DIO adalah mode yang dipakai ESP-12E, sama dengan NodeMCU), plus Erase Flash untuk flashing pertama. Pilihan lain di tabel sudah default; menu lain biarkan default.

4. Flashing pertama (USB):
   * Hubungkan ESP-12E ke flasher: TX flasher ke RX ESP, RX flasher ke TX ESP, GND bersama, catu 3,3 V. Agar masuk mode flash, saat ESP dinyalakan atau di-reset: GPIO0 = LOW, GPIO15 = LOW, GPIO2 = HIGH, EN = HIGH. Flasher/burner ESP-12 biasanya sudah mengatur ini; kalau flasher Anda pakai tombol, tahan FLASH (GPIO0), tekan RESET, lalu lepas keduanya.
   * Pilih port flasher di Tools > Port, lalu Upload.
   * Kalau setelah upload ESP belum berjalan, tekan RESET atau cabut-pasang daya tanpa menahan FLASH.
   * File system tidak perlu di-upload. LittleFS diformat otomatis saat pertama kali dipakai (core 3.1.2: auto-format aktif secara default).

5. Update berikutnya (OTA):
   * Nyalakan pesawat di rumah sampai tersambung ke WiFi rumah (3 bip), pastikan aplikasi remote tertutup, lalu tunggu sekitar 10 detik.
   * Tools > Port: pilih port jaringan `wifiplane-ota at 192.168.x.x` (PC harus satu jaringan dengan pesawat). Kalau belum muncul, tunggu sebentar atau buka ulang menu Port.
   * Upload, lalu masukkan `OTA_PASSWORD` saat diminta. Menu Erase Flash tidak berpengaruh untuk OTA.
   * **Pengaturan Tools harus sama dengan flashing pertama, terutama Flash Size.** Kalau Flash Size diganti, lokasi file system berubah: salinan rollback hilang (file system diformat ulang), atau rollback nonaktif kalau memilih ukuran tanpa FS.
   * Jangan cabut daya sekitar 10 detik setelah upload selesai, saat bootloader menyalin firmware baru.
   * Setelah upload firmware baru, biarkan pesawat menyala sekitar 2 menit dengan aplikasi tertutup supaya salinan versi baik tersimpan (lihat **Rollback**).

6. Cek setelah flashing: 3 bip = tersambung ke `ssid_sta` (mode STA); 2 bip = menjadi AP `wifiplane` (mode AP).

Kenapa 4MB (FS:1MB OTA:~1019KB):

* Firmware boleh sampai sekitar 1019 KB. Firmware ini sekarang sekitar 349 KB (356.960 byte, hasil compile dengan pengaturan di atas).
* Ruang OTA: firmware baru ditulis dulu ke flash yang kosong, jadi upload yang gagal tidak merusak firmware yang sedang jalan.
* File system LittleFS 1 MB (0x300000–0x3FA000, 1000 KB) untuk salinan rollback. Saat menyimpan salinan baru, salinan lama dan baru sempat ada bersamaan (sekitar 2 × 349 KB), jadi masih muat. Kalau kelak firmware lebih besar dari sekitar 480 KB, salinan baru tidak muat dan pesawat tetap memakai salinan lama.
* Pilihan tanpa file system (misalnya "4MB (FS:none OTA:~1019KB)") tetap bisa dipakai, tapi rollback nonaktif.

**Mode WiFi**

* Saat dinyalakan, pesawat mencoba tersambung ke `ssid_sta` (WiFi rumah atau hotspot HP) sampai 20 detik (`STA_TUNGGU_MS`, 3 bip kalau berhasil), supaya router yang lambat tidak membuat pesawat masuk mode AP.

* Kalau gagal, pesawat menjadi access point `wifiplane` di kanal 1, 6 atau 11 yang paling sepi (2 bip). Sambungkan HP ke WiFi ini. Di luar jangkauan WiFi rumah, AP siap sekitar 20 detik setelah pesawat dinyalakan.

* Update OTA (port Arduino IDE `wifiplane-ota`, meminta `OTA_PASSWORD`) lewat mode STA (WiFi rumah atau hotspot HP). Mode AP menjadi cadangan kalau STA tidak bisa tersambung: sambungkan PC ke `wifiplane`. Di kedua mode, OTA dan mDNS hanya berjalan saat aplikasi remote tidak terbuka: aktif setelah 10 detik tanpa paket kendali (`OTA_TUNDA_MS`) dan langsung mati begitu aplikasi mengirim lagi, sehingga tidak pernah berjalan saat terbang. Setelah pesawat dinyalakan tanpa aplikasi, tunggu sekitar 10 detik sebelum upload.

* Mode dipilih sekali saat pesawat dinyalakan dan dipertahankan sampai pesawat dimatikan.

**Mode aman**

* Kalau firmware crash 3 kali berturut-turut (reset karena exception atau watchdog, `CRASH_MAKS`), misalnya setelah update yang rusak, pesawat menyala dalam mode aman: motor tidak pernah digerakkan, tanpa bunyi bip, LED berkedip ganda setiap detik, dan hanya WiFi (STA, kalau gagal AP) dan OTA yang berjalan, dengan OTA langsung aktif. Upload firmware yang sudah diperbaiki lewat OTA, atau cabut lalu pasang lagi baterai untuk mencoba start normal.

* Setelah 30 detik berjalan normal (`STABIL_MS`), hitungan crash kembali ke 0. Hitungan ini disimpan di RTC memory, jadi mencabut baterai juga menghapusnya.

* Mode aman hanya menolong kalau firmware baru masih mengandung kode mode aman dan crash-nya terjadi setelah firmware mulai berjalan. Pertahankan kode mode aman di setiap versi yang Anda upload.

**Rollback**

* Upload OTA yang gagal (koneksi putus, password salah, MD5 tidak cocok, baterai dicabut saat upload) tidak pernah menyentuh firmware yang sedang berjalan: image baru ditulis dulu ke flash yang kosong dan baru disalin setelah MD5-nya cocok. Jangan cabut daya sekitar 10 detik setelah upload selesai, saat bootloader menyalinnya.

* Untuk upload yang berhasil tapi firmware-nya crash, pesawat menyimpan salinan firmware baik terakhir. Pakai Flash Size "4MB (FS:1MB OTA:~1019KB)" (lihat **Flashing ke ESP-12E**). Tanpa file system, rollback nonaktif dan crash berulang hanya berujung ke mode aman.

* Firmware yang sudah berjalan 2 menit tanpa crash (`VERSI_BAIK_MS`) disalin ke file system, sekali per versi, hanya saat aplikasi remote tertutup. Pada crash ke-3 berturut-turut, pesawat memasang salinan itu (dicek MD5) lalu restart dengannya. Kalau tidak ada salinan, atau salinannya justru versi yang crash, pesawat masuk mode aman.

**Pengaturan jangkauan (firmware)**

* Hanya 802.11b, modem sleep mati, kalibrasi RF penuh setiap dinyalakan, daya pancar di level tertinggi tabel PHY (19,5 dBm).

* Kiriman pesawat sendiri (telemetri, OTA) dimulai di 1 Mbps, rate yang paling peka. Rate paket kendali dipilih oleh HP.

* `EKSP_AP_RATE_1_2M` (mati secara default, eksperimen) membuat access point hanya mengiklankan 1 dan 2 Mbps, sehingga HP juga mengirim di rate itu. Uji dulu di darat.

**Link**

* Aplikasi mengirim paket kendali 5 byte pada 250 Hz: `[BIND_ID, seq lo, seq hi, PWM kanan, PWM kiri]`. Paket yang byte pertamanya bukan `BIND_ID` pesawat ini dibuang. Tidak ada checksum tambahan: WiFi sudah mengecek setiap frame dengan CRC-32 di hardware.

* Aplikasi memilih mode kirim sendiri dan menampilkannya di bilah status (MODE). BC (broadcast) saat HP menjadi hotspot: tanpa pengulangan WiFi, tanpa antrean selama pesawat satu-satunya perangkat di hotspot. UC (unicast, dikonfirmasi dan diulang) saat HP menjadi klien WiFi, baik ke access point pesawat maupun ke WiFi rumah: di sana broadcast tidak memberi keuntungan dan bisa tertunda atau terkirim dua kali.

* Pesawat hanya memakai paket terbaru, membuang paket basi dan duplikat berdasarkan nomor urut, dan menghitung link quality (LQ) dari nomor yang terlewat. Motor dimatikan setelah 900 ms tanpa paket.

* Sekali per detik pesawat mengirim `[BIND_ID, RSSI, VBAT*10, LQ %]`, lewat broadcast sampai ada HP yang mengendalikannya dan lewat unicast setelahnya, sehingga aplikasi menemukan pesawat dengan sendirinya. Di mode access point pesawat tidak bisa mengukur RSSI, jadi aplikasi menampilkan RSSI yang diukur HP ("HP").

**Tampilan remote**

Ada dua mode kemudi, diganti dengan tombol GANTI MODE saat terkunci:

* MIRING (layar potret): belok dengan memiringkan HP (sensor accelerometer), gas di slider tengah. Tanpa trim.

* MANUAL (layar landscape): gas di slider kiri (ibu jari kiri, geser ke atas), belok di slider horizontal kanan-bawah (ibu jari kanan, geser ke kiri/kanan), trim dan HOLD di atas slider belok.

Mode MIRING:

| Siap | Terbang, belok kiri | Sinyal lemah | Link putus |
|---|---|---|---|
| ![Siap](ProcessingAndroidApp/tampilan/1_siap.png) | ![Terbang](ProcessingAndroidApp/tampilan/2_terbang.png) | ![Sinyal lemah](ProcessingAndroidApp/tampilan/3_sinyal_lemah.png) | ![Link putus](ProcessingAndroidApp/tampilan/4_link_putus.png) |

Mode MANUAL:

| Terbang, belok kanan | HOLD, belok kiri penuh, sinyal lemah |
|---|---|
| ![Manual terbang](ProcessingAndroidApp/tampilan/5_manual_terbang.png) | ![Manual HOLD](ProcessingAndroidApp/tampilan/6_manual_hold_sinyal_lemah.png) |

Gambar di atas dirender dari kode `draw()` yang sama; huruf di HP bisa sedikit berbeda.

* Atas: status koneksi ke pesawat (alamat IP, "Mencari pesawat…" atau "Link putus"), lalu sinyal, LQ · KIRIM, baterai (warna hijau/kuning/merah sesuai level) dan mode kirim BC/UC.

* LQ · KIRIM: angka besar = LQ, persen paket kendali yang diterima pesawat (dihitung FC dari nomor urut, hanya paket yang hilang di udara). Angka kecil = jumlah paket kendali yang benar-benar dikirim HP per detik, normalnya sekitar 250. Kuning kalau di bawah 200 (HP tidak sanggup mengirim secepat itu), 0 kalau HP belum atau tidak mengirim. LQ tidak membatasi gas atau motor; motor hanya dimatikan oleh failsafe (900 ms tanpa paket) dan pemutus baterai.

* Di bawahnya muncul satu pesan kalau ada yang perlu diperhatikan: link putus, baterai lemah, sinyal lemah, izin kurang, atau petunjuk saat siap terbang.

* BELOK: pilihan BG (belok halus) atau EX (belok tajam), yang aktif disorot. Ketuk untuk mengganti. Berlaku di kedua mode.

* GANTI MODE: ikonnya menunjukkan posisi HP setelah diganti (MANUAL = landscape, MIRING = potret).

* Mode MIRING: output motor kiri dan kanan dalam persen di kiri-kanan slider gas (dihitung dengan rumus yang sama dengan paket yang dikirim), dan indikator kemiringan HP di bawahnya.

* Mode MANUAL: trim kiri dan kanan ([−] nilai [+]) dan HOLD di atas slider belok, supaya bisa diketuk ibu jari kanan selagi ibu jari kiri memegang gas. AKTIFKAN di kiri-bawah, jauh dari titik ibu jari kanan.

* Setiap tombol bergetar singkat saat diketuk.

**Kendali dan keselamatan**

* Multi-touch: setiap jari dibaca sendiri, jadi gas, belok dan tombol bisa dipakai bersamaan, misalnya menahan gas sambil mengetuk HOLD, trim atau BG/EX dengan jari lain.

* Gas: sentuh dan geser slider gas, atas = penuh. Gas langsung mengikuti jari saat slider disentuh, dan hanya jari yang mulai menyentuh di slider saat AKTIF yang mengubah gas; jari lain yang ikut menyentuh slider diabaikan. Jari gas diangkat membuat gas menjadi 0, walaupun jari lain masih menyentuh layar, sehingga motor mati saat pesawat jatuh. Saat gas 0, kedua motor mati, apa pun kemiringan, slider belok dan trim-nya.

* Belok (mode MANUAL): kenop mengikuti jari, ujung slider sama dengan HP miring 90 derajat di mode MIRING, dan BG/EX tetap berlaku. Jari diangkat membuat pesawat lurus lagi. Ada zona mati kecil di tengah. Di mode MANUAL kemiringan HP tidak dipakai.

* HOLD (hanya mode MANUAL, oranye saat aktif, hanya bisa saat AKTIF): gas ditahan walaupun jari diangkat, sehingga ibu jari kiri bebas, misalnya untuk mengatur trim. Ketuk lagi untuk mematikannya, yang juga membuat gas menjadi 0; kalau jari masih di slider gas, angkat dulu untuk memberi gas lagi. Mode MIRING tidak punya HOLD.

* Trim (hanya mode MANUAL): TRIM KIRI menambah motor kanan (pesawat cenderung ke kiri), TRIM KANAN menambah motor kiri. Batas ±30 per trim. Nilainya disimpan di memori aplikasi setiap kali diketuk, jadi tetap ada saat aplikasi ditutup dan dibuka lagi. Di mode MIRING trim tidak dipakai.

* AKTIFKAN / AKTIF mengunci dan membuka kendali. Mengunci juga mematikan HOLD dan membuat gas menjadi 0. Jari yang sudah ada di slider gas saat AKTIFKAN diketuk tidak memberi gas; angkat dan sentuh lagi.

* Ganti mode hanya bisa saat terkunci. Saat AKTIF, tombolnya redup dan muncul pesan "Kunci dulu untuk ganti mode". Layar landscape dikunci ke satu arah (tidak ikut sensor), jadi tidak berputar sendiri saat terbang. Kalau bentuk layar tetap berubah saat AKTIF (misalnya layar terpisah), kendali langsung dikunci.

* HP bergetar saat baterai lemah (di bawah 3,0 V, paling lama 2 detik sebelum pesawat memutus motor), dan saat AKTIF ketika link putus atau LQ di bawah 50%.

* Pesawat memutus motor saat tegangan baterai bertahan di bawah 3,0 V (batas mutlak LiPo 1S saat dibebani) selama 2 detik, sehingga penurunan sesaat saat gas penuh tidak memutusnya. Motor bisa dipakai lagi setelah tegangan naik dan gas kembali ke 0.

* Saat aplikasi di-pause (telepon masuk, layar dikunci, pindah aplikasi), kendali dikunci dan gas 0 dikirim selama 1 detik, lalu pengiriman berhenti dan lock dilepas.

**HP**

* Hotspot: pita 2,4 GHz, opsi "matikan hotspot otomatis" dimatikan, dan tidak ada perangkat lain yang tersambung.

* Access point pesawat: matikan data seluler, atau pilih "tetap terhubung" saat Android memberi tahu jaringan tidak punya internet. Aplikasi juga mengikat socket-nya ke jaringan itu.

* Matikan penghemat baterai, dan jangan tutupi tepi HP dengan tangan karena antena WiFi biasanya ada di sana. Aplikasi menjaga layar tetap menyala.
