# esp01-wifiplane

Here is the modified code for an ESP-12E running [RAVI_BUTANI](https://www.instructables.com/member/RAVI_BUTANI/)'s cheapest diy [WIFI-CONTROLLED-RC-PLANE](https://www.instructables.com/id/WIFI-CONTROLLED-RC-PLANE/), tuned for maximum range.

**Hardware**

* ESP-12E (or ESP-12F, NodeMCU, Wemos D1 mini) wired as in the [original schematic](Hardware/original-electronics.png), status LED on gpio2.

* Motors: the sketch drives the left motor on gpio4 and the right one on gpio5. The original schematic has them the other way round, so if the plane turns against the phone tilt, swap `L_MOTOR` and `R_MOTOR`.

* Battery voltage on A0 through a 33k / 8.2k divider.

**Before flashing**

* In the sketch, fill in `ssid_sta` / `pass_sta` (phone hotspot), `pass_ap` (8+ characters) and `OTA_PASSWORD`. Don't commit real passwords.

* Set the same `BIND_ID` in the sketch and the app, so another phone or plane running this code can't control yours.

* Rebuild the app from `ProcessingAndroidApp/wifiplane/wifiplane.pde` in Processing (Android mode). The bundled `wifiplane.apk` is an old version and doesn't work with this firmware. The permissions the app needs are in `AndroidManifest.xml`, and any that are missing are shown on screen.

**WiFi modes**

* At power up the plane tries the phone hotspot for 8 s (3 beeps when connected). Turn the hotspot on before powering the plane.

* Otherwise it becomes an access point `wifiplane` on the least busy of channels 1, 6 and 11 (2 beeps). Connect the phone to it.

**Range settings (firmware)**

* 802.11b only, modem sleep off, full RF calibration at every power up, TX power at the top of the PHY table (19.5 dBm).

* The plane's own transmissions (telemetry, OTA) start at 1 Mbps, the most sensitive rate. The rate of the control packets is picked by the phone.

* `EKSP_AP_RATE_1_2M` (off by default, experimental) makes the access point advertise only 1 and 2 Mbps, so the phone also sends at those rates. Test it on the ground.

**Link**

* The app sends 6 byte control packets at 250 Hz: `[0xEA, seq lo, seq hi, PWM L, PWM R, CRC8]`, CRC8 seeded with `BIND_ID`.

* BC mode broadcasts them (no WiFi retries, no queue while the plane is the only device on the hotspot), UC mode unicasts them (acked and retried).

* The plane uses only the newest packet, drops stale and duplicate ones by sequence number and works out link quality (LQ) from the gaps. It cuts the motors after 900 ms without packets.

* Once a second the plane sends `[P_ID, RSSI, VBAT*10, LQ %, CRC8]`, broadcast until a phone controls it and unicast after that, so the app finds the plane on its own. In access point mode the plane can't measure RSSI, so the app shows the RSSI the phone measures ("HP").

**Controls and safety**

* Gas: slide on the middle bar. Lifting the finger sets gas to 0, so a crash cuts the motors. At gas 0 both motors are off, whatever the tilt or trim.

* HOLD (bottom right, orange when on, only while ACTIVATED): keeps the gas when the finger lifts, so you can set the trims or switch BG/EX and BC/UC in flight. Tap it again to turn it off, which also sets gas to 0.

* LOCKED / ACTIVATED (bottom bar) also turns HOLD off and sets gas to 0.

* The phone vibrates on low battery (below 3.5 V), and while ACTIVATED when the link is lost or LQ is below 50%.

* The plane cuts the motors when the battery stays below 3.2 V for 2 s, so short sags at full throttle don't cut it. Motors come back once the voltage recovers and the gas is back to 0.

* When the app is paused (call, screen lock, other app) it locks the controls and sends gas 0 for 1 s, then stops sending and releases its locks.

**Phone**

* Hotspot: 2.4 GHz band, "turn off hotspot automatically" off, and no other devices on it.

* Plane access point: turn mobile data off, or answer "stay connected" when Android says the network has no internet. The app also binds its socket to that network.

* Battery saver off, and keep your hand off the phone edges where the WiFi antenna usually is. The app keeps the screen on.
