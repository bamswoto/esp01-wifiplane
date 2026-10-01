//***************************************************
// WiFi Controlled Tiny Airplane - Android Controller
// PROFIL JANGKAUAN MAKSIMUM (latensi boleh lebih tinggi)
// Background sender thread (~250 Hz) + buffer reuse
// Binding ala ELRS: byte pertama setiap paket = BIND_ID (integritas data sudah dijamin CRC-32 hardware WiFi)
// + nomor urut 16-bit
// Paket kendali (5 byte): [BIND_ID, SEQ lo, SEQ hi, PWM KANAN, PWM KIRI]
// Discovery: IP FC diambil dari telemetri valid
// Mode kirim otomatis (ditampilkan di area kanan-tengah):
//   BC = broadcast ke subnet FC, saat HP jadi hotspot (FC mode STA): frame grup, tanpa retry MAC.
//        Tidak ditahan sampai beacon DTIM selama FC tidak sleep dan tidak ada perangkat lain di hotspot
//   UC = unicast ke IP FC, saat HP klien Wi-Fi (FC mode AP, atau router rumah): ACK + retry MAC
// Dua mode kemudi, diganti dengan tombol MANUAL / MIRING saat terkunci:
//   MIRING (potret) = belok dengan memiringkan HP, gas di slider tengah
//   MANUAL (landscape) = gas di slider kiri, belok di slider horizontal kanan-bawah
// Gas: jari lepas = gas 0 (safety saat pesawat jatuh). Tombol HOLD menahan gas
//   supaya trim bisa diatur; tekan HOLD lagi = HOLD mati + gas 0.
//   Gas 0 = kedua motor mati, kemiringan HP, slider belok dan trim tidak memutar motor.
// Multi-touch: setiap jari dilacak sendiri, jadi gas, belok dan tombol bisa dipakai bersamaan.
// Jaringan Wi-Fi tanpa internet (AP FC) di-request agar tidak dilepas sistem,
// dan socket kirim di-bind ke jaringan itu (tetap jalan walau data seluler ON)
// Izin (Android > Sketch Permissions): INTERNET, VIBRATE, WAKE_LOCK, ACCESS_WIFI_STATE,
//   ACCESS_NETWORK_STATE, CHANGE_NETWORK_STATE
//   Izin yang kurang ditampilkan di layar.
// AndroidManifest.xml: activity memakai android:configChanges (orientation|screenSize|...)
//   supaya ganti mode MANUAL/MIRING tidak me-restart aplikasi.
//***************************************************

import hypermedia.net.*;
import ketai.sensors.*;
import ketai.ui.*;
import android.content.Context;
import android.net.ConnectivityManager;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.net.NetworkRequest;
import android.net.wifi.WifiManager;
import android.view.WindowManager;
import java.net.InetAddress;
import java.net.Inet4Address;
import java.net.InterfaceAddress;
import java.net.NetworkInterface;
import java.net.DatagramSocket;
import java.net.DatagramPacket;
import java.util.Collections;

// =========================================================
// BINDING: byte pertama setiap paket, HARUS sama dengan BIND_ID di firmware FC
// =========================================================
final int BIND_ID = 0x5A;

// Gain diferensial accelerometer per mode (dipakai saat start DAN saat toggle)
final float DIFF_BG = 4.0;   // mode BG
final float DIFF_EX = 7.0;   // mode EX

// Belok penuh dalam satuan accelerometer: HP miring 90 derajat setelah deadzone (9.8 - 1.5).
// Slider belok di ujung = HP miring 90 derajat.
final float MIRING_PENUH = 8.3;

// Peringatan getar
final int VBAT_WARN     = 30;    // baterai < 3.0 V, sama dengan batas pemutus motor di FC
final int LQ_WARN       = 50;    // LQ < 50% saat AKTIF
final int TLM_HILANG_MS = 2000;  // telemetri hilang > 2 detik = link putus

// Setelah app ter-pause, kirim 0/0 selama ini lalu berhenti (FC failsafe sendiri)
final int KIRIM_SETELAH_PAUSE_MS = 1000;

// =========================================================
// GLOBAL STATE
// volatile: ditulis UI/callback thread, dibaca sender thread
// =========================================================
volatile int gas          = 0;
volatile int lock         = 0;
volatile boolean hold     = false;   // true = gas ditahan walau jari lepas (untuk atur trim)
volatile int trimKiri     = 0;   // tombol kolom kiri: tambah motor kanan -> belok kiri
volatile int trimKanan    = 0;   // tombol kolom kanan: tambah motor kiri -> belok kanan
volatile float accelerometerX = 0;
volatile float diff_power = DIFF_BG;
volatile boolean kemudiSlider = false;   // true = mode MANUAL (layar landscape, belok dari slider)
volatile float belokSlider    = 0;       // slider belok: -1 (kiri) .. 1 (kanan), 0 saat jari lepas

// Mode kirim: true = BC (broadcast subnet FC), false = UC (unicast). Dipilih otomatis, lihat pakaiBroadcast()
volatile boolean kirimBroadcast = true;

// State telemetri: ditulis receiver callback, dibaca UI thread
volatile int rssi          = 0;
volatile int vcc           = 0;
volatile int lqFc          = 0;   // LQ % yang dihitung FC dari nomor urut paket
volatile long lastTelemetryMs = -100000;

// Wi-Fi klien HP, dibaca sekali per detik oleh sender thread (bacaInfoWifiKlien)
volatile InetAddress ipKlienHp = null;   // null = HP bukan klien Wi-Fi (mis. HP jadi hotspot)
volatile int rssiHp = 0;                 // RSSI yang diukur HP, dipakai saat FC mode AP (FC kirim 0)

// Paket terkirim/detik dari HP (ditulis sender thread)
volatile int txPerDetik = 0;

// Discovery: IP FC dari telemetri valid terakhir (null = belum ditemukan)
volatile InetAddress fcAddr = null;

// Wi-Fi tanpa internet (AP FC) untuk bind socket kirim; null = tidak ada
volatile Network wifiFC = null;
volatile int netGen     = 0;   // naik tiap pilihan jaringan berubah -> socket kirim dibuat ulang
ConnectivityManager connMgr;
ConnectivityManager.NetworkCallback netCallback;

// Flag kontrol sender thread
volatile boolean senderRunning = false;
volatile boolean appAktif      = true;   // false setelah onPause
volatile long    pauseMs       = 0;
Thread senderThread;

// UI-only state
int exprt_flag = 0;
long lastVib   = 0;

// Tampilan: tema gelap
final int W_LATAR  = 0xFF0E1625;
final int W_KARTU  = 0xFF1A2537;
final int W_TEKAN  = 0xFF2B3C55;
final int W_TEKS   = 0xFFE7EDF5;
final int W_REDUP  = 0xFF8496AE;
final int W_BIRU   = 0xFF38BDF8;
final int W_HIJAU  = 0xFF22C55E;
final int W_KUNING = 0xFFF5B30B;
final int W_MERAH  = 0xFFEF4444;
final int W_ORANYE = 0xFFFB923C;
final int W_UNGU   = 0xFFA78BFA;

