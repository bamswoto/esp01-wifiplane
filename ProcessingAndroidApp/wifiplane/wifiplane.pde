//***************************************************
// WiFi Controlled Tiny Airplane - Android Controller
// PROFIL JANGKAUAN MAKSIMUM (latensi boleh lebih tinggi)
// Background sender thread (~250 Hz) + buffer reuse
// ELRS-style Packet Integrity (CRC8, nilai awal = BIND_ID) + nomor urut 16-bit
// Paket kendali (6 byte): [0xEA, SEQ lo, SEQ hi, PWM KANAN, PWM KIRI, CRC8]
// Discovery: IP FC diambil dari telemetri valid
// Mode kirim otomatis (ditampilkan di area kanan-tengah):
//   BC = broadcast ke subnet FC, saat HP jadi hotspot (FC mode STA): frame grup, tanpa retry MAC.
//        Tidak ditahan sampai beacon DTIM selama FC tidak sleep dan tidak ada perangkat lain di hotspot
//   UC = unicast ke IP FC, saat HP klien Wi-Fi (FC mode AP, atau router rumah): ACK + retry MAC
// Gas: jari lepas = gas 0 (safety saat pesawat jatuh). Tombol HOLD (kanan-bawah)
//   menahan gas supaya trim bisa diatur; tekan HOLD lagi = HOLD mati + gas 0.
//   Gas 0 = kedua motor mati, kemiringan HP dan trim tidak memutar motor.
// Jaringan Wi-Fi tanpa internet (AP FC) di-request agar tidak dilepas sistem,
// dan socket kirim di-bind ke jaringan itu (tetap jalan walau data seluler ON)
// Izin (Android > Sketch Permissions): INTERNET, VIBRATE, WAKE_LOCK, ACCESS_WIFI_STATE,
//   CHANGE_WIFI_MULTICAST_STATE, ACCESS_NETWORK_STATE, CHANGE_NETWORK_STATE
//   Izin yang kurang ditampilkan di layar.
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
import android.os.PowerManager;
import android.view.WindowManager;
import java.net.InetAddress;
import java.net.Inet4Address;
import java.net.InterfaceAddress;
import java.net.NetworkInterface;
import java.net.DatagramSocket;
import java.net.DatagramPacket;
import java.util.Collections;

// =========================================================
// BINDING: nilai awal CRC8, HARUS sama dengan BIND_ID di firmware FC
// =========================================================
final int BIND_ID = 0x5A;

// Gain diferensial accelerometer per mode (dipakai saat start DAN saat toggle)
final float DIFF_BG = 4.0;   // mode BG
final float DIFF_EX = 7.0;   // mode EX

// Peringatan getar
final int VBAT_WARN     = 30;    // baterai < 3.0 V, sama dengan batas pemutus motor di FC
final int LQ_WARN       = 50;    // LQ < 50% saat ACTIVATED
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

// Mode kirim: true = BC (broadcast subnet FC), false = UC (unicast). Dipilih otomatis, lihat pakaiBroadcast()
volatile boolean kirimBroadcast = true;

// State telemetri: ditulis receiver callback, dibaca UI thread
volatile int rssi          = 0;
volatile int vcc           = 0;
volatile int lqFc          = 0;   // LQ % yang dihitung FC dari nomor urut paket
volatile long lastTelemetryMs = -100000;

// RSSI yang diukur HP sendiri (dipakai saat FC mode AP, yang mengirim RSSI 0)
int  rssiHp     = 0;
long lastRssiHp = 0;

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
volatile String peringatan = "";   // lock/izin yang gagal, ditampilkan di layar

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
PowerManager.WakeLock wakeLock;
WifiManager.MulticastLock multicastLock;

