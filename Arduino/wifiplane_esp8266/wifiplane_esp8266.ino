//**************************************************
// WiFi Controlled Tiny Airplane
// ESP8266 Firmware ino file
// By Ravi Butani
// Rajkot INDIA
// Instructables page: https://www.instructables.com/id/WIFI-CONTROLLED-RC-PLANE/
//***************************************************
#include <ESP8266WiFi.h>
#include <WiFiUdp.h>

// ExpressLRS style link: the app sends RC packets at a fixed rate with a sequence number,
// stale packets are dropped, link quality (LQ) is counted from sequence gaps, telemetry is
// sent back every TLM_RATIO packets and the CRC is seeded from the binding phrase.
#define P_ID 1
#define BIND_PHRASE "wifiplane" // must match the app, packets from other phones fail the CRC
#define TLM_RATIO 10  // send link stats every 10 RC packets (1:10), 5 Hz at 50 Hz packet rate
#define LQ_WINDOW 100 // LQ = % of the last 100 RC packets received
#define DC_RX   900   // Time in mS for tx inactivity 200 old problem of motor stopping flickring

#define PKT_RC      0x01 // app -> plane: P_ID, type, seq, flags, ch1 (2), ch2 (2), crc (2)
#define PKT_TLM     0x02 // plane -> app: P_ID, type, rssi, lq, vcc, crc (2)
#define RC_PKT_LEN  10
#define TLM_PKT_LEN 7
#define FLAG_ARMED  0x01

//#define SERIAL_DEBUG  //Enable serial debugging

#define LONG_RANGE          //Max range: 802.11b, max TX power, no modem sleep
#define TX_POWER_DBM   20.5 //0 - 20.5 dBm, lower it if the ESP resets when motors spin up
#define PHY_SWITCH_MS 15000 //Alternate 802.11b/g while connecting, for hotspots that refuse 802.11b

// ESP-12E / ESP-12F / NodeMCU / Wemos D1 mini
#define ST_LED  2 // onboard LED
#define L_MOTOR 5 // D1
#define R_MOTOR 4 // D2

#define PWM_RANGE 1000 // one step per microsecond of the 1000-2000 us channel value
#define MOTOR_OFF 0

ADC_MODE(ADC_VCC);

unsigned long premillis_rx   = 0;

bool    linked   = false; // receiving RC packets, false after DC_RX failsafe
uint8_t last_seq = 0;
uint8_t tlm_seq  = 0;     // seq of the RC packet that last triggered telemetry
uint8_t lq_hist[LQ_WINDOW];
uint8_t lq_idx   = 0;
uint8_t lq       = 0;     // received packets in the window, equals LQ %
uint16_t crc_seed;

int status = WL_IDLE_STATUS;
char ssid[] = "wifiplane";   //  your network SSID (name)
char pass[] = "wifiplane1234";    // your network password (use for WPA, or use as key for WEP)
int keyIndex = 0;            // your network key Index number (needed only for WEP)
IPAddress remotIp;
unsigned int localPort = 6000;      // local port to listen on
unsigned int remotPort = 2390;      // local port to talk on
uint8_t packetBuffer[16]; //buffer to hold incoming packet
WiFiUDP Udp;

// FNV-1a hash of the binding phrase, like the ELRS UID it makes the CRC unique per pair
uint16_t bindSeed(const char *phrase)
{
  uint32_t h = 2166136261UL;
  while (*phrase)
  {
    h ^= (uint8_t)*phrase++;
    h *= 16777619UL;
  }
  return (uint16_t)(h ^ (h >> 16));
}

// CRC-16/CCITT starting from the binding seed
uint16_t crc16(const uint8_t *data, uint8_t len)
{
  uint16_t crc = crc_seed;
  while (len--)
  {
    crc ^= (uint16_t)(*data++) << 8;
    for (uint8_t i = 0; i < 8; i++)
      crc = (crc & 0x8000) ? (crc << 1) ^ 0x1021 : crc << 1;
  }
  return crc;
}

uint16_t get16(const uint8_t *p)
{
  return p[0] | (p[1] << 8);
}

void lqReset()
{
  memset(lq_hist, 0, sizeof(lq_hist));
  lq = 0;
}

void lqPush(uint8_t received)
{
  lq -= lq_hist[lq_idx];
  lq_hist[lq_idx] = received;
  lq += received;
  lq_idx = (lq_idx + 1) % LQ_WINDOW;
}

// channel value 1000-2000 us -> motor PWM
void setMotor(uint8_t pin, uint16_t us)
{
  us = constrain(us, 1000, 2000);
  analogWrite(pin, us - 1000);
}

void sendTelemetry()
{
  uint8_t tlm[TLM_PKT_LEN];
  long rssi = abs(WiFi.RSSI());
  float vcc = (((float)ESP.getVcc()/(float)1024.0)+0.75f)*10;
  tlm[0] = P_ID;
  tlm[1] = PKT_TLM;
  tlm[2] = (uint8_t)rssi;
  tlm[3] = lq;
  tlm[4] = (uint8_t)vcc;
  uint16_t crc = crc16(tlm, TLM_PKT_LEN - 2);
  tlm[5] = crc & 0xFF;
  tlm[6] = crc >> 8;
  Udp.beginPacket(remotIp, remotPort);
  Udp.write(tlm, TLM_PKT_LEN);
  Udp.endPacket();
}