// Area tombol [x, y, lebar, tinggi], dihitung ulang tiap frame oleh aturTata()
// dan dipakai juga untuk mendeteksi sentuhan
float[] rTrimKiriTambah  = new float[4];
float[] rTrimKiriKurang  = new float[4];
float[] rTrimKananTambah = new float[4];
float[] rTrimKananKurang = new float[4];
float[] rMode  = new float[4];
float[] rHold  = new float[4];
float[] rGas   = new float[4];
float[] rAktif = new float[4];
float[] rLayar = new float[4];        // tombol ganti mode MANUAL / MIRING
float[] rBelok = new float[4];        // slider belok (mode MANUAL)
float[] rIndikator  = new float[4];   // indikator kemiringan HP (mode MIRING)
float[] rMotorKiri  = new float[4];
float[] rMotorKanan = new float[4];
float[] rChip   = new float[4];       // baris chip sinyal/LQ/baterai/mode kirim
float[] rBanner = new float[4];       // baris pesan
float xKepala, yJudul, ySub, tPil;    // judul dan pil status koneksi
float u;                     // satuan ukuran: 1% sisi layar yang pendek
float[] rDitekan = null;     // tombol yang sedang ditekan (efek tekan)
volatile String peringatan = "";   // lock/izin yang gagal, ditampilkan di layar
String pesanSingkat = "";    // pesan sementara, mis. tombol ditolak
int pesanSampai = 0;

// Sentuhan: id jari dari event sentuh terakhir, dan jari yang memegang slider/tombol (-1 = tidak ada)
int[] idJari = new int[0];
int idGas    = -1;
int idBelok  = -1;
int idTombol = -1;

// --- Konfigurasi jaringan ---
int remotPort = 6000;               // port ESP8266
int localPort = 2390;               // port HP (untuk terima telemetri)

// --- Receiver (hypermedia UDP, port 2390) ---
UDP udp;

// --- Sensor & UI ---
KetaiSensor sensor;
KetaiVibrate vibe;

// --- Locks ---
WifiManager wifiMgr;
WifiManager.WifiLock wifiLock;

// =========================================================
// SETUP
// =========================================================
void setup() {
  size(displayWidth, displayHeight);
  orientation(PORTRAIT);   // mulai di mode MIRING. Rotasi tidak membuat ulang activity
                           // (configChanges di AndroidManifest.xml), jadi state tetap.

  keepScreenOn();
  setupPowerAndWifiLocks();
  setupWifiBinding();

  // --- Receiver via hypermedia UDP (telemetri + discovery FC) ---
  udp = new UDP(this, localPort);
  udp.listen(true);

  // --- Sender thread (raw DatagramSocket, ~250 Hz) ---
  senderRunning = true;
  senderThread = new Thread(new Runnable() {
    public void run() {
      senderLoop();
    }
  }
  );
  senderThread.start();
  println("Sender thread berjalan (~250 Hz)");

  sensor = new KetaiSensor(this);
  vibe   = new KetaiVibrate(this);
  sensor.start();
}

// =========================================================
// SENDER LOOP (berjalan di background thread)
// Tujuan kirim:
//   - FC sudah ditemukan : BC -> broadcast subnet FC, UC -> IP FC
//   - Belum ditemukan    : broadcast subnet Wi-Fi klien HP (FC mode AP);
//                          kalau HP sedang jadi hotspot (FC mode STA), tidak kirim
//                          dan menunggu telemetri broadcast dari FC (maks. ~1 detik)
// =========================================================
void senderLoop() {
  DatagramSocket sock = null;
  int sockGen = -1;

  // Buffer & packet di-reuse (nol alokasi per iterasi)
  final byte[] buf = new byte[5];
  DatagramPacket pkt = new DatagramPacket(buf, buf.length);
  pkt.setPort(remotPort);

  InetAddress fallbackAddr = null; // broadcast subnet Wi-Fi klien HP, sebelum FC ditemukan
  InetAddress fcUntukMode  = null; // IP FC yang mode kirimnya sudah dipilih
  InetAddress bcFc         = null; // alamat broadcast subnet FC
  long nextInfoMs = 0;             // info Wi-Fi & mode kirim dibaca ulang tiap detik

  int  seq         = 0;           // nomor urut 16-bit, naik tiap paket terkirim
  int  txHitung    = 0;
  long jendelaTxNs = System.nanoTime();

  final long periodNs = 4000000L; // 4 ms = 250 Hz
  long next = System.nanoTime();

  while (senderRunning) {
    try {
      // --- (Re)buat socket bila pilihan jaringan berubah ---
      int gen = netGen;
      if (sock == null || gen != sockGen) {
        if (sock != null) {
          sock.close();
          sock = null;
        }
        sock = buatSocketKirim();
        sockGen = gen;
      }

      // --- Info Wi-Fi klien HP, sekali per detik (jaringan HP bisa berubah) ---
      long nowMs = System.currentTimeMillis();
      boolean infoBaru = nowMs >= nextInfoMs;
      if (infoBaru) {
        bacaInfoWifiKlien();
        nextInfoMs = nowMs + 1000;
      }

      // --- Tentukan tujuan ---
      InetAddress fa = fcAddr;
      InetAddress target;
      if (fa != null) {
        if (infoBaru || !fa.equals(fcUntukMode)) {
          kirimBroadcast = pakaiBroadcast(fa);
          bcFc = kirimBroadcast ? broadcastUntuk(fa) : null;
          fcUntukMode = fa;
        }
        target = kirimBroadcast ? bcFc : fa;
      } else {
        // FC mode AP: broadcast ke subnet Wi-Fi klien HP. HP jadi hotspot: tidak kirim,
        // tunggu telemetri broadcast dari FC
        InetAddress ipHp = ipKlienHp;
        if (infoBaru) fallbackAddr = (ipHp != null) ? broadcastUntuk(ipHp) : null;
        target = fallbackAddr;
      }

      // Setelah app ter-pause: kirim 0/0 sebentar (motor langsung mati), lalu berhenti
      boolean kirim = appAktif || nowMs - pauseMs < KIRIM_SETELAH_PAUSE_MS;

      if (target != null && kirim) {
        // --- Snapshot state (volatile read) lalu susun paket 5 byte ---
        isiPaket(buf, seq, gas, trimKiri, trimKanan, nilaiBelok(), diff_power, lock);

        // --- Kirim (buffer yang sama, packet yang sama) ---
        pkt.setAddress(target);
        sock.send(pkt);
        seq = (seq + 1) & 0xFFFF;
        txHitung++;
      }

      // --- Hitung paket terkirim per detik ---
      long nowNs = System.nanoTime();
      if (nowNs - jendelaTxNs >= 1000000000L) {
        txPerDetik  = txHitung;
        txHitung    = 0;
        jendelaTxNs = nowNs;
      }

      // --- Jadwalkan iterasi berikutnya ---
      next += periodNs;
      long sleepNs = next - System.nanoTime();
      if (sleepNs > 0) {
        Thread.sleep(sleepNs / 1000000L, (int)(sleepNs % 1000000L));
      } else {
        next = System.nanoTime(); // tertinggal, reset jadwal
      }
    }
    catch (InterruptedException ie) {
      break;
    }
    catch (Exception e) {
      // Kirim / buat socket gagal (mis. Wi-Fi putus): jeda dulu, jangan busy-spin
      try {
        Thread.sleep(20);
      }
      catch (InterruptedException ie2) {
        break;
      }
      next = System.nanoTime();
    }
  }

  if (sock != null && !sock.isClosed()) sock.close();
}

