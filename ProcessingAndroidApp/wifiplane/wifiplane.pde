//**************************************************
// WiFi Controlled Tiny Airplane
// Android App Processing file
// By Ravi Butani
// Rajkot INDIA
// Instructables page:https://www.instructables.com/id/WIFI-CONTROLLED-RC-PLANE/
//***************************************************
import hypermedia.net.*; // import UDP library
import ketai.sensors.*;  // import Ketai Sensor library
import ketai.ui.*;
import ketai.net.*;

// ExpressLRS style link, see the plane firmware for the packet layout
int PACKET_RATE_HZ = 50;           // fixed RC packet rate, sent from its own thread
String BIND_PHRASE = "wifiplane";  // must match the plane firmware
int LINK_LOST_MS = 1000;           // no telemetry for this long shows the link as lost
int IP_UNLOCK_MS = 3000;           // no telemetry for this long goes back to broadcast
int LQ_WARN = 50;                  // vibrate below this LQ % while activated
byte P_ID = 1;
byte PKT_RC = 1;
byte PKT_TLM = 2;
byte FLAG_ARMED = 1;
int RC_PKT_LEN = 10;
int TLM_PKT_LEN = 7;
int crcSeed;
int seq = 0;

int app_start=1;
volatile int lock = 0;
volatile int gas = 0;
volatile int rssi=0;
volatile int lq=0;
volatile int vcc=0;
volatile int lastTlmMillis = -100000;
volatile int lastDrawMillis = -100000;
int lastVibeMillis = 0;
UDP udp;             // define the UDP object
KetaiSensor sensor;  // define the Ketai sensor object
KetaiVibrate vibe;
volatile float accelerometerX;
float accelerometerY, accelerometerZ;
int exprt_flag = 0;
volatile float diff_power = 2.2;
int remotPort = 6000;
int localPort = 2390;
volatile int offsetl = 0;
volatile int offsetr = 0;
volatile String remotIp = "255.255.255.255";  // the remote IP address
volatile Boolean remotIpLock = false;

void getBroadcastAddress()
{
  String localIp[] = {"0","0","0","0"};

  if ( KetaiNet.getIP() != null)
    localIp = split(KetaiNet.getIP(), ".");
  println("My ip address is: " + localIp[0] + "." + localIp[1] + "." + localIp[2] + "." + localIp[3]);
  remotIp = localIp[0] + "." + localIp[1] + "." + localIp[2] + ".255"; //build broadcast/multicast adddress
  println("Broadcast address is: " + remotIp);
}

void setup()
{
  size(displayWidth,displayHeight);
  orientation(PORTRAIT);
  crcSeed = bindSeed(BIND_PHRASE);
  udp = new UDP( this, localPort );
  udp.listen( true );
  getBroadcastAddress();
  sensor = new KetaiSensor(this);
  vibe = new KetaiVibrate(this);
  sensor.start();
  thread("sendLoop");
}

void draw()
{
  lastDrawMillis = millis();
  background(125, 255, 200);
  fill(255);
  stroke(163);
  rect(0,0,width/4,height/4);
  rect(3*width/4,0,width/4,height/4);
  rect(0,height/4,width/4,height/4);
  rect(3*width/4,height/4,width/4,height/4);
  rect(0,7*height/8,width,height/8);
  fill(color(255,100,60));
  rect(width/4,0,width/2,7*height/8);
  fill(color(100,150,255));
  rect(width/4,0,width/2,((7*height)/8)-(gas*7*height)/(8*127));

  textSize(height/12);
  textAlign(CENTER,CENTER);
  fill(color(50,100,255));
  text("+", width/8, height/8 - 10);
  text("-", width/8, 3*height/8 - 10);
  text("+", 3*width/4 + width/8, height/8 - 10);
  text("-", 3*width/4 + width/8, 3*height/8 - 10);
  fill(0);
  text(gas*100/127, width/2, height/2);
  text(offsetl, width/8, height/4 - 10);
  text(offsetr, 3*width/4 + width/8, height/4 -10);

  if(exprt_flag == 0){text("BG", width/8, height/2 + height/6);}
  else if(exprt_flag == 1){text("EX", width/8, height/2 + height/6);}
  if(lock == 0)text("LOCKED", width/2, 7*height/8 + height/16);
  else if(lock == 1)text("ACTIVATED", width/2, 7*height/8 + height/16);
  textSize(height/14);
  fill(255);
  text("LQ "+lq+"%", width/2, 3*height/4 - height/12);
  if (rssi == 0 )text("-"+Character.toString('∞')+"dBm", width/2, 3*height/4);
  else text("-"+rssi+"dBm", width/2, 3*height/4);
  text((vcc/10)+"."+(vcc%10)+"V", width/2, 3*height/4 + height/12);
  fill(0);
  textSize(height/30);
  textAlign(CENTER,CENTER);
  text("Instructables", width/2, height/20);
  text("WiFi Plane App", width/2, 2*height/20);
  text("By Ravi Butani", width/2, 3*height/20);
  textSize(height/12);

  int sinceTlm = millis() - lastTlmMillis;
  if (sinceTlm > LINK_LOST_MS)
  {
    vcc = 0;
    rssi = 0;
    lq = 0;
  }
  if (sinceTlm > IP_UNLOCK_MS && remotIpLock)
  {
    remotIpLock=false;
    println("Connection with " + remotIp + " is lost !");
    getBroadcastAddress(); //reset bcast address if network changed
  }
  if (lock == 1 && (vcc < 35 || lq < LQ_WARN) && millis() - lastVibeMillis > 1000)
  {
    vibe.vibrate(500);
    lastVibeMillis = millis();
  }
}

