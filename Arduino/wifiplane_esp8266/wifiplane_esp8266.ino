//***************************************************
// WiFi Controlled Tiny Airplane with OTA (STA priority + AP fallback)
// PROFIL JANGKAUAN MAKSIMUM (latensi boleh lebih tinggi)
// Binding ala ELRS: CRC8 dengan nilai awal BIND_ID (integritas data sudah dijamin CRC-32 hardware WiFi)
// Eksternal Voltage Divider: 33k & 8.2k
// Auto Cut-Off Motor saat Baterai < 3.0V selama 2 detik (latch; re-arm saat perintah HP = 0)
// Discovery: telemetri di-broadcast selama belum ada HP yang mengontrol,
//            setelah itu unicast ke IP HP pengirim paket valid
// Paket kendali (6 byte): [0xEA, SEQ lo, SEQ hi, PWM KANAN, PWM KIRI, CRC8]
// Telemetri (5 byte): [P_ID, RSSI, VBAT*10, LQ %, CRC8]
//***************************************************

#include <ESP8266WiFi.h>
#include <WiFiUdp.h>
#include <ArduinoOTA.h>

#define P_ID 1
#define ST_LED  2
// Sesuai skema asli Ravi Butani: GPIO4 -> T2 -> MOTOR_R, GPIO5 -> T1 -> MOTOR_L.
// HP miring kiri -> motor kanan lebih kencang -> pesawat belok kiri.
#define MOTOR_KANAN 4
#define MOTOR_KIRI  5
#define DC_RSSI 1000   // interval telemetri (ms), sejalan dengan jendela LQ 1 detik
#define DC_RX   900    // failsafe: motor mati jika tidak ada paket valid > 900 ms

// Batas paket yang dikuras per loop() supaya durasi loop tetap terbatas
#define MAX_PAKET_PER_LOOP 16

// --- DEBUG: 1 = cetak mode, IP, kanal, PHY, hasil setting rate ke Serial (115200) ---
#define DEBUG_SERIAL 0

// --- BINDING ---
// Nilai awal CRC8. HARUS sama dengan BIND_ID di aplikasi Android.
// Ganti di KEDUA sisi supaya HP/pesawat lain yang memakai aplikasi yang sama
// tidak saling mengendalikan.
#define BIND_ID 0x5A

// --- OTA ---
// Password upload OTA (Arduino IDE akan memintanya saat upload lewat port jaringan).
// Tanpa password, siapa pun di jaringan yang sama bisa mengganti firmware.
#define OTA_PASSWORD "GANTI_PASSWORD_OTA"
// OTA (dan mDNS) hanya aktif di mode STA (WiFi rumah / hotspot HP), dan hanya jika
// remote Android tidak terbuka: tidak ada paket kendali valid selama OTA_TUNDA_MS.
// Begitu paket remote datang, OTA langsung dimatikan. Di mode AP OTA tidak pernah aktif.
#define OTA_TUNDA_MS 10000

// =========================================================
// PROFIL JANGKAUAN
// =========================================================
// Kalibrasi RF penuh tiap power-up (API Guide: opsi 3, ~200 ms).
// Default core: hanya kalibrasi VDD33 + daya TX, sisanya pakai data kalibrasi di flash.
#define RF_KALIBRASI_PENUH 1

// Rate AWAL kirim data dari ESP dikunci 1 Mbps (DSSS).
// Datasheet ESP8266EX: sensitivitas DSSS 1 Mbps -98 dBm vs CCK 11 Mbps -91 dBm.
// API Guide: yang dibatasi hanya rate awal; retransmisi tidak dibatasi.
// Hanya berlaku untuk kiriman FC (telemetri, OTA); rate paket kendali dipilih HP.
#define KUNCI_RATE_KIRIM_1M 1

// Mode AP: scan saat boot lalu pilih kanal 1/6/11 dengan interferensi terendah (+2-3 detik boot).
#define AUTO_KANAL_AP    1
#define KANAL_AP_DEFAULT 1   // dipakai jika AUTO_KANAL_AP 0 atau scan gagal