// =========================================================
// PAKET KENDALI (5 byte): [BIND_ID, SEQ lo, SEQ hi, PWM KANAN, PWM KIRI]
// LOCK atau gas 0 = kedua motor 0 (kemiringan HP dan trim tidak memutar motor)
// =========================================================
void isiPaket(byte[] buf, int seq, int g, int tKiri, int tKanan, float ax, float dp, int lk) {
  buf[0] = (byte) BIND_ID;
  buf[1] = (byte) (seq & 0xFF);
  buf[2] = (byte) ((seq >> 8) & 0xFF);
  if (lk == 1 && g > 0) {
    // HP miring kiri (ax > 0) -> motor kanan lebih kencang -> pesawat belok kiri
    buf[3] = (byte) pwmMotor(g, tKiri, ax * dp);
    buf[4] = (byte) pwmMotor(g, tKanan, -ax * dp);
  } else {
    buf[3] = (byte) 0x00;
    buf[4] = (byte) 0x00;
  }
}

// PWM satu motor (0-254), mixing seperti kode asli. Dipakai paket dan indikator motor di layar.
int pwmMotor(int g, int trim, float belok) {
  return constrain((int)((float)g + (float)trim + belok) * 2, 0, 255);
}

// Belok dalam satuan accelerometer (> 0 = belok kiri): dari kemiringan HP di mode MIRING,
// dari slider di mode MANUAL (slider ke kanan = belok kanan)
float nilaiBelok() {
  return kemudiSlider ? -belokSlider * MIRING_PENUH : accelerometerX;
}

// =========================================================
// SOCKET KIRIM
// Kalau ada Wi-Fi tanpa internet (AP FC), socket di-bind ke jaringan itu.
// Tanpa bind, Android bisa merutekan paket lewat data seluler.
// =========================================================
DatagramSocket buatSocketKirim() throws Exception {
  DatagramSocket s = new DatagramSocket();
  try {
    s.setBroadcast(true);        // eksplisit, untuk mode BC dan fallback broadcast
    s.setSendBufferSize(2048);   // antrean kirim kecil: paket basi tidak menumpuk saat link lemah
    Network n = wifiFC;
    if (n != null && android.os.Build.VERSION.SDK_INT >= 23) {
      n.bindSocket(s);
    }
  }
  catch (Exception e) {
    s.close();
    throw e;
  }
  return s;
}

// =========================================================
// MODE KIRIM OTOMATIS
// HP jadi hotspot (FC mode STA ke hotspot HP) -> BC: frame grup dari AP, tanpa ACK/retry.
// HP klien Wi-Fi (FC mode AP, atau HP & FC sama-sama di router rumah) -> UC: kiriman klien
//   tetap di-ACK dan diulang, broadcast tidak memberi keuntungan, bisa diteruskan ulang oleh
//   AP ke semua klien dan (di router) ditahan sampai beacon DTIM.
// Caranya: FC dicapai lewat interface Wi-Fi klien HP -> UC, selain itu FC ada di hotspot HP -> BC.
// =========================================================
boolean pakaiBroadcast(InetAddress fc) {
  InetAddress ipHp = ipKlienHp;
  if (ipHp == null) return true;                       // HP bukan klien Wi-Fi
  InterfaceAddress ia = interfaceUntuk(fc);
  if (ia != null) return !ia.getAddress().equals(ipHp);
  return !samaSubnet(ipHp.getAddress(), fc.getAddress(), 24);   // interface tidak terbaca: asumsi /24
}

// =========================================================
// ALAMAT BROADCAST SUBNET (FC, atau Wi-Fi klien HP sebelum FC ditemukan)
// Dari interface lokal yang subnetnya memuat alamat itu.
// Jika gagal, asumsi /24 (subnet hotspot Android dan softAP ESP sama-sama /24).
// =========================================================
InetAddress broadcastUntuk(InetAddress addr) {
  InterfaceAddress ia = interfaceUntuk(addr);
  if (ia != null && ia.getBroadcast() != null) return ia.getBroadcast();
  byte[] f = addr.getAddress();
  if (f.length != 4) return addr;
  try {
    return InetAddress.getByAddress(new byte[] {f[0], f[1], f[2], (byte) 255});
  }
  catch (Exception e) {
    return addr;
  }
}

// Interface IPv4 lokal (aktif, bukan loopback) yang subnetnya memuat addr, null kalau tidak ada
InterfaceAddress interfaceUntuk(InetAddress addr) {
  byte[] f = addr.getAddress();
  if (f.length != 4) return null;
  try {
    for (NetworkInterface ni : Collections.list(NetworkInterface.getNetworkInterfaces())) {
      if (!ni.isUp() || ni.isLoopback()) continue;
      for (InterfaceAddress ia : ni.getInterfaceAddresses()) {
        InetAddress a = ia.getAddress();
        if (a instanceof Inet4Address && samaSubnet(a.getAddress(), f, ia.getNetworkPrefixLength())) return ia;
      }
    }
  }
  catch (Exception e) {
  }
  return null;
}

boolean samaSubnet(byte[] a, byte[] b, int prefix) {
  if (a.length != 4 || b.length != 4 || prefix < 1 || prefix > 32) return false;
  int ia = ((a[0] & 0xFF) << 24) | ((a[1] & 0xFF) << 16) | ((a[2] & 0xFF) << 8) | (a[3] & 0xFF);
  int ib = ((b[0] & 0xFF) << 24) | ((b[1] & 0xFF) << 16) | ((b[2] & 0xFF) << 8) | (b[3] & 0xFF);
  int mask = 0xFFFFFFFF << (32 - prefix);
  return (ia & mask) == (ib & mask);
}

// =========================================================
// TATA LETAK. Semua ukuran relatif terhadap layar.
// Layar potret = mode MIRING, landscape = mode MANUAL. Kalau bentuk layar berubah
// (rotasi, layar terpisah), kendali dikunci supaya kendali tidak pindah di bawah jari.
// =========================================================
void aturTata() {
  boolean landscape = width > height;
  if (landscape != kemudiSlider) {
    kemudiSlider = landscape;
    kunci();
  }
  if (landscape) aturTataLandscape();
  else           aturTataPotret();
}

void aturTataPotret() {
  u = width / 100.0;
  float m  = 4 * u;                    // margin tepi
  float jk = 3 * u;                    // jarak antar kolom
  float kolom = 24 * u;                // lebar kolom kiri/kanan
  float y0 = 0.215 * height;           // awal area utama
  float y1 = 0.795 * height;           // akhir area utama
  float xKanan = width - m - kolom;
  float tTombol = 0.08 * height;

  xKepala = m;
  yJudul  = m + 0.018 * height;
  ySub    = m + 0.047 * height;
  tPil    = 0.036 * height;
  isi(rChip,   m, 0.085 * height, width - 2 * m, 0.07 * height);
  isi(rBanner, m, 0.165 * height, width - 2 * m, 0.04 * height);

  isi(rTrimKiriTambah,  m,      y0 + 0.03 * height,  kolom, tTombol);
  isi(rTrimKiriKurang,  m,      y0 + 0.17 * height,  kolom, tTombol);
  isi(rTrimKananTambah, xKanan, y0 + 0.03 * height,  kolom, tTombol);
  isi(rTrimKananKurang, xKanan, y0 + 0.17 * height,  kolom, tTombol);
  isi(rMode,            m,      y0 + 0.275 * height, kolom, 0.085 * height);
  isi(rHold,            xKanan, y0 + 0.275 * height, kolom, 0.085 * height);
  isi(rGas, m + kolom + jk, y0, width - 2 * (m + kolom + jk), y1 - y0);
  float yMotor = rMode[1] + rMode[3] + 0.025 * height;
  isi(rMotorKiri,  m,      yMotor, kolom, y1 - yMotor);
  isi(rMotorKanan, xKanan, yMotor, kolom, y1 - yMotor);
  isi(rIndikator, m,      0.805 * height, width - 2 * m - kolom - jk, 0.05 * height);
  isi(rLayar,     xKanan, 0.805 * height, kolom, 0.05 * height);
  isi(rBelok, 0, 0, 0, 0);
  isi(rAktif, m, 0.865 * height, width - 2 * m, height - m - 0.865 * height);
}