// the setup function runs once when you press reset or power the board
void setup() {
  crc_seed = bindSeed(BIND_PHRASE);
  WiFi.persistent(false);
  WiFi.mode(WIFI_STA);
#ifdef LONG_RANGE
  WiFi.setPhyMode(WIFI_PHY_MODE_11B);  // 802.11b: highest TX power and best RX sensitivity (down to 1 Mbps)
  WiFi.setOutputPower(TX_POWER_DBM);
  WiFi.setSleepMode(WIFI_NONE_SLEEP);  // modem sleep delays and drops control packets
#endif //LONG_RANGE
  WiFi.setAutoReconnect(true);
  analogWriteFreq(5000);
  analogWriteRange(PWM_RANGE);
  pinMode(L_MOTOR, OUTPUT);
  pinMode(R_MOTOR, OUTPUT);
  analogWrite(L_MOTOR,MOTOR_OFF);
  analogWrite(R_MOTOR,MOTOR_OFF);
  pinMode(ST_LED, OUTPUT);
  digitalWrite(ST_LED,HIGH);
#ifdef SERIAL_DEBUG
  Serial.begin(115200);
#endif //SERIAL_DEBUG
  WiFi.begin(ssid, pass);
#ifdef LONG_RANGE
  unsigned long premillis_phy = millis();
#endif //LONG_RANGE
  while (WiFi.status() != WL_CONNECTED)
  {
    digitalWrite(ST_LED,LOW);
    delay(60);
    digitalWrite(ST_LED,HIGH);
    delay(1000);
#ifdef SERIAL_DEBUG
    Serial.print(".");
#endif //SERIAL_DEBUG
#ifdef LONG_RANGE
    if(millis()-premillis_phy > PHY_SWITCH_MS)
    {
      premillis_phy = millis();
      WiFi.disconnect();
      WiFi.setPhyMode(WiFi.getPhyMode() == WIFI_PHY_MODE_11B ? WIFI_PHY_MODE_11G : WIFI_PHY_MODE_11B);
      WiFi.setOutputPower(TX_POWER_DBM);
      WiFi.begin(ssid, pass);
    #ifdef SERIAL_DEBUG
      Serial.print(WiFi.getPhyMode() == WIFI_PHY_MODE_11B ? "[11b]" : "[11g]");
    #endif //SERIAL_DEBUG
    }
#endif //LONG_RANGE
  }
  Udp.begin(localPort);
}

// the loop function runs over and over again forever
void loop() {
  delay(5);
  if(WiFi.status() == WL_CONNECTED)
  {
    digitalWrite(ST_LED,LOW);
    // read all queued packets so the newest command is applied without lag
    while (Udp.parsePacket())
    {
      // read the packet into packetBufffer
      int len = Udp.read(packetBuffer, sizeof(packetBuffer));
      if (len != RC_PKT_LEN || packetBuffer[0] != P_ID || packetBuffer[1] != PKT_RC)
        continue;
      if (crc16(packetBuffer, RC_PKT_LEN - 2) != get16(packetBuffer + RC_PKT_LEN - 2))
        continue; // corrupt or from a phone with another binding phrase
      uint8_t seq = packetBuffer[2];
      if (linked && (int8_t)(seq - last_seq) <= 0)
        continue; // older than what we already applied
      if (linked)
      {
        for (uint8_t gap = seq - last_seq; gap > 1; gap--)
          lqPush(0); // count the packets lost in between
      }
      else
      {
        lqReset(); // LQ climbs from 0 after (re)connecting, like ELRS
      }
      lqPush(1);

      bool armed = packetBuffer[3] & FLAG_ARMED;
      uint16_t l_us = armed ? get16(packetBuffer + 4) : 1000;
      uint16_t r_us = armed ? get16(packetBuffer + 6) : 1000;
      setMotor(L_MOTOR, l_us);
      setMotor(R_MOTOR, r_us);
    #ifdef SERIAL_DEBUG
      Serial.print(l_us);
      Serial.print(" \t");
      Serial.print(r_us);
      Serial.print(" \tLQ ");
      Serial.println(lq);
    #endif //SERIAL_DEBUG

      remotIp = Udp.remoteIP(); // unicast telemetry is acked and retried, broadcast is not
      if (!linked || (uint8_t)(seq - tlm_seq) >= TLM_RATIO)
      {
        tlm_seq = seq;
        sendTelemetry(); // reply right away on connect so the app locks onto our IP
      }
      last_seq = seq;
      linked = true;
      premillis_rx = millis();
    }
     if(millis()-premillis_rx > DC_RX)
     {
       linked = false;
       analogWrite(L_MOTOR,MOTOR_OFF);
       analogWrite(R_MOTOR,MOTOR_OFF);
       //Serial.println("nodata");
     }
  }
  else
  {
    linked = false;
    digitalWrite(ST_LED,LOW);
    delay(60);
    digitalWrite(ST_LED,HIGH);
    delay(1000);
    analogWrite(L_MOTOR,MOTOR_OFF);
    analogWrite(R_MOTOR,MOTOR_OFF);
    digitalWrite(ST_LED,HIGH);
  }
}
