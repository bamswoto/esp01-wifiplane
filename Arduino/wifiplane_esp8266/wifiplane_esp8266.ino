//**************************************************
// WiFi Controlled Tiny Airplane
// ESP8266 Firmware ino file
// By Ravi Butani
// Rajkot INDIA
// Instructables page: https://www.instructables.com/id/WIFI-CONTROLLED-RC-PLANE/
//***************************************************
#include <ESP8266WiFi.h>
#include <WiFiUdp.h>

#define P_ID 1
#define DC_RSSI 500   // Time in mS for send RSSI, app drops back to broadcast after ~3s without it
#define DC_RX   900   // Time in mS for tx inactivity 200 old problem of motor stopping flickring

//#define SERIAL_DEBUG  //Enable serial debugging
//#define ESP01_BUILD  //Enable ESP01, leave disabled for ESP-12E / ESP-12F / NodeMCU / Wemos D1 mini

#define LONG_RANGE          //Max range: 802.11b, max TX power, no modem sleep
#define TX_POWER_DBM   20.5 //0 - 20.5 dBm, lower it if the ESP resets when motors spin up
#define PHY_SWITCH_MS 15000 //Alternate 802.11b/g while connecting, for hotspots that refuse 802.11b

#ifdef ESP01_BUILD //ESP01 only have gpio0 (bootstrap), gpio2 (bootstrap), gpio1 (TX & LED), gpio3 (RX)
  #define REVERSE_ON_OFF //bootstrap pins need to be HIGH on boot
  #define ST_LED  1
  #define L_MOTOR 0
  #define R_MOTOR 2
#else //ESP-12E: onboard LED on gpio2, motors on gpio5 (D1) and gpio4 (D2)
  #define ST_LED  2
  #define L_MOTOR 5
  #define R_MOTOR 4
#endif

#ifdef REVERSE_ON_OFF
  #define MOTOR_OFF 255
#else
  #define MOTOR_OFF 0
#endif //REVERSE_ON_OFF

ADC_MODE(ADC_VCC);
unsigned int l_speed = 0;
unsigned int r_speed = 0;

unsigned long premillis_rssi = 0;
unsigned long premillis_rx   = 0;

int status = WL_IDLE_STATUS;
char ssid[] = "wifiplane";   //  your network SSID (name)
char pass[] = "wifiplane1234";    // your network password (use for WPA, or use as key for WEP)
int keyIndex = 0;            // your network key Index number (needed only for WEP)
IPAddress remotIp;
unsigned int localPort = 6000;      // local port to listen on
unsigned int remotPort = 2390;      // local port to talk on
char  packetBuffer[10]; //buffer to hold incoming packet
char  replyBuffer[]={P_ID,0x01,0x01,0x00}; // a string to send back
WiFiUDP Udp;

// the setup function runs once when you press reset or power the board
void setup() {
  WiFi.persistent(false);
  WiFi.mode(WIFI_STA);
#ifdef LONG_RANGE
  WiFi.setPhyMode(WIFI_PHY_MODE_11B);  // 802.11b: highest TX power and best RX sensitivity (down to 1 Mbps)
  WiFi.setOutputPower(TX_POWER_DBM);
  WiFi.setSleepMode(WIFI_NONE_SLEEP);  // modem sleep delays and drops control packets
#endif //LONG_RANGE
  WiFi.setAutoReconnect(true);
  analogWriteFreq(5000);
  analogWriteRange(255);
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
  unsigned long premillis_phy = millis();
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
  remotIp=WiFi.localIP();
  remotIp[3] = 255;
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
      int len = Udp.read(packetBuffer, 10);
      if (len > 2) 
      {
        if(packetBuffer[0] == P_ID)
        {
          //Speed value sent from app range 1-127
        #ifdef REVERSE_ON_OFF
          l_speed = 257-(2*(unsigned int)packetBuffer[1]);
          r_speed = 257-(2*(unsigned int)packetBuffer[2]);
        #else
          l_speed = (unsigned int)packetBuffer[1]*2-2;
          r_speed = (unsigned int)packetBuffer[2]*2-2;
        #endif //REVERSE_ON_OFF
	      #ifdef SERIAL_DEBUG
          Serial.print(l_speed);
          Serial.print(" \t");
          Serial.println(r_speed);
	      #endif //SERIAL_DEBUG
          analogWrite(L_MOTOR,l_speed);
          analogWrite(R_MOTOR,r_speed);
          premillis_rx = millis();
          remotIp = Udp.remoteIP(); // unicast telemetry is acked and retried, broadcast is not
        }
      }
      
    }
    if(millis()-premillis_rssi > DC_RSSI)
    {
       premillis_rssi = millis();
       long rssi = abs(WiFi.RSSI());
       float vcc = (((float)ESP.getVcc()/(float)1024.0)+0.75f)*10;
       replyBuffer[1] = (unsigned char)rssi;
       replyBuffer[2] = (unsigned char)vcc;
       
       Udp.beginPacket(remotIp, remotPort);
       Udp.write(replyBuffer);
       Udp.endPacket();
     }
     if(millis()-premillis_rx > DC_RX)
     {
       analogWrite(L_MOTOR,MOTOR_OFF);
       analogWrite(R_MOTOR,MOTOR_OFF);
       //Serial.println("nodata");
     }
  }
  else
  {
    digitalWrite(ST_LED,LOW);
    delay(60);
    digitalWrite(ST_LED,HIGH);
    delay(1000);
    analogWrite(L_MOTOR,MOTOR_OFF);
    analogWrite(R_MOTOR,MOTOR_OFF);
    digitalWrite(ST_LED,HIGH);
  }
}