// Landscape: gas di kiri (ibu jari kiri), belok di kanan-bawah (ibu jari kanan),
// HOLD tepat di atas slider belok. AKTIFKAN dipisah dari slider belok oleh output motor.
void aturTataLandscape() {
  u = height / 100.0;
  float m  = 4 * u;
  float jk = 3 * u;
  float x0 = m + 28 * u + 5 * u;       // area di kanan slider gas
  float lebar = width - m - x0;
  float kolom = (lebar - 3 * jk) / 4;  // empat kolom
  float yA = 40 * u;                   // baris trim, BELOK, HOLD
  float yB = 75 * u;                   // baris AKTIFKAN, motor, slider belok
  float tB = height - m - yB;

  isi(rGas, m, m, 28 * u, height - 2 * m);

  xKepala = x0;
  yJudul  = m + 3.5 * u;
  ySub    = yJudul + u;
  tPil    = 7 * u;
  isi(rChip,   x0, 14 * u, lebar - kolom - jk, 13 * u);
  isi(rLayar,  width - m - kolom, 14 * u, kolom, 13 * u);
  isi(rBanner, x0, 30 * u, lebar, 7 * u);

  float xK2 = x0 + kolom + jk, xK3 = xK2 + kolom + jk, xK4 = xK3 + kolom + jk;
  isi(rTrimKiriTambah,  x0,  yA + 3.5 * u,  kolom, 10 * u);
  isi(rTrimKiriKurang,  x0,  yA + 21.5 * u, kolom, 10 * u);
  isi(rTrimKananTambah, xK2, yA + 3.5 * u,  kolom, 10 * u);
  isi(rTrimKananKurang, xK2, yA + 21.5 * u, kolom, 10 * u);
  isi(rMode, xK3, yA + 3.5 * u, kolom, 28 * u);
  isi(rHold, xK4, yA + 3.5 * u, kolom, 28 * u);

  isi(rAktif, x0, yB, kolom, tB);
  float wMotor = (kolom - 1.5 * u) / 2;
  isi(rMotorKiri,  xK2, yB, wMotor, tB);
  isi(rMotorKanan, xK2 + wMotor + 1.5 * u, yB, wMotor, tB);
  isi(rBelok, xK3, yB, 2 * kolom + jk, tB);
  isi(rIndikator, 0, 0, 0, 0);
}

void isi(float[] r, float x, float y, float w, float h) {
  r[0] = x;
  r[1] = y;
  r[2] = w;
  r[3] = h;
}

boolean di(float[] r, float x, float y) {
  return x >= r[0] && x <= r[0] + r[2] && y >= r[1] && y <= r[1] + r[3];
}

// =========================================================
// DRAW — hanya UI, tidak mengirim paket
// =========================================================
void draw() {
  aturTata();
  boolean tlmAda = millis() - lastTelemetryMs <= TLM_HILANG_MS;

  background(W_LATAR);
  noStroke();
  gambarKepala(tlmAda);
  gambarPeringatan(tlmAda);
  gambarTrim(rTrimKiriTambah, rTrimKiriKurang, "TRIM KIRI", trimKiri);
  gambarTrim(rTrimKananTambah, rTrimKananKurang, "TRIM KANAN", trimKanan);
  gambarTombolMode();
  gambarTombolHold();
  gambarGas();

  // Output motor, dihitung dengan rumus yang sama seperti paket
  float belok = nilaiBelok() * diff_power;
  boolean jalan = lock == 1 && gas > 0;
  gambarMotor(rMotorKiri, "MOTOR KIRI", jalan ? pwmMotor(gas, trimKanan, -belok) : 0);
  gambarMotor(rMotorKanan, "MOTOR KANAN", jalan ? pwmMotor(gas, trimKiri, belok) : 0);

  if (kemudiSlider) gambarSliderBelok();
  else              gambarBelok();
  gambarTombolLayar();
  gambarTombolAktif();

  // Getar (time-based, tidak blocking UI):
  //   baterai lemah kapan saja; link putus atau LQ rendah saat AKTIF
  boolean bahaya = (vcc > 0 && vcc < VBAT_WARN) || (lock == 1 && (!tlmAda || lqFc < LQ_WARN));
  if (bahaya && millis() - lastVib > 1500) {
    lastVib = millis();
    vibe.vibrate(500);
  }

  // Reset telemetri kalau sudah >2 detik tidak ada paket balik
  if (!tlmAda) {
    rssi = 0;
    vcc  = 0;
    lqFc = 0;
  }
}

// =========================================================
// KOMPONEN TAMPILAN
// =========================================================
void kartu(float[] r, int warna) {
  fill(warna);
  rect(r[0], r[1], r[2], r[3], 3 * u);
}

int warnaKartu(float[] r) {
  return r == rDitekan ? W_TEKAN : W_KARTU;
}

void gambarKepala(boolean tlmAda) {
  float m = 4 * u;
  textAlign(LEFT, CENTER);
  fill(W_TEKS);
  textSize(5.5 * u);
  text("WiFi Plane", xKepala, yJudul);
  float xSub = kemudiSlider ? xKepala + textWidth("WiFi Plane") + 3 * u : xKepala;   // landscape: di samping judul

  // Status koneksi ke pesawat
  InetAddress fa = fcAddr;
  String status;
  int warna;
  if (fa == null) {
    status = "Mencari pesawat\u2026";
    warna = W_KUNING;
  } else if (!tlmAda) {
    status = "Link putus";
    warna = W_MERAH;
  } else {
    status = fa.getHostAddress();
    warna = W_HIJAU;
  }
  textSize(3 * u);
  float lebar = textWidth(status) + 9 * u;
  float tinggi = tPil;
  float x = width - m - lebar;
  float y = yJudul - tinggi / 2;
  fill(warna, 40);
  rect(x, y, lebar, tinggi, tinggi / 2);
  fill(warna);
  ellipse(x + 3.5 * u, y + tinggi / 2, 2 * u, 2 * u);
  textAlign(LEFT, CENTER);
  text(status, x + 6 * u, y + tinggi / 2);

  String sub = "desain asli Ravi Butani \u00b7 Instructables";
  fill(W_REDUP);
  textSize(2.6 * u);
  if (!kemudiSlider || xSub + textWidth(sub) < x - 2 * u) text(sub, xSub, ySub);   // landscape: hanya kalau muat

  // Empat chip: sinyal, LQ, baterai, mode kirim
  float yc = rChip[1];
  float hc = rChip[3];
  float jc = 2 * u;
  float wc = (rChip[2] - 3 * jc) / 4;
  for (int k = 0; k < 4; k++) {
    fill(W_KARTU);
    rect(rChip[0] + k * (wc + jc), yc, wc, hc, 3 * u);
  }
  float yl = yc + 0.257 * hc;
  float yv = yc + 0.671 * hc;

  // Sinyal: RSSI dari FC (mode STA), atau diukur HP saat FC mode AP (FC kirim 0)
  int nilaiRssi = rssi != 0 ? rssi : (tlmAda ? rssiHp : 0);
  float x0 = rChip[0];
  label(rssi == 0 && nilaiRssi != 0 ? "SINYAL HP" : "SINYAL", x0 + wc / 2, yl);
  int bar = nilaiRssi == 0 ? 0 : nilaiRssi <= 55 ? 4 : nilaiRssi <= 65 ? 3 : nilaiRssi <= 75 ? 2 : nilaiRssi <= 85 ? 1 : 0;
  ikonSinyal(x0 + 2.5 * u, yv + 1.6 * u, 3.2 * u, bar);
  nilaiSetelahIkon(nilaiRssi == 0 ? "--" : "-" + nilaiRssi + " dBm", x0 + 7.5 * u, yv, W_TEKS);

  // LQ
  x0 += wc + jc;
  label("LQ", x0 + wc / 2, yl);
  int wLq = !tlmAda ? W_REDUP : lqFc >= 80 ? W_HIJAU : lqFc >= LQ_WARN ? W_KUNING : W_MERAH;
  nilai(tlmAda ? lqFc + "%" : "--", x0 + wc / 2, yv, wLq);

  // Baterai
  x0 += wc + jc;
  label("BATERAI", x0 + wc / 2, yl);
  int wBat = vcc == 0 ? W_REDUP : vcc >= 37 ? W_HIJAU : vcc >= 33 ? W_KUNING : W_MERAH;
  ikonBaterai(x0 + 2.5 * u, yv - 1.4 * u, 4.5 * u, 2.8 * u, vcc == 0 ? 0 : constrain((vcc - 30) / 12.0, 0, 1), wBat);
  nilaiSetelahIkon(vcc == 0 ? "-- V" : (vcc / 10) + "." + (vcc % 10) + " V", x0 + 9 * u, yv, wBat);

  // Mode kirim (otomatis, lihat pakaiBroadcast)
  x0 += wc + jc;
  label("MODE", x0 + wc / 2, yl);
  nilai(kirimBroadcast ? "BC" : "UC", x0 + wc / 2, yv, W_BIRU);
}

