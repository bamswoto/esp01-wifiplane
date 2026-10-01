# esp01-wifiplane

Here is the modified code for an ESP-12E running [RAVI_BUTANI](https://www.instructables.com/member/RAVI_BUTANI/)'s cheapest diy [WIFI-CONTROLLED-RC-PLANE](https://www.instructables.com/id/WIFI-CONTROLLED-RC-PLANE/), tuned for maximum range.

**Hardware**

* ESP-12E (or ESP-12F, NodeMCU, Wemos D1 mini) wired as in the [original schematic](Hardware/original-electronics.png), status LED on gpio2.

* Motors as in the original schematic: right motor on gpio4 (T2, `MOTOR_KANAN`), left motor on gpio5 (T1, `MOTOR_KIRI`). Tilting the phone left speeds up the right motor, so the plane turns left. The left trim buttons add to the right motor (trim left), the right ones to the left motor.

* Battery voltage on A0 through a 33k / 8.2k divider.

**Before flashing**

* In the sketch, fill in `ssid_sta` / `pass_sta` (home WiFi for OTA, or the phone hotspot), `pass_ap` (8+ characters) and `OTA_PASSWORD`. Don't commit real passwords.

* Set the same `BIND_ID` in the sketch and the app, so another phone or plane running this code can't control yours.

* Rebuild the app from `ProcessingAndroidApp/wifiplane/wifiplane.pde` in Processing (Android mode). The bundled `wifiplane.apk` is an old version and doesn't work with this firmware. The permissions the app needs are in `AndroidManifest.xml`, and any that are missing are shown on screen.

**WiFi modes**

* At power up the plane tries `ssid_sta` (home WiFi or phone hotspot) for up to 20 s (`STA_TUNGGU_MS`, 3 beeps when connected), so a slow router doesn't push it into access point mode.

* Otherwise it becomes an access point `wifiplane` on the least busy of channels 1, 6 and 11 (2 beeps). Connect the phone to it. Away from the home WiFi this takes about 20 s after power up.

* OTA updates (Arduino IDE port `wifiplane-ota`, asks for `OTA_PASSWORD`) go through STA mode (home WiFi or phone hotspot). Access point mode is the backup when STA can't connect: connect the PC to `wifiplane`. In both modes OTA and mDNS only run while the remote app isn't open: they start after 10 s without control packets (`OTA_TUNDA_MS`) and stop as soon as the app sends again, so they never run during a flight. After power up without the app, wait about 10 s before uploading.

* The mode is picked once at power up and kept until the plane is switched off.

**Safe mode**

* If the firmware crashes 3 times in a row (exception or watchdog reset, `CRASH_MAKS`), for example after a bad update, the plane starts in safe mode: the motors are never driven, no beeps, the LED double blinks every second, and only WiFi (STA, else access point) and OTA run, with OTA on right away. Upload a fixed firmware over OTA, or unplug and replug the battery to try the normal start again.

* After 30 s of normal running (`STABIL_MS`) the crash count goes back to 0. The count lives in RTC memory, so a power cycle also clears it.

* Safe mode only helps if the new firmware still contains it and crashes after it starts. Keep the safe mode code in every version you upload.

**Rollback**

* A failed OTA upload (connection lost, wrong password, MD5 mismatch, battery pulled during the upload) never touches the running firmware: the new image goes to free flash first and is only copied in after its MD5 checks out. Don't cut the power for about 10 s after an upload finishes, while the bootloader copies it.

* For an upload that succeeds but crashes, the plane keeps a copy of the last good firmware. Select a Flash Size with a file system in the Arduino IDE, for example "4MB (FS:1MB OTA:~1019KB)"; without one, rollback is off and a crash loop only leads to safe mode.

* A firmware that has run 2 minutes without crashing (`VERSI_BAIK_MS`) is copied to the file system, once per version, only while the remote app is closed. On the 3rd crash in a row the plane installs that copy (checked by MD5) and restarts with it. With no copy, or a copy of the crashing version itself, it goes to safe mode.

**Range settings (firmware)**

* 802.11b only, modem sleep off, full RF calibration at every power up, TX power at the top of the PHY table (19.5 dBm).

* The plane's own transmissions (telemetry, OTA) start at 1 Mbps, the most sensitive rate. The rate of the control packets is picked by the phone.

* `EKSP_AP_RATE_1_2M` (off by default, experimental) makes the access point advertise only 1 and 2 Mbps, so the phone also sends at those rates. Test it on the ground.

**Link**

* The app sends 5 byte control packets at 250 Hz: `[BIND_ID, seq lo, seq hi, PWM right, PWM left]`. Packets whose first byte isn't the plane's `BIND_ID` are dropped. There is no extra checksum: WiFi already checks every frame with a hardware CRC-32.

* The app picks the mode by itself and shows it on the right. BC (broadcast) when the phone is the hotspot: no WiFi retries, no queue while the plane is the only device on the hotspot. UC (unicast, acked and retried) when the phone is a WiFi client, of the plane's access point or of the home WiFi: there broadcast gains nothing and can be delayed or sent twice.

* The plane uses only the newest packet, drops stale and duplicate ones by sequence number and works out link quality (LQ) from the gaps. It cuts the motors after 900 ms without packets.

* Once a second the plane sends `[BIND_ID, RSSI, VBAT*10, LQ %]`, broadcast until a phone controls it and unicast after that, so the app finds the plane on its own. In access point mode the plane can't measure RSSI, so the app shows the RSSI the phone measures ("HP").

**Controls and safety**

* Gas: slide on the middle bar. Lifting the finger sets gas to 0, so a crash cuts the motors. At gas 0 both motors are off, whatever the tilt or trim.

* HOLD (bottom right, orange when on, only while ACTIVATED): keeps the gas when the finger lifts, so you can set the trims or switch BG/EX in flight. Tap it again to turn it off, which also sets gas to 0.

* LOCKED / ACTIVATED (bottom bar) also turns HOLD off and sets gas to 0.

* The phone vibrates on low battery (below 3.0 V, at most 2 s before the plane cuts the motors), and while ACTIVATED when the link is lost or LQ is below 50%.

* The plane cuts the motors when the battery stays below 3.0 V (the absolute minimum for a 1S LiPo under load) for 2 s, so short sags at full throttle don't cut it. Motors come back once the voltage recovers and the gas is back to 0.

* When the app is paused (call, screen lock, other app) it locks the controls and sends gas 0 for 1 s, then stops sending and releases its locks.

**Phone**

* Hotspot: 2.4 GHz band, "turn off hotspot automatically" off, and no other devices on it.

* Plane access point: turn mobile data off, or answer "stay connected" when Android says the network has no internet. The app also binds its socket to that network.

* Battery saver off, and keep your hand off the phone edges where the WiFi antenna usually is. The app keeps the screen on.