// Sends RC packets at PACKET_RATE_HZ no matter how fast the screen redraws
void sendLoop()
{
  long period = 1000000000L / PACKET_RATE_HZ;
  long next = System.nanoTime();
  while (true)
  {
    // stop sending when the app is paused or frozen so the plane failsafes
    if (millis() - lastDrawMillis < 250)
      udp.send(buildRcPacket(), remotIp, remotPort);
    next += period;
    long wait = next - System.nanoTime();
    if (wait > 0)
    {
      try { Thread.sleep(wait / 1000000L, (int)(wait % 1000000L)); }
      catch (InterruptedException e) { return; }
    }
    else next = System.nanoTime(); // fell behind, don't send a burst
  }
}

byte[] buildRcPacket()
{
  float accX = accelerometerX;
  if(accX > 1.5){accX = accX - 1.5;}
  else if(accX < -1.5){accX = accX + 1.5;}
  else {accX = 0;}
  boolean armed = (lock == 1);
  int l_us = armed ? toMicros(gas + offsetl + accX*diff_power) : 1000;
  int r_us = armed ? toMicros(gas + offsetr - accX*diff_power) : 1000;
  byte[] pkt = new byte[RC_PKT_LEN];
  pkt[0] = P_ID;
  pkt[1] = PKT_RC;
  pkt[2] = (byte)seq;
  pkt[3] = armed ? FLAG_ARMED : 0;
  put16(pkt, 4, l_us);
  put16(pkt, 6, r_us);
  put16(pkt, 8, crc16(pkt, RC_PKT_LEN - 2));
  seq = (seq + 1) & 0xFF;
  return pkt;
}

// motor value 1-127 -> 1000-2000 us channel
int toMicros(float v)
{
  v = constrain(v, 1, 127);
  return 1000 + (int)((v - 1) * 1000 / 126);
}

void put16(byte[] b, int i, int v)
{
  b[i] = (byte)(v & 0xFF);
  b[i+1] = (byte)((v >> 8) & 0xFF);
}

// FNV-1a hash of the binding phrase, same as the plane firmware
int bindSeed(String phrase)
{
  int h = 0x811C9DC5;
  byte[] b = phrase.getBytes();
  for (int i = 0; i < b.length; i++)
  {
    h ^= (b[i] & 0xFF);
    h *= 0x01000193;
  }
  return (h ^ (h >>> 16)) & 0xFFFF;
}

// CRC-16/CCITT starting from the binding seed, same as the plane firmware
int crc16(byte[] data, int len)
{
  int crc = crcSeed;
  for (int i = 0; i < len; i++)
  {
    crc ^= (data[i] & 0xFF) << 8;
    for (int j = 0; j < 8; j++)
      crc = ((crc & 0x8000) != 0) ? ((crc << 1) ^ 0x1021) : (crc << 1);
    crc &= 0xFFFF;
  }
  return crc;
}

void onAccelerometerEvent(float x, float y, float z)
{
  accelerometerX = x;
  accelerometerY = y;
  accelerometerZ = z;
}

void mouseDragged()
{
  if(mouseY<7*height/8 && mouseX>width/4 && mouseX<3*width/4 && lock==1)  gas = 127-(int)(((float)mouseY/((float)(7*height/8)))*(float)127);
}

void mousePressed()
{
  if(mouseX<width/4 && mouseY<height/4) offsetl++;
  else if(mouseX<width/4 && mouseY<height/2) offsetl--;
  else if(mouseX>3*width/4 && mouseY<height/4) offsetr++;
  else if(mouseX>3*width/4 && mouseY<height/2) offsetr--;
  else if(mouseX<width/4 && mouseY<3*height/4){
    if(exprt_flag == 0){exprt_flag = 1; diff_power = 3.9;}
    else{exprt_flag = 0; diff_power = 2.2;}
  }
  else if(mouseY>7*height/8){
    gas=0;
    if (lock == 0)lock =1;
    else lock=0;
  }
}

void lockRemoteIp(String ip)
{
  remotIp=ip;
  remotIpLock = true;
  println("Remote ip is locked to: " + ip);
}

void receive( byte[] data, String ip, int port ) {  // <-- extended handler
  if (data.length < TLM_PKT_LEN || data[0] != P_ID || data[1] != PKT_TLM)
    return;
  if (crc16(data, TLM_PKT_LEN - 2) != ((data[5] & 0xFF) | ((data[6] & 0xFF) << 8)))
    return; // corrupt or from a plane with another binding phrase
  rssi = data[2] & 0xFF;
  lq   = data[3] & 0xFF;
  vcc  = (data[4] & 0xFF) + 3;
  lastTlmMillis = millis();
  if (! remotIpLock)
    lockRemoteIp(ip);
}