void label(String t, float x, float y) {
  fill(W_REDUP);
  textSize(2.4 * u);
  textAlign(CENTER, CENTER);
  text(t, x, y);
}

void nilai(String t, float x, float y, int warna) {
  fill(warna);
  textSize(3.6 * u);
  textAlign(CENTER, CENTER);
  text(t, x, y);
}

// Nilai rata kiri, di sebelah ikon
void nilaiSetelahIkon(String t, float x, float y, int warna) {
  fill(warna);
  textSize(3.3 * u);
  textAlign(LEFT, CENTER);
  text(t, x, y);
}

void ikonSinyal(float x, float yBawah, float tinggi, int level) {
  float w = tinggi / 5;
  for (int k = 0; k < 4; k++) {
    float h = tinggi * (k + 1) / 4;
    fill(k < level ? W_HIJAU : W_TEKAN);
    rect(x + k * w * 1.4, yBawah - h, w, h, w / 3);
  }
}

void ikonBaterai(float x, float y, float w, float h, float level, int warna) {
  noFill();
  stroke(warna);
  strokeWeight(0.35 * u);
  rect(x, y, w, h, 0.6 * u);
  noStroke();
  fill(warna);
  rect(x + w, y + h * 0.3, 0.5 * u, h * 0.4);
  rect(x + 0.6 * u, y + 0.6 * u, (w - 1.2 * u) * level, h - 1.2 * u, 0.3 * u);
}

// Satu pesan terpenting di bawah bilah status; kosong kalau semua baik
void gambarPeringatan(boolean tlmAda) {
  String pesan = "";
  int warna = W_REDUP;
  String p = peringatan;
  if (lock == 1 && !tlmAda) {
    pesan = "LINK PUTUS \u2014 motor mati otomatis";
    warna = W_MERAH;
  } else if (vcc > 0 && vcc < VBAT_WARN) {
    pesan = "BATERAI LEMAH \u2014 segera mendarat";
    warna = W_MERAH;
  } else if (millis() < pesanSampai) {
    pesan = pesanSingkat;
    warna = W_KUNING;
  } else if (lock == 1 && lqFc < LQ_WARN) {
    pesan = "SINYAL LEMAH (LQ " + lqFc + "%) \u2014 dekatkan pesawat";
    warna = W_KUNING;
  } else if (p.length() > 0) {
    pesan = "Izin kurang: " + p;
    warna = W_KUNING;
  } else if (lock == 0 && tlmAda) {
    pesan = "Siap. Ketuk AKTIFKAN untuk mulai terbang";
    warna = W_REDUP;
  }
  if (pesan.length() == 0) return;
  float x = rBanner[0], y = rBanner[1], w = rBanner[2], h = rBanner[3];
  fill(warna, warna == W_REDUP ? 25 : 45);
  rect(x, y, w, h, h / 2);
  fill(warna == W_REDUP ? W_REDUP : warna);
  ukuranMuat(pesan, 3 * u, w - 4 * u);
  textAlign(CENTER, CENTER);
  text(pesan, x + w / 2, y + h / 2);
}

void tampilkanPesan(String t) {
  pesanSingkat = t;
  pesanSampai  = millis() + 2000;
}

// Ukuran teks maksimum, dikecilkan kalau teks lebih lebar dari maks
void ukuranMuat(String t, float ukuran, float maks) {
  textSize(ukuran);
  float w = textWidth(t);
  if (w > maks) textSize(ukuran * maks / w);
}

void gambarTrim(float[] rTambah, float[] rKurang, String judul, int nilaiTrim) {
  label(judul, rTambah[0] + rTambah[2] / 2, rTambah[1] - 3 * u);
  kartu(rTambah, warnaKartu(rTambah));
  kartu(rKurang, warnaKartu(rKurang));
  fill(W_TEKS);
  textSize(8 * u);
  textAlign(CENTER, CENTER);
  text("+", rTambah[0] + rTambah[2] / 2, rTambah[1] + rTambah[3] / 2);
  text("\u2212", rKurang[0] + rKurang[2] / 2, rKurang[1] + rKurang[3] / 2);
  float yNilai = (rTambah[1] + rTambah[3] + rKurang[1]) / 2;
  fill(nilaiTrim == 0 ? W_REDUP : W_TEKS);
  textSize(6 * u);
  text((nilaiTrim > 0 ? "+" : "") + nilaiTrim, rTambah[0] + rTambah[2] / 2, yNilai);
}

void gambarTombolMode() {
  boolean ex = exprt_flag == 1;
  kartu(rMode, warnaKartu(rMode));
  float cy = rMode[1] + rMode[3] / 2;
  label("BELOK", rMode[0] + rMode[2] / 2, cy - 4.9 * u);
  fill(ex ? W_UNGU : W_BIRU);
  textSize(6 * u);
  textAlign(CENTER, CENTER);
  text(ex ? "EX" : "BG", rMode[0] + rMode[2] / 2, cy + 2.7 * u);
}

void gambarTombolHold() {
  if (hold) {
    fill(W_ORANYE);
    rect(rHold[0], rHold[1], rHold[2], rHold[3], 3 * u);
  } else {
    kartu(rHold, warnaKartu(rHold));
  }
  float cy = rHold[1] + rHold[3] / 2;
  fill(hold ? W_LATAR : (lock == 1 ? W_TEKS : W_REDUP));
  textSize(2.4 * u);
  textAlign(CENTER, CENTER);
  text(hold ? "GAS DITAHAN" : "TAHAN GAS", rHold[0] + rHold[2] / 2, cy - 4.9 * u);
  textSize(6 * u);
  text("HOLD", rHold[0] + rHold[2] / 2, cy + 2.7 * u);
}