// =========================================================
// SETUP
// =========================================================
void setup() {
  size(displayWidth, displayHeight);
  orientation(PORTRAIT);

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
  final byte[] buf = new byte[6];
  DatagramPacket pkt = new DatagramPacket(buf, buf.length);
  pkt.setPort(remotPort);

  InetAddress fallbackAddr = null;
  long nextFallbackMs = 0;

  InetAddress fcUntukBc = null;   // IP FC yang broadcast-nya sudah dihitung
  InetAddress bcFc      = null;   // alamat broadcast subnet FC

  InetAddress fcUntukMode = null; // IP FC yang mode kirimnya sudah dipilih
  long nextModeMs = 0;            // pilih ulang tiap detik (jaringan HP bisa berubah)

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

      // --- Tentukan tujuan ---
      InetAddress fa = fcAddr;
      InetAddress target;
      if (fa != null) {
        long nowModeMs = System.currentTimeMillis();
        if (!fa.equals(fcUntukMode) || nowModeMs >= nextModeMs) {
          kirimBroadcast = pakaiBroadcast(fa);
          fcUntukMode = fa;
          nextModeMs = nowModeMs + 1000;
        }
        if (kirimBroadcast) {
          if (!fa.equals(fcUntukBc)) {
            bcFc = broadcastUntuk(fa);
            fcUntukBc = fa;
          }
          target = bcFc;
        } else {
          target = fa;
        }
      } else {
        long nowMs = System.currentTimeMillis();
        if (nowMs >= nextFallbackMs) {
          fallbackAddr = getWifiBroadcastAddr();
          nextFallbackMs = nowMs + 1000;
        }
        target = fallbackAddr;
      }

      // Setelah app ter-pause: kirim 0/0 sebentar (motor langsung mati), lalu berhenti
      boolean kirim = appAktif || System.currentTimeMillis() - pauseMs < KIRIM_SETELAH_PAUSE_MS;

      if (target != null && kirim) {
        // --- Snapshot state (volatile read) lalu susun paket 6 byte ---
        isiPaket(buf, seq, gas, trimKiri, trimKanan, accelerometerX, diff_power, lock);

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
// PAKET KENDALI (6 byte): [0xEA, SEQ lo, SEQ hi, PWM KANAN, PWM KIRI, CRC8]
// LOCK atau gas 0 = kedua motor 0 (kemiringan HP dan trim tidak memutar motor)
// =========================================================
void isiPaket(byte[] buf, int seq, int g, int tKiri, int tKanan, float ax, float dp, int lk) {
  // --- Mixing seperti kode asli ---
  // HP miring kiri (ax > 0) -> motor kanan lebih kencang -> pesawat belok kiri
  int kanan = (int)((float)g + (float)tKiri + ax * dp);
  int kiri  = (int)((float)g + (float)tKanan - ax * dp);

  int pwmKanan = constrain(kanan * 2, 0, 255);
  int pwmKiri  = constrain(kiri * 2, 0, 255);

  buf[0] = (byte) 0xEA;   // Header
  buf[1] = (byte) (seq & 0xFF);
  buf[2] = (byte) ((seq >> 8) & 0xFF);
  if (lk == 1 && g > 0) {
    buf[3] = (byte) pwmKanan;
    buf[4] = (byte) pwmKiri;
  } else {
    buf[3] = (byte) 0x00;
    buf[4] = (byte) 0x00;
  }
  buf[5] = calculateCRC8(buf, 5);
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
// Caranya: FC satu subnet dengan Wi-Fi klien HP -> UC, selain itu FC ada di hotspot HP -> BC.
// =========================================================
boolean pakaiBroadcast(InetAddress fc) {
  byte[] f = fc.getAddress();
  int ip = 0;
  try {
    if (wifiMgr != null) ip = wifiMgr.getConnectionInfo().getIpAddress();   // 0 = HP bukan klien Wi-Fi
  }
  catch (Exception e) {
  }
  if (ip == 0 || f.length != 4) return true;
  byte[] hp = {(byte) ip, (byte) (ip >> 8), (byte) (ip >> 16), (byte) (ip >> 24)};   // little-endian

  int prefix = 24;   // subnet hotspot Android, softAP ESP dan kebanyakan router rumah
  try {
    for (NetworkInterface ni : Collections.list(NetworkInterface.getNetworkInterfaces())) {
      for (InterfaceAddress ia : ni.getInterfaceAddresses()) {
        if (java.util.Arrays.equals(ia.getAddress().getAddress(), hp)) prefix = ia.getNetworkPrefixLength();
      }
    }
  }
  catch (Exception e) {
    // pakai asumsi /24
  }
  return !samaSubnet(hp, f, prefix);
}

// =========================================================
// ALAMAT BROADCAST SUBNET FC
// Dicari dari interface lokal yang subnetnya memuat IP FC (hotspot atau Wi-Fi klien).
// Jika gagal, asumsi /24 (subnet hotspot Android dan softAP ESP sama-sama /24).
// =========================================================
InetAddress broadcastUntuk(InetAddress fc) {
  byte[] f = fc.getAddress();
  if (f.length != 4) return fc;
  try {
    for (NetworkInterface ni : Collections.list(NetworkInterface.getNetworkInterfaces())) {
      if (!ni.isUp() || ni.isLoopback()) continue;
      for (InterfaceAddress ia : ni.getInterfaceAddresses()) {
        InetAddress a = ia.getAddress();
        InetAddress b = ia.getBroadcast();
        if (!(a instanceof Inet4Address) || b == null) continue;
        if (samaSubnet(a.getAddress(), f, ia.getNetworkPrefixLength())) return b;
      }
    }
  }
  catch (Exception e) {
    // lanjut ke asumsi /24
  }
  try {
    return InetAddress.getByAddress(new byte[] {f[0], f[1], f[2], (byte) 255});
  }
  catch (Exception e) {
    return fc;
  }
}

boolean samaSubnet(byte[] a, byte[] b, int prefix) {
  if (a.length != 4 || b.length != 4 || prefix < 1 || prefix > 32) return false;
  int ia = ((a[0] & 0xFF) << 24) | ((a[1] & 0xFF) << 16) | ((a[2] & 0xFF) << 8) | (a[3] & 0xFF);
  int ib = ((b[0] & 0xFF) << 24) | ((b[1] & 0xFF) << 16) | ((b[2] & 0xFF) << 8) | (b[3] & 0xFF);
  int mask = 0xFFFFFFFF << (32 - prefix);
  return (ia & mask) == (ib & mask);
}

// =========================================================
// DRAW — hanya UI, tidak mengirim paket
// =========================================================
void draw() {
  background(125, 255, 200);
  fill(255);
  stroke(163);
  rect(0, 0, width/4, height/4);
  rect(3*width/4, 0, width/4, height/4);
  rect(0, height/4, width/4, height/4);
  rect(3*width/4, height/4, width/4, height/4);
  rect(0, 7*height/8, width, height/8);

  // Tombol HOLD (kanan-bawah), oranye saat aktif
  fill(hold ? color(255, 170, 0) : 255);
  rect(3*width/4, 3*height/4, width/4, height/8);

  fill(color(255, 100, 60));
  rect(width/4, 0, width/2, 7*height/8);
  fill(color(100, 150, 255));
  rect(width/4, 0, width/2, ((7*height)/8) - (gas*7*height)/(8*127));

  textSize(height/12);
  textAlign(CENTER, CENTER);
  fill(color(50, 100, 255));
  text("+", width/8, height/8 - 10);
  text("-", width/8, 3*height/8 - 10);
  text("+", 3*width/4 + width/8, height/8 - 10);
  text("-", 3*width/4 + width/8, 3*height/8 - 10);

  fill(0);
  text(gas*100/127, width/2, height/2);
  text(trimKiri, width/8, height/4 - 10);
  text(trimKanan, 3*width/4 + width/8, height/4 - 10);

  if (exprt_flag == 0) text("BG", width/8, height/2 + height/6);
  else                 text("EX", width/8, height/2 + height/6);

  // Mode kirim (otomatis, lihat pakaiBroadcast)
  if (kirimBroadcast) text("BC", 3*width/4 + width/8, height/2 + height/6);
  else                text("UC", 3*width/4 + width/8, height/2 + height/6);

  if (lock == 0) text("LOCKED", width/2, 7*height/8 + height/16);
  else           text("ACTIVATED", width/2, 7*height/8 + height/16);

  textSize(height/24);
  text(hold ? "HOLD ON" : "HOLD", 3*width/4 + width/8, 3*height/4 + height/16);

  // RSSI: dari FC (mode STA), atau diukur HP sendiri saat FC mode AP (FC kirim 0)
  if (millis() - lastRssiHp > 500) {
    lastRssiHp = millis();
    rssiHp = bacaRssiHp();
  }
  boolean tlmAda = millis() - lastTelemetryMs <= TLM_HILANG_MS;

  textSize(height/14);
  fill(255);
  if (rssi != 0)                  text("-" + rssi + "dBm", width/2, 3*height/4);
  else if (tlmAda && rssiHp != 0) text("-" + rssiHp + "dBm HP", width/2, 3*height/4);
  else                            text("-" + Character.toString('∞') + "dBm", width/2, 3*height/4);
  text((vcc/10) + "." + (vcc%10) + "V", width/2, 3*height/4 + height/12);

  fill(0);
  textSize(height/30);
  textAlign(CENTER, CENTER);
  text("Instructables", width/2, height/20);
  text("WiFi Plane App", width/2, 2*height/20);
  text("By Ravi Butani", width/2, 3*height/20);

  // Status discovery FC
  InetAddress fa = fcAddr;
  if (fa == null) text("FC: mencari...", width/2, 4*height/20);
  else            text("FC: " + fa.getHostAddress(), width/2, 4*height/20);

  // Link quality: % paket diterima FC dari nomor urut, dan paket dikirim HP per detik
  text("LQ: " + lqFc + "% (tx " + txPerDetik + "/s)", width/2, 5*height/20);

  // Lock/izin yang gagal
  String p = peringatan;
  if (p.length() > 0) {
    fill(color(200, 0, 0));
    text("Izin kurang: " + p, width/2, 6*height/20);
  }
  textSize(height/12);

  // Getar (time-based, tidak blocking UI):
  //   baterai lemah kapan saja; link putus atau LQ rendah saat ACTIVATED
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
// CRC8 (identik dengan sisi ESP8266, nilai awal = BIND_ID)
// =========================================================
byte calculateCRC8(byte[] data, int length) {
  int crc = BIND_ID & 0xFF;
  for (int i = 0; i < length; i++) {
    crc ^= (data[i] & 0xFF);
    for (int j = 0; j < 8; j++) {
      if ((crc & 0x80) != 0) {
        crc = ((crc << 1) ^ 0x07) & 0xFF;
      } else {
        crc = (crc << 1) & 0xFF;
      }
    }
  }
  return (byte) (crc & 0xFF);
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
// INPUT
// =========================================================
void mouseDragged() {
  if (mouseY < 7*height/8 && mouseX > width/4 && mouseX < 3*width/4 && lock == 1) {
    gas = 127 - (int)(((float)mouseY / ((float)(7*height/8))) * (float)127);
  }
}

void mousePressed() {
  if (mouseX < width/4 && mouseY < height/4)              trimKiri++;
  else if (mouseX < width/4 && mouseY < height/2)         trimKiri--;
  else if (mouseX > 3*width/4 && mouseY < height/4)       trimKanan++;
  else if (mouseX > 3*width/4 && mouseY < height/2)       trimKanan--;
  else if (mouseX < width/4 && mouseY < 3*height/4) {
    if (exprt_flag == 0) {
      exprt_flag = 1;
      diff_power = DIFF_EX;
    } else {
      exprt_flag = 0;
      diff_power = DIFF_BG;
    }
  } else if (mouseX > 3*width/4 && mouseY < 3*height/4) {
    // Area BC/UC: hanya tampilan, mode kirim dipilih otomatis
  } else if (mouseX > 3*width/4 && mouseY < 7*height/8) {
    // HOLD: aktif = gas ditahan; ditekan lagi = HOLD mati dan gas langsung 0
    if (hold) {
      hold = false;
      gas  = 0;
    } else if (lock == 1) {
      hold = true;
    }
  } else if (mouseY > 7*height/8) {
    gas  = 0;
    hold = false;
    if (lock == 0) lock = 1;
    else           lock = 0;
  }
}

void mouseReleased() {
  // Jari lepas = gas 0 (safety saat pesawat jatuh), kecuali HOLD aktif
  if (!hold) gas = 0;
}

// =========================================================
// RECEIVE TELEMETRI dari FC (hypermedia UDP callback)
// Format: [P_ID, RSSI, VBAT*10, LQ %, CRC8]. Paket valid juga dipakai untuk
// discovery: IP pengirimnya = IP FC.
// =========================================================
void receive(byte[] data, String ip, int port) {
  if (data.length != 5) return;
  if (calculateCRC8(data, 4) != data[4]) return;

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
// BROADCAST FALLBACK (hanya dipakai sebelum IP FC ditemukan)
// DhcpInfo berisi DHCP koneksi Wi-Fi KLIEN HP, bukan subnet hotspot.
// Return null kalau HP bukan klien Wi-Fi (mis. HP sedang jadi hotspot).
// =========================================================
InetAddress getWifiBroadcastAddr() {
  try {
    if (wifiMgr == null) return null;
    android.net.DhcpInfo dhcp = wifiMgr.getDhcpInfo();   // butuh ACCESS_WIFI_STATE

    if (dhcp != null && dhcp.gateway != 0) {
      int broadcast = (dhcp.gateway & dhcp.netmask) | ~dhcp.netmask;
      byte[] quads = new byte[4];
      for (int k = 0; k < 4; k++)
        quads[k] = (byte) ((broadcast >> (k * 8)) & 0xFF);

      return InetAddress.getByAddress(quads);
    }
  }
  catch (SecurityException se) {
    tambahPeringatan("ACCESS_WIFI_STATE");
  }
  catch (Exception e) {
    // abaikan; tunggu discovery dari telemetri FC
  }
  return null;
}

// RSSI AP yang diukur HP (HP sebagai klien Wi-Fi), 0 kalau tidak ada
int bacaRssiHp() {
  try {
    if (wifiMgr == null) return 0;
    int r = wifiMgr.getConnectionInfo().getRssi();   // butuh ACCESS_WIFI_STATE
    if (r < 0 && r > -127) return -r;
  }
  catch (Exception e) {
  }
  return 0;
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
// LAYAR & LOCKS
// Lock dipegang hanya selama app tampil (dilepas di onPause, diambil lagi di onResume).
// Tiap lock di try sendiri: satu izin kurang tidak membatalkan lock lain.
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

    // 1. Wi-Fi tanpa power save: WIFI_MODE_FULL_LOW_LATENCY (4) di Android 10+,
    //    WIFI_MODE_FULL_HIGH_PERF (3) sebelumnya. Hanya berpengaruh saat HP klien Wi-Fi.
    wifiLock = wifiMgr.createWifiLock(android.os.Build.VERSION.SDK_INT >= 29 ? 4 : 3, "RC_WifiLock");
    wifiLock.setReferenceCounted(false);

    // 2. Buka blokir broadcast/multicast UDP (telemetri broadcast FC mode AP)
    multicastLock = wifiMgr.createMulticastLock("RC_MulticastLock");
    multicastLock.setReferenceCounted(false);
  }
  catch (Exception e) {
    println("Gagal membuat WifiLock/MulticastLock: " + e.getMessage());
  }
  try {
    // 3. Cegah CPU tidur
    PowerManager powerManager = (PowerManager) app.getSystemService(Context.POWER_SERVICE);
    wakeLock = powerManager.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "wifiplane:RC_WakeLock");
    wakeLock.setReferenceCounted(false);
  }
  catch (Exception e) {
    println("Gagal membuat WakeLock: " + e.getMessage());
  }
  ambilLocks();
}

void ambilLocks() {
  try {
    if (wifiLock != null) wifiLock.acquire();
  }
  catch (SecurityException e) {
    tambahPeringatan("WAKE_LOCK");
  }
  try {
    if (multicastLock != null) multicastLock.acquire();
  }
  catch (SecurityException e) {
    tambahPeringatan("CHANGE_WIFI_MULTICAST_STATE");
  }
  try {
    if (wakeLock != null) wakeLock.acquire();
  }
  catch (SecurityException e) {
    tambahPeringatan("WAKE_LOCK");
  }
}

void lepasLocks() {
  try {
    if (multicastLock != null && multicastLock.isHeld()) multicastLock.release();
    if (wifiLock      != null && wifiLock.isHeld())      wifiLock.release();
    if (wakeLock      != null && wakeLock.isHeld())      wakeLock.release();
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
  // tanpa menunggu failsafe FC, lalu berhenti mengirim. Lock dilepas supaya
  // baterai HP tidak terkuras di background. Setelah kembali, tekan ACTIVATED lagi.
  gas      = 0;
  hold     = false;
  lock     = 0;
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
