# esp01-wifiplane

Here is the modified code and hardware for esp01 running [RAVI_BUTANI](https://www.instructables.com/member/RAVI_BUTANI/)'s cheapest diy [WIFI-CONTROLLED-RC-PLANE](https://www.instructables.com/id/WIFI-CONTROLLED-RC-PLANE/).

**Highlights**

* Hardware: Works on esp01's gpio0 and gpio2, both bootstrap pins require pullup on boot, so output is inverted

* Arduino code: Ability to invert outputs and switch gpio pins using define directives

* Android code: Now also works in home networks (for testing). The [compiled binary](ProcessingAndroidApp/wifiplane.apk) is from before the ExpressLRS style link below and does not work with the current firmware, rebuild the app from `wifiplane.pde` in Processing (Android mode).

**ESP-12E and long range**

* Build: leave `ESP01_BUILD` commented out. Motors go on gpio5 (D1) and gpio4 (D2), status LED on gpio2.

* `LONG_RANGE` (on by default) locks the radio to 802.11b, which has the most TX power and the best receive sensitivity, sets max TX power (`TX_POWER_DBM`) and disables modem sleep. If the hotspot won't accept 802.11b, the plane switches between 802.11b and 802.11g every 15 s until it connects.

* The phone hotspot is usually the weakest end of the link. For more range, put both the phone and the plane on a 2.4 GHz access point with a better antenna (b/g/n mixed mode, client isolation off, SSID and password matching the sketch).

* Max TX power draws 170 mA or more in peaks. Use a low dropout regulator rated for 500 mA or more with a 470 µF+ capacitor next to the module, or the ESP may reset when the motors spin up.

**ExpressLRS style link**

The app and the plane talk the way an ELRS transmitter and receiver do, over UDP on the same WiFi. Flash the firmware and install the rebuilt app together, the old packets are not accepted.

* The app sends RC packets at a fixed 50 Hz (`PACKET_RATE_HZ`) from its own thread: sequence number, armed flag and two 1000-2000 us channels (left and right motor). It stops sending while the app is in the background, so the plane failsafes.

* The plane applies only packets newer than the last one, counts link quality (LQ) from sequence gaps over the last 100 packets and cuts the motors after 900 ms without packets (`DC_RX`).

* Every 10 packets (`TLM_RATIO`) the plane sends back link stats: RSSI, LQ and battery. The app shows LQ above RSSI and vibrates below 50% LQ (`LQ_WARN`) or on low battery while activated.

* `BIND_PHRASE` seeds the CRC of every packet, like the ELRS UID. Set the same phrase in the sketch and the app, packets from a phone or plane with another phrase are ignored.

* Unlike ELRS it is still WiFi: one fixed channel (no frequency hopping), the plane must stay associated to the access point, and WiFi retries lost unicast packets itself (stale ones are dropped by the plane).