// EKSPERIMEN (default 0): mode AP mengiklankan hanya rate 1-2 Mbps supaya HP mengirim
// ke FC dengan modulasi paling tahan derau. API Guide Espressif v1.5.4 menyebut
// wifi_set_user_sup_rate() baru mendukung 802.11g; dukungan 802.11b di SDK core 3.1.2
// BELUM terverifikasi. Uji di darat; jika HP gagal konek ke AP, kembalikan ke 0.
#define EKSP_AP_RATE_1_2M 0

// --- KONFIGURASI BATERAI (LiPo 1S) ---
#define BATT_MIN_V     3.0    // Motor mati (latch) jika tegangan di bawah ini (batas mutlak LiPo 1S)...
#define BATT_LOW_MS    2000   // ...terus-menerus selama 2 detik (sag sesaat saat gas penuh diabaikan)
#define BATT_HYST      0.15   // Re-arm hanya jika tegangan > BATT_MIN_V + BATT_HYST
                              // DAN perintah terakhir dari HP = 0 (throttle dilepas / LOCK)
#define BATT_SAMPLE_MS 100    // 1x analogRead tiap 100 ms. Dokumentasi core: analogRead()
                              // yang terlalu sering mengganggu WiFi dan hasilnya di-cache >= 5 ms
// Catatan: datasheet ESP8266EX: tegangan operasi 2.5-3.6 V. Dengan LDO/buck dari 1S,
// rail ESP <= tegangan baterai, jadi di dekat ambang ini ESP bisa reset lebih dulu.

unsigned long premillis_rssi = 0;
unsigned long premillis_rx   = 0;
unsigned long premillis_batt = 0;
unsigned long premillis_lq   = 0;
unsigned long premillis_battLow = 0;

float batteryVoltage = 0.0;     // rata-rata bergerak, 0 = belum ada sampel
bool  batteryLow     = false;
bool  battDiBawahMin = false;   // tegangan sedang di bawah BATT_MIN_V (belum tentu 2 detik)
bool  cmdNol         = true;    // true = perintah terakhir dari HP adalah 0/0

// --- Link quality ala ELRS: % paket diterima dari nomor urut yang diharapkan, per detik ---
bool     linked       = false;  // ada paket valid dalam DC_RX terakhir (false = failsafe)
uint16_t lastSeq      = 0;
uint16_t lqDiterima   = 0;
uint16_t lqDiharapkan = 0;
uint8_t  lqPersen     = 0;

// --- Variabel baru untuk non-blocking ---
unsigned long lastBlink      = 0;
bool          ledState       = false;

// --- Status mode WiFi yang sedang aktif ---
bool    usingSTA = true;   // true = konek ke hotspot HP, false = jadi AP sendiri
uint8_t kanalAP  = KANAL_AP_DEFAULT;

// --- Hasil setting rate (untuk DEBUG) ---
bool hasilRateSta = false, hasilRateAp = false, hasilRateMask = false;
int  hasilSupRate = -1;

bool otaAktif = false;   // ArduinoOTA.begin() sudah dipanggil (end() crash jika belum)

// --- IP HP yang sedang mengontrol (tujuan telemetri unicast) ---
IPAddress ipHP;

// --- KONFIGURASI WIFI (isi sendiri, jangan di-commit ke repo publik) ---
const char* ssid_sta = "NAMA_WIFI_STA";        // WiFi modem rumah (untuk OTA) atau hotspot HP
const char* pass_sta = "PASSWORD_WIFI_STA";

const char* ssid_ap  = "wifiplane";
const char* pass_ap  = "PASSWORD_AP_FC";   // minimal 8 karakter

unsigned int localPort = 6000;
unsigned int remotPort = 2390;

uint8_t packetBuffer[10];
uint8_t replyBuffer[5] = {P_ID, 0x00, 0x00, 0x00, 0x00};   // byte ke-5 = CRC8 telemetri
WiFiUDP Udp;

#if RF_KALIBRASI_PENUH
// Hook core (user_rf_pre_init): dijalankan sebelum inisialisasi RF.
RF_PRE_INIT() {
  system_phy_set_powerup_option(3);   // 3 = kalibrasi RF penuh tiap power-up
}
#endif