void gambarGas() {
  kartu(rGas, W_KARTU);
  float x = rGas[0], y = rGas[1], w = rGas[2], h = rGas[3];
  // Isi gas dari bawah
  int warna = lock == 0 ? W_REDUP : hold ? W_ORANYE : W_BIRU;
  float hIsi = h * gas / 127.0;
  float yIsi = y + h - hIsi;
  if (hIsi > 0) {
    fill(warna, 210);
    rect(x, yIsi, w, hIsi, 3 * u);
    fill(W_TEKS);
    rect(x + 6 * u, yIsi - 0.4 * u, w - 12 * u, 0.8 * u, 0.4 * u);
  }
  // Tanda skala 25/50/75% di kedua tepi
  fill(W_TEKS, 70);
  for (int k = 1; k <= 3; k++) {
    rect(x, y + h * k / 4, 3 * u, 0.3 * u);
    rect(x + w - 3 * u, y + h * k / 4, 3 * u, 0.3 * u);
  }
  // Judul GAS terang kalau sudah tertutup isian gas
  fill(yIsi < y + 6 * u ? W_TEKS : W_REDUP);
  textSize(2.4 * u);
  textAlign(CENTER, CENTER);
  text("GAS", x + w / 2, y + 4.3 * u);
  float maks = w - 8 * u;   // tidak menabrak tanda skala di tepi
  if (lock == 0) {
    fill(W_REDUP);
    ukuranMuat("TERKUNCI", 5 * u, maks);
    text("TERKUNCI", x + w / 2, y + h / 2);
  } else {
    float yTeks = y + h * 0.42;
    String persen = round(gas * 100 / 127.0) + "%";
    fill(W_TEKS);
    ukuranMuat("100%", 13 * u, maks);   // ukuran tetap, tidak berubah saat gas berubah
    text(persen, x + w / 2, yTeks);
    // Di atas isian gas tulisan dibuat terang supaya tetap terbaca
    fill(yIsi < yTeks + 9 * u ? W_TEKS : W_REDUP, yIsi < yTeks + 9 * u ? 220 : 255);
    String petunjuk = hold ? "GAS DITAHAN" : "geser untuk gas";
    ukuranMuat(petunjuk, 2.8 * u, maks);
    text(petunjuk, x + w / 2, yTeks + 9 * u);
  }
}

void gambarMotor(float[] r, String judul, int pwm) {
  float x = r[0], y = r[1], w = r[2], h = r[3];
  fill(W_KARTU);
  rect(x, y, w, h, 3 * u);
  fill(W_REDUP);
  ukuranMuat("MOTOR KANAN", 2.4 * u, w - 2 * u);   // judul terpanjang: kedua judul sama besar
  textAlign(CENTER, CENTER);
  text(judul, x + w / 2, y + 3.5 * u);
  float bx = x + w / 2 - 3 * u;
  float by = y + 6.5 * u;
  float bh = h - 13.5 * u;
  fill(W_TEKAN);
  rect(bx, by, 6 * u, bh, 1.5 * u);
  float hIsi = bh * pwm / 254.0;
  if (hIsi > 0) {
    fill(W_BIRU);
    rect(bx, by + bh - hIsi, 6 * u, hIsi, 1.5 * u);
  }
  nilai(round(pwm * 100 / 254.0) + "%", x + w / 2, y + h - 3.5 * u, pwm > 0 ? W_TEKS : W_REDUP);
}

// Indikator belok dari kemiringan HP (setelah deadzone), mode MIRING
void gambarBelok() {
  float x = rIndikator[0], y = rIndikator[1], w = rIndikator[2], h = rIndikator[3];
  float cx = x + w / 2;
  fill(W_KARTU);
  rect(x, y, w, h, h / 2);
  fill(W_TEKAN);
  rect(cx - 0.25 * u, y + h * 0.2, 0.5 * u, h * 0.6);
  fill(W_REDUP);
  textSize(2.4 * u);
  textAlign(LEFT, CENTER);
  text("\u2190 KIRI", x + 3 * u, y + h / 2);
  textAlign(RIGHT, CENTER);
  text("KANAN \u2192", x + w - 3 * u, y + h / 2);
  float ax = accelerometerX;
  float pos = constrain(-ax / MIRING_PENUH, -1, 1);   // ax > 0 = HP miring kiri
  fill(ax == 0 ? W_REDUP : W_BIRU);
  ellipse(cx + pos * (w / 2 - h), y + h / 2, h * 0.75, h * 0.75);
}

// Slider belok, mode MANUAL: kenop mengikuti jari, kembali ke tengah saat jari lepas
float rKenop() {
  return rBelok[3] * 0.32;
}

float jangkauanKenop() {   // jarak tengah slider ke posisi kenop paling kiri/kanan
  return rBelok[2] / 2 - rKenop() - 2 * u;
}

void gambarSliderBelok() {
  float x = rBelok[0], y = rBelok[1], w = rBelok[2], h = rBelok[3];
  float cx = x + w / 2;
  float cy = y + h * 0.6;
  float j = jangkauanKenop();
  kartu(rBelok, W_KARTU);
  label("BELOK", cx, y + 3.5 * u);
  fill(W_REDUP);
  textSize(2.4 * u);
  textAlign(LEFT, CENTER);
  text("\u2190 KIRI", x + 3 * u, y + 3.5 * u);
  textAlign(RIGHT, CENTER);
  text("KANAN \u2192", x + w - 3 * u, y + 3.5 * u);
  // Lintasan, tanda tengah, dan isian dari tengah ke kenop
  fill(W_TEKAN);
  rect(cx - j, cy - 0.6 * u, 2 * j, 1.2 * u, 0.6 * u);
  rect(cx - 0.25 * u, cy - 3 * u, 0.5 * u, 6 * u);
  float b = belokSlider;
  float kx = cx + b * j;
  if (b != 0) {
    fill(W_BIRU, 150);
    rect(min(cx, kx), cy - 0.6 * u, abs(kx - cx), 1.2 * u, 0.6 * u);
  }
  float d = 2 * rKenop();
  fill(b == 0 ? W_REDUP : W_BIRU);
  ellipse(kx, cy, d, d);
  fill(W_KARTU);
  ellipse(kx, cy, d * 0.3, d * 0.3);
}

// Tombol ganti mode: MANUAL (landscape) dari potret, MIRING (potret) dari landscape.
// Ikon = HP dalam posisi tujuan. Hanya bisa saat terkunci.
void gambarTombolLayar() {
  float x = rLayar[0], y = rLayar[1], w = rLayar[2], h = rLayar[3];
  int warna = lock == 0 ? W_TEKS : W_REDUP;
  String t = kemudiSlider ? "MIRING" : "MANUAL";
  fill(warnaKartu(rLayar));
  rect(x, y, w, h, kemudiSlider ? 3 * u : h / 2);
  float yv = y + h / 2;
  if (kemudiSlider) {   // kartu setinggi chip: judul di atas
    label("GANTI MODE", x + w / 2, y + 0.257 * h);
    yv = y + 0.671 * h;
  }
  float iw = kemudiSlider ? 2.4 * u : 4.2 * u;
  float ih = kemudiSlider ? 4.2 * u : 2.4 * u;
  textSize(3 * u);
  float lebar = iw + 1.6 * u + textWidth(t);
  float xi = x + (w - lebar) / 2;
  noFill();
  stroke(warna);
  strokeWeight(0.35 * u);
  rect(xi, yv - ih / 2, iw, ih, 0.5 * u);
  noStroke();
  fill(warna);
  textAlign(LEFT, CENTER);
  text(t, xi + iw + 1.6 * u, yv);
}