// --- FUNGSI VALIDASI CRC8 (SAMA DENGAN SISI ANDROID) ---
// Nilai awal = BIND_ID (lihat bagian BINDING)
uint8_t calculateCRC8(const uint8_t *data, uint8_t len) {
  uint8_t crc = BIND_ID;
  for (uint8_t i = 0; i < len; i++) {
    crc ^= data[i];
    for (uint8_t j = 0; j < 8; j++) {
      if (crc & 0x80) {
        crc = (crc << 1) ^ 0x07;
      } else {
        crc <<= 1;
      }
    }
  }
  return crc;
}

// --- FUNGSI BACA TEGANGAN BATERAI (1 SAMPEL; dirata-rata antar panggilan) ---
float readBatteryVoltage() {
  return (analogRead(A0) / 1024.0) * 4.6894;
}

// --- SETTING RADIO ---
// Dipanggil SETELAH setiap WiFi.mode(). Sejak core 3.x WiFi tidak dinyalakan
// saat boot, jadi setting yang diberikan saat radio masih mati tidak dijamin
// berlaku. Cek hasilnya dengan DEBUG_SERIAL 1 (PHY harus 1 = 802.11b).
void terapkanSettingRadio() {
  WiFi.setSleep(false);
  // setOutputPower() = BATAS ATAS daya TX. Level daya tertinggi di PHY init data
  // core 3.1.2 adalah 19.5 dBm (byte 34 = 78), jadi daya efektif kemungkinan 19.5 dBm.
  WiFi.setOutputPower(20.5);
  WiFi.setPhyMode(WIFI_PHY_MODE_11B);
#if KUNCI_RATE_KIRIM_1M
  hasilRateSta  = wifi_set_user_rate_limit(RC_LIMIT_11B, 0x00, RATE_11B_B1M, RATE_11B_B1M);  // station
  hasilRateAp   = wifi_set_user_rate_limit(RC_LIMIT_11B, 0x01, RATE_11B_B1M, RATE_11B_B1M);  // soft-AP
  hasilRateMask = wifi_set_user_limit_rate_mask(LIMIT_RATE_MASK_ALL);
#endif
}

#if AUTO_KANAL_AP
// --- PILIH KANAL AP TERBAIK ---
// Scan dengan PHY 11n supaya jaringan OFDM-only ikut terdeteksi (radio 11b tidak
// bisa men-decode beacon OFDM). Skor = jumlah daya (mW) jaringan lain, dibobot
// tumpang-tindih kanal (jarak kanal >= 5 dianggap tidak tumpang-tindih).
uint8_t pilihKanalTerbaik() {
  const uint8_t kandidat[3] = {1, 6, 11};
  float skor[3] = {0, 0, 0};

  WiFi.setPhyMode(WIFI_PHY_MODE_11N);
  int n = WiFi.scanNetworks(false, true);   // sinkron, termasuk SSID tersembunyi
  if (n <= 0) {
    WiFi.scanDelete();
    return KANAL_AP_DEFAULT;
  }

  for (int i = 0; i < n; i++) {
    int   ch = WiFi.channel(i);
    float mw = powf(10.0f, WiFi.RSSI(i) / 10.0f);
    for (uint8_t k = 0; k < 3; k++) {
      int d = abs(ch - (int)kandidat[k]);
      if (d < 5) skor[k] += mw * (1.0f - d / 5.0f);
    }
  }
  WiFi.scanDelete();

  uint8_t best = 0;
  for (uint8_t k = 1; k < 3; k++) {
    if (skor[k] < skor[best]) best = k;
  }
#if DEBUG_SERIAL
  Serial.printf("\nScan: %d jaringan | skor ch1=%.3g ch6=%.3g ch11=%.3g mW -> ch%u\n",
                n, skor[0], skor[1], skor[2], kandidat[best]);
#endif
  return kandidat[best];
}
#endif

// --- FUNGSI NADA STARTUP SEPERTI ESC ---
void playESCStartupSound() {
  uint16_t tones[] = {1200, 1800, 2500};
  uint8_t duty = 3;

  for (uint8_t i = 0; i < 3; i++) {
    analogWriteFreq(tones[i]);
    analogWrite(MOTOR_KANAN, duty);
    analogWrite(MOTOR_KIRI, duty);
    delay(100);

    analogWrite(MOTOR_KANAN, 0);
    analogWrite(MOTOR_KIRI, 0);
    delay(30);
  }
  analogWriteFreq(1000); // Kembalikan frekuensi PWM standar (1000 Hz)
}

// --- FUNGSI BUNYI BIP MOTOR ---
void playKoneksiSound(uint8_t count) {
  for (uint8_t i = 0; i < count; i++) {
    analogWrite(MOTOR_KANAN, 5);
    analogWrite(MOTOR_KIRI, 5);
    delay(50);

    analogWrite(MOTOR_KANAN, 0);
    analogWrite(MOTOR_KIRI, 0);
    delay(100);
  }
}

// --- OTA HANYA DI MODE STA, SAAT REMOTE ANDROID TIDAK TERBUKA ---
// Remote dianggap terbuka selama paket kendali valid masih datang (aplikasi mengirim
// 250 Hz dan berhenti 1 detik setelah ditutup/di-pause). Saat boot dihitung dari 0,
// jadi tanpa remote OTA aktif ~OTA_TUNDA_MS setelah pesawat dinyalakan.
void aturOTA() {
  bool remoteTerbuka = (millis() - premillis_rx < OTA_TUNDA_MS);
  bool otaBoleh      = usingSTA && !remoteTerbuka;
  if (!otaBoleh && otaAktif) {
    ArduinoOTA.end();     // tutup listener OTA dan mDNS
    otaAktif = false;
  } else if (otaBoleh && !otaAktif) {
    ArduinoOTA.begin();
    otaAktif = true;
  }
}

void setup() {
#if DEBUG_SERIAL
  Serial.begin(115200);
#endif

  analogWriteRange(255);

  pinMode(MOTOR_KANAN, OUTPUT);
  pinMode(MOTOR_KIRI, OUTPUT);
  analogWrite(MOTOR_KANAN, 0);
  analogWrite(MOTOR_KIRI, 0);
  pinMode(ST_LED, OUTPUT);
  digitalWrite(ST_LED, HIGH);

  playESCStartupSound();

  // =========================================================
  // PRIORITAS 1: COBA KONEK SEBAGAI STA (WiFi modem rumah, atau hotspot HP)
  // =========================================================
  WiFi.mode(WIFI_STA);
  terapkanSettingRadio();          // setelah WiFi.mode(), sebelum WiFi.begin()
  WiFi.begin(ssid_sta, pass_sta);

  unsigned long startWait = millis();
  while (WiFi.status() != WL_CONNECTED && millis() - startWait < 8000) {
    digitalWrite(ST_LED, LOW);
    delay(60);
    digitalWrite(ST_LED, HIGH);
    delay(400);
  }

  if (WiFi.status() == WL_CONNECTED) {
    // --- STA berhasil: HP hotspot ditemukan, radio fokus penuh ke STA ---
    usingSTA = true;
    playKoneksiSound(3);   // 3 bip = mode STA aktif
  } else {
    // =========================================================
    // PRIORITAS 2: FALLBACK KE AP (FC jadi hotspot sendiri)
    // =========================================================
    WiFi.disconnect();
    delay(100);

#if AUTO_KANAL_AP
    kanalAP = pilihKanalTerbaik();   // masih di mode STA
#else
    kanalAP = KANAL_AP_DEFAULT;
#endif

    WiFi.mode(WIFI_AP);
    terapkanSettingRadio();        // ulangi setelah ganti mode (kembali ke 11b)
#if EKSP_AP_RATE_1_2M
    hasilSupRate = wifi_set_user_sup_rate(RATE_11B1M, RATE_11B2M);
#endif
    WiFi.softAP(ssid_ap, pass_ap, kanalAP);

    usingSTA = false;
    playKoneksiSound(2);   // 2 bip = mode AP fallback aktif
  }

  Udp.begin(localPort);

#if DEBUG_SERIAL
  Serial.printf("\nMode: %s | IP: %s | Kanal: %d | PHY: %d (1=11b, 2=11g, 3=11n)\n",
                usingSTA ? "STA" : "AP",
                (usingSTA ? WiFi.localIP() : WiFi.softAPIP()).toString().c_str(),
                (int)WiFi.channel(), (int)WiFi.getPhyMode());
  Serial.printf("Rate limit 1M: sta=%d ap=%d mask=%d (baca: 0x%02X) | sup_rate=%d (-1 = tidak dipakai)\n",
                hasilRateSta, hasilRateAp, hasilRateMask,
                wifi_get_user_limit_rate_mask(), hasilSupRate);
#endif

  // --- KONFIGURASI ARDUINO OTA (JANGAN DIUBAH) ---
  // ArduinoOTA.begin()/end() dipanggil oleh aturOTA() di loop(): OTA hanya aktif
  // selama remote Android tidak terbuka, supaya tidak mengganggu penerbangan.
  ArduinoOTA.setHostname("wifiplane-ota");
  ArduinoOTA.setPassword(OTA_PASSWORD);

  ArduinoOTA.onStart([]() {
    // Matikan motor demi keselamatan saat proses upload firmware via OTA
    analogWrite(MOTOR_KANAN, 0);
    analogWrite(MOTOR_KIRI, 0);
    digitalWrite(ST_LED, LOW);
  });

  ArduinoOTA.onEnd([]() {
    analogWrite(MOTOR_KANAN, 0);
    analogWrite(MOTOR_KIRI, 0);
    digitalWrite(ST_LED, HIGH);
  });

  premillis_lq = millis();
}