void gambarTombolAktif() {
  boolean aktif = lock == 1;
  if (aktif) {
    fill(rAktif == rDitekan ? 0xFF16A34A : W_HIJAU);
    rect(rAktif[0], rAktif[1], rAktif[2], rAktif[3], 4 * u);
  } else {
    kartu(rAktif, warnaKartu(rAktif));
    noFill();
    stroke(W_MERAH);
    strokeWeight(0.5 * u);
    rect(rAktif[0], rAktif[1], rAktif[2], rAktif[3], 4 * u);
    noStroke();
  }
  float cx = rAktif[0] + rAktif[2] / 2;
  float cy = rAktif[1] + rAktif[3] / 2;
  float maks = rAktif[2] - 4 * u;
  String judul = aktif ? "AKTIF" : "AKTIFKAN";
  String sub = aktif ? "ketuk untuk mengunci" : (kemudiSlider ? "motor mati" : "pesawat terkunci, motor mati");
  textAlign(CENTER, CENTER);
  fill(aktif ? W_LATAR : W_TEKS);
  ukuranMuat(judul, 7 * u, maks);
  text(judul, cx, cy - 1.5 * u);
  fill(aktif ? 0xFF0B3B1F : W_REDUP);
  ukuranMuat(sub, 2.8 * u, maks);
  text(sub, cx, cy + 4.5 * u);
}

void getar(int ms) {
  if (vibe != null) vibe.vibrate(ms);
}

// =========================================================
// SENSOR CALLBACK
// =========================================================
void onAccelerometerEvent(float x, float y, float z) {
  // Deadzone seperti kode asli
  if (x > 1.5)       x -= 1.5;
  else if (x < -1.5) x += 1.5;
  else               x = 0;
  accelerometerX = x;
}

// =========================================================
// INPUT (multi-touch)
// Setiap jari dilacak dengan id-nya, jadi gas, belok dan tombol bisa dipakai bersamaan.
// Tombol bereaksi saat disentuh, dengan getar singkat.
// Slider dikendalikan jari yang mulai menyentuh di slider itu (jari lain di atasnya diabaikan):
//   gas  : hanya sentuhan yang dimulai saat AKTIF; jari lepas = gas 0 (kecuali HOLD)
//   belok: jari lepas = kembali lurus
// =========================================================
void touchStarted() {
  sentuhan(true);
}

void touchMoved() {
  sentuhan(false);
}

void touchEnded() {
  sentuhan(false);
}

void touchCancelled() {   // mis. gestur sistem mengambil alih: semua jari dianggap lepas
  sentuhan(false);
}

void sentuhan(boolean mulai) {
  aturTata();
  if (mulai && touches.length == 1) {
    // Jari pertama = gerakan baru: jari dari gerakan sebelumnya pasti sudah lepas,
    // walau event lepasnya hilang (id jari dipakai ulang oleh Android)
    idJari = new int[0];
    lepas(false, false, false);
  }
  int[] ids = new int[touches.length];
  boolean gasAda = false, belokAda = false, tombolAda = false;
  for (int k = 0; k < touches.length; k++) {
    int id = touches[k].id;
    ids[k] = id;
    if (mulai && !adaDi(idJari, id)) jariTurun(id, touches[k].x, touches[k].y);
    if (id == idGas) {
      gasAda = true;
      aturGas(touches[k].y);
    }
    if (id == idBelok) {
      belokAda = true;
      aturBelok(touches[k].x);
    }
    if (id == idTombol) tombolAda = true;
  }
  idJari = ids;
  lepas(gasAda, belokAda, tombolAda);
}

// Lepaskan slider dan tombol yang jarinya sudah tidak ada di layar
void lepas(boolean gasAda, boolean belokAda, boolean tombolAda) {
  if (idGas >= 0 && !gasAda) {
    idGas = -1;
    if (!hold) gas = 0;   // jari lepas = gas 0 (safety saat pesawat jatuh), kecuali HOLD
  }
  if (idBelok >= 0 && !belokAda) {
    idBelok = -1;
    belokSlider = 0;
  }
  if (!tombolAda) {
    idTombol = -1;
    rDitekan = null;
  }
}

boolean adaDi(int[] daftar, int id) {
  for (int k = 0; k < daftar.length; k++) if (daftar[k] == id) return true;
  return false;
}

// Jari baru menyentuh layar di (x, y)
void jariTurun(int id, float x, float y) {
  if (di(rGas, x, y)) {
    if (lock == 1 && idGas < 0) idGas = id;
  } else if (kemudiSlider && di(rBelok, x, y)) {
    if (idBelok < 0) idBelok = id;
  } else if (di(rTrimKiriTambah, x, y)) {
    trimKiri++;
    tekan(rTrimKiriTambah, id);
  } else if (di(rTrimKiriKurang, x, y)) {
    trimKiri--;
    tekan(rTrimKiriKurang, id);
  } else if (di(rTrimKananTambah, x, y)) {
    trimKanan++;
    tekan(rTrimKananTambah, id);
  } else if (di(rTrimKananKurang, x, y)) {
    trimKanan--;
    tekan(rTrimKananKurang, id);
  } else if (di(rMode, x, y)) {
    if (exprt_flag == 0) {
      exprt_flag = 1;
      diff_power = DIFF_EX;
    } else {
      exprt_flag = 0;
      diff_power = DIFF_BG;
    }
    tekan(rMode, id);
  } else if (di(rHold, x, y)) {
    // HOLD: aktif = gas ditahan; ditekan lagi = HOLD mati dan gas langsung 0
    // (jari yang masih di slider gas harus diangkat dulu untuk memberi gas lagi)
    if (hold) {
      hold  = false;
      gas   = 0;
      idGas = -1;
      tekan(rHold, id);
    } else if (lock == 1) {
      hold = true;
      tekan(rHold, id);
    }
  } else if (di(rAktif, x, y)) {
    if (lock == 0) {
      gas   = 0;
      hold  = false;
      idGas = -1;
      lock  = 1;
    } else {
      kunci();
    }
    tekan(rAktif, id);
  } else if (di(rLayar, x, y)) {
    tekan(rLayar, id);
    if (lock == 0) orientation(kemudiSlider ? PORTRAIT : LANDSCAPE);
    else           tampilkanPesan("Kunci dulu untuk ganti mode");
  }
}

// Kunci kendali: motor 0, HOLD mati, slider dilepas
void kunci() {
  lock        = 0;
  gas         = 0;
  hold        = false;
  belokSlider = 0;
  idGas       = -1;
  idBelok     = -1;
}

// Posisi jari di slider gas -> gas 0-127 (atas = penuh). Hanya saat AKTIF.
void aturGas(float y) {
  if (lock == 1) gas = constrain(round(127 * (rGas[1] + rGas[3] - y) / rGas[3]), 0, 127);
}

// Posisi jari di slider belok -> -1 (kiri) .. 1 (kanan), dengan deadzone di tengah
void aturBelok(float x) {
  final float DZ = 0.08;
  float v = constrain((x - (rBelok[0] + rBelok[2] / 2)) / jangkauanKenop(), -1, 1);
  if (v > DZ)       belokSlider = (v - DZ) / (1 - DZ);
  else if (v < -DZ) belokSlider = (v + DZ) / (1 - DZ);
  else              belokSlider = 0;
}

void tekan(float[] r, int id) {
  rDitekan = r;
  idTombol = id;
  getar(12);
}