void loop() {
  // =========================================================
  // 0. OTA HANDLER  (JANGAN DIUBAH — selalu di paling atas)
  //    Hanya di mode STA, saat remote Android tidak terbuka (lihat aturOTA)
  // =========================================================
  aturOTA();
  if (otaAktif) ArduinoOTA.handle();
  // =========================================================
  // 1. TERIMA PAKET UDP DENGAN VALIDASI CRC8 ALA ELRS
  //    Antrean dikuras tiap loop; hanya paket valid TERBARU yang dipakai.
  //    Nomor urut 16-bit: paket basi/duplikat dibuang, celah nomor = paket hilang (LQ).
  //    16-bit supaya putus > 0.5 detik di 250 Hz tidak terbaca sebagai paket basi.
  // =========================================================
  bool    adaPaketBaru = false;
  uint8_t cmdKanan = 0;
  uint8_t cmdKiri  = 0;

  for (uint8_t n = 0; n < MAX_PAKET_PER_LOOP; n++) {
    int packetSize = Udp.parsePacket();   // juga melepas paket sebelumnya
    if (packetSize <= 0) break;           // antrean kosong
    if (packetSize != 6) continue;        // ukuran salah -> abaikan

    Udp.read(packetBuffer, 6);
    if (packetBuffer[0] != 0xEA) continue;
    if (packetBuffer[5] != calculateCRC8(packetBuffer, 5)) continue;

    uint16_t seq     = packetBuffer[1] | (packetBuffer[2] << 8);
    int16_t  selisih = (int16_t)(seq - lastSeq);
    if (linked && selisih <= 0) continue; // lebih lama dari yang sudah dipakai

    lqDiharapkan += linked ? selisih : 1; // setelah failsafe: mulai hitung dari paket ini
    lqDiterima++;
    lastSeq = seq;
    linked  = true;

    cmdKanan = packetBuffer[3];
    cmdKiri  = packetBuffer[4];
    ipHP = Udp.remoteIP();                // dibaca selagi paket ini masih aktif
    adaPaketBaru = true;
  }

  if (adaPaketBaru) {
    cmdNol = (cmdKanan == 0 && cmdKiri == 0);
    analogWrite(MOTOR_KANAN, batteryLow ? 0 : cmdKanan);
    analogWrite(MOTOR_KIRI,  batteryLow ? 0 : cmdKiri);
    premillis_rx = millis();
  }

  // Jendela link quality 1 detik
  if (millis() - premillis_lq >= 1000) {
    premillis_lq = millis();
    lqPersen     = lqDiharapkan ? (uint8_t)min(100UL, 100UL * lqDiterima / lqDiharapkan) : 0;
    lqDiterima   = 0;
    lqDiharapkan = 0;
  }

  // =========================================================
  // 2. SAFETY: CEK BATERAI (1 sampel tiap 100 ms, rata-rata bergerak)
  //    Cutoff di-latch setelah tegangan < BATT_MIN_V terus-menerus BATT_LOW_MS.
  //    Motor baru boleh hidup lagi jika tegangan sudah pulih
  //    (> BATT_MIN_V + BATT_HYST) DAN perintah terakhir dari HP = 0.
  //    Tanpa latch, sag saat motor jalan > BATT_HYST membuat motor on/off berulang.
  // =========================================================
  if (millis() - premillis_batt >= BATT_SAMPLE_MS) {
    premillis_batt = millis();
    float v = readBatteryVoltage();
    batteryVoltage = (batteryVoltage <= 0) ? v : batteryVoltage + 0.25f * (v - batteryVoltage);

    if (batteryVoltage < BATT_MIN_V) {
      if (!battDiBawahMin) {
        battDiBawahMin    = true;
        premillis_battLow = millis();
      }
      if (millis() - premillis_battLow >= BATT_LOW_MS) batteryLow = true;
    } else {
      battDiBawahMin = false;
      if (batteryLow && cmdNol && batteryVoltage > (BATT_MIN_V + BATT_HYST)) {
        batteryLow = false;
      }
    }

    if (batteryLow) {
      analogWrite(MOTOR_KANAN, 0);   // langsung, tanpa menunggu paket berikutnya
      analogWrite(MOTOR_KIRI, 0);
    }
  }

  // =========================================================
  // 3. KIRIM TELEMETRI KE ANDROID: [P_ID, RSSI, VBAT*10, LQ %, CRC8]
  //    - Ada HP aktif (paket valid < DC_RX ms) : unicast ke IP HP tersebut
  //    - Belum/tidak ada                       : broadcast (discovery), supaya
  //      aplikasi bisa menemukan IP FC di subnet hotspot apa pun
  // =========================================================
  if (millis() - premillis_rssi > DC_RSSI) {
    premillis_rssi = millis();

    // RSSI hanya valid di mode STA (di mode AP aplikasi memakai RSSI yang diukur HP)
    long rssi = 0;
    if (usingSTA) {
      rssi = abs(WiFi.RSSI());
    }

    replyBuffer[1] = (uint8_t)rssi;
    replyBuffer[2] = (uint8_t)(batteryVoltage * 10);
    replyBuffer[3] = lqPersen;
    replyBuffer[4] = calculateCRC8(replyBuffer, 4);

    IPAddress replyIp;
    if (millis() - premillis_rx <= DC_RX) {
      replyIp = ipHP;
    } else if (usingSTA) {
      replyIp = IPAddress(255, 255, 255, 255);
    } else {
      IPAddress apIp = WiFi.softAPIP();                     // default 192.168.4.1/24
      replyIp = IPAddress(apIp[0], apIp[1], apIp[2], 255);
    }

    Udp.beginPacket(replyIp, remotPort);
    Udp.write(replyBuffer, 5);
    Udp.endPacket();
  }

  // =========================================================
  // 4. FAIL-SAFE MOTOR
  // =========================================================
  if (linked && millis() - premillis_rx > DC_RX) {
    linked = false;   // paket berikutnya diterima berapa pun nomor urutnya
    analogWrite(MOTOR_KANAN, 0);
    analogWrite(MOTOR_KIRI, 0);
  }

  // =========================================================
  // 5. INDIKATOR LED (non-blocking, tanpa delay)
  //    - Battery low          : kedip cepat 100 ms
  //    - Tidak ada koneksi    : kedip lambat 800 ms
  //      * Mode STA : WiFi.status() != WL_CONNECTED
  //      * Mode AP  : softAPgetStationNum() == 0
  // =========================================================
  unsigned long now = millis();
  uint16_t interval;

  bool linkLost;
  if (usingSTA) {
    linkLost = (WiFi.status() != WL_CONNECTED);
  } else {
    linkLost = (WiFi.softAPgetStationNum() == 0);
  }

  if (batteryLow) {
    interval = 100;
  } else if (linkLost) {
    interval = 800;
  } else {
    interval = 0;
    if (ledState) {
      ledState = false;
      digitalWrite(ST_LED, HIGH);
    }
  }

  if (interval && (now - lastBlink >= interval)) {
    lastBlink = now;
    ledState  = !ledState;
    digitalWrite(ST_LED, ledState ? HIGH : LOW);
  }
}