// =========================================================
// RECEIVE TELEMETRI dari FC (hypermedia UDP callback)
// Format: [BIND_ID, RSSI, VBAT*10, LQ %]. Paket valid juga dipakai untuk
// discovery: IP pengirimnya = IP FC.
// =========================================================
void receive(byte[] data, String ip, int port) {
  if (data.length != 4 || data[0] != (byte) BIND_ID) return;   // pesawat lain / paket nyasar

  rssi = data[1] & 0xFF;
  vcc  = data[2] & 0xFF;
  lqFc = data[3] & 0xFF;
  lastTelemetryMs = millis();

  try {
    if (ip.startsWith("/")) ip = ip.substring(1);
    InetAddress a = InetAddress.getByName(ip);   // IP literal: tanpa DNS lookup
    if (!a.equals(fcAddr)) fcAddr = a;
  }
  catch (Exception e) {
    // abaikan alamat tidak valid
  }
}

// =========================================================
// INFO Wi-Fi KLIEN HP (IP & RSSI), satu pembacaan untuk mode kirim, broadcast
// sebelum FC ditemukan, dan RSSI di layar. IP 0 = HP bukan klien Wi-Fi.
// =========================================================
void bacaInfoWifiKlien() {
  int ip = 0, r = 0;
  try {
    if (wifiMgr != null) {
      android.net.wifi.WifiInfo info = wifiMgr.getConnectionInfo();   // butuh ACCESS_WIFI_STATE
      ip = info.getIpAddress();
      r  = info.getRssi();
    }
  }
  catch (SecurityException se) {
    tambahPeringatan("ACCESS_WIFI_STATE");
  }
  catch (Exception e) {
  }
  InetAddress a = null;
  if (ip != 0) {
    try {
      a = InetAddress.getByAddress(new byte[] {(byte) ip, (byte) (ip >> 8), (byte) (ip >> 16), (byte) (ip >> 24)});   // little-endian
    }
    catch (Exception e) {
    }
  }
  ipKlienHp = a;
  rssiHp    = (a != null && r < 0 && r > -127) ? -r : 0;
}

// =========================================================
// REQUEST & BIND KE WI-FI FC
// requestNetwork(): selama request aktif, sistem berusaha mempertahankan jaringan
// Wi-Fi yang cocok (penting untuk AP FC yang tidak punya internet).
// Wi-Fi tanpa internet (tidak VALIDATED) dianggap AP FC -> socket kirim di-bind ke situ.
// Hotspot HP sendiri bukan jaringan Wi-Fi klien, jadi mode STA FC tidak terpengaruh.
// =========================================================
void setupWifiBinding() {
  if (android.os.Build.VERSION.SDK_INT < 23) return;   // Network.bindSocket butuh API 23
  try {
    connMgr = (ConnectivityManager) getActivity().getApplicationContext().getSystemService(Context.CONNECTIVITY_SERVICE);
    NetworkRequest req = new NetworkRequest.Builder()
      .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
      .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
      .build();

    netCallback = new ConnectivityManager.NetworkCallback() {
      public void onAvailable(Network n) {
        // Sebelum Android 8, onCapabilitiesChanged tidak dijamin menyusul onAvailable
        if (android.os.Build.VERSION.SDK_INT < 26) {
          NetworkCapabilities c = connMgr.getNetworkCapabilities(n);
          if (c != null) evaluasiJaringanWifi(n, c);
        }
      }

      public void onCapabilitiesChanged(Network n, NetworkCapabilities c) {
        evaluasiJaringanWifi(n, c);
      }

      public void onLost(Network n) {
        if (n.equals(wifiFC)) {
          wifiFC = null;
          netGen++;
        }
      }
    };

    try {
      connMgr.requestNetwork(req, netCallback);          // butuh CHANGE_NETWORK_STATE
    }
    catch (SecurityException se) {
      tambahPeringatan("CHANGE_NETWORK_STATE");
      connMgr.registerNetworkCallback(req, netCallback); // butuh ACCESS_NETWORK_STATE
    }
  }
  catch (SecurityException se) {
    tambahPeringatan("ACCESS_NETWORK_STATE");
  }
  catch (Exception e) {
    println("Gagal memasang network callback: " + e.getMessage());
  }
}

void evaluasiJaringanWifi(Network n, NetworkCapabilities c) {
  boolean tanpaInternet = !c.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED);
  if (tanpaInternet && !n.equals(wifiFC)) {
    wifiFC = n;
    netGen++;
  } else if (!tanpaInternet && n.equals(wifiFC)) {
    wifiFC = null;
    netGen++;
  }
}

// =========================================================
// LAYAR & WIFI LOCK
// WifiLock dipegang hanya selama app tampil (dilepas di onPause, diambil lagi di onResume).
// =========================================================
void keepScreenOn() {
  // Layar mati = onPause = kendali terkunci di udara
  runOnUiThread(new Runnable() {
    public void run() {
      getActivity().getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
    }
  });
}

void setupPowerAndWifiLocks() {
  Context app = getActivity().getApplicationContext();
  try {
    wifiMgr = (WifiManager) app.getSystemService(Context.WIFI_SERVICE);

    // Wi-Fi tanpa power save: WIFI_MODE_FULL_LOW_LATENCY (4) di Android 10+,
    //    WIFI_MODE_FULL_HIGH_PERF (3) sebelumnya. Hanya berpengaruh saat HP klien Wi-Fi.
    wifiLock = wifiMgr.createWifiLock(android.os.Build.VERSION.SDK_INT >= 29 ? 4 : 3, "RC_WifiLock");
    wifiLock.setReferenceCounted(false);
  }
  catch (Exception e) {
    println("Gagal membuat WifiLock: " + e.getMessage());
  }
  // Tanpa MulticastLock: aplikasi selalu mengirim duluan dan FC membalas unicast
  // Tanpa WakeLock: layar dijaga menyala selama app tampil, jadi CPU tidak tidur
  ambilLocks();
}

void ambilLocks() {
  try {
    if (wifiLock != null) wifiLock.acquire();
  }
  catch (SecurityException e) {
    tambahPeringatan("WAKE_LOCK");
  }
}

void lepasLocks() {
  try {
    if (wifiLock != null && wifiLock.isHeld()) wifiLock.release();
  }
  catch (Exception e) {
  }
}

void tambahPeringatan(String izin) {
  String p = peringatan;
  if (p.indexOf(izin) < 0) peringatan = (p.length() > 0) ? p + ", " + izin : izin;
}

// =========================================================
// LIFECYCLE
// =========================================================
void onPause() {
  // App ter-pause (panggilan masuk, layar mati, pindah app): kunci kendali.
  // Sender thread mengirim 0/0 selama KIRIM_SETELAH_PAUSE_MS -> motor langsung mati,
  // tanpa menunggu failsafe FC, lalu berhenti mengirim. Lock Wi-Fi dilepas supaya
  // baterai HP tidak terkuras di background. Setelah kembali, tekan AKTIFKAN lagi.
  kunci();
  rDitekan = null;
  idTombol = -1;
  idJari   = new int[0];
  pauseMs  = System.currentTimeMillis();
  appAktif = false;
  lepasLocks();
  super.onPause();
}

void onResume() {
  super.onResume();
  ambilLocks();   // saat start pertama lock belum dibuat; setup() yang mengambilnya
  appAktif = true;
}

void onDestroy() {
  // Hentikan sender thread
  senderRunning = false;
  if (senderThread != null) senderThread.interrupt();

  // Lepas network request / callback
  if (connMgr != null && netCallback != null) {
    try {
      connMgr.unregisterNetworkCallback(netCallback);
    }
    catch (Exception e) {
    }
  }

  // Lepas semua lock
  lepasLocks();

  super.onDestroy();
}
