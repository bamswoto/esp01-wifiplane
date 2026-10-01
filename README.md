# esp01-wifiplane

Here is the modified code and hardware for esp01 running [RAVI_BUTANI](https://www.instructables.com/member/RAVI_BUTANI/)'s cheapest diy [WIFI-CONTROLLED-RC-PLANE](https://www.instructables.com/id/WIFI-CONTROLLED-RC-PLANE/).

**Highlights**

* Hardware: Works on esp01's gpio0 and gpio2, both bootstrap pins require pullup on boot, so output is inverted

* Arduino code: Ability to invert outputs and switch gpio pins using define directives

* Android code: Now also works in home networks (for testing). A [compiled binary](ProcessingAndroidApp/wifiplane.apk) is supplied if you dont want to install processing and android sdk.

**ESP-12E and long range**

* Build: leave `ESP01_BUILD` commented out. Motors go on gpio5 (D1) and gpio4 (D2), status LED on gpio2.

* `LONG_RANGE` (on by default) locks the radio to 802.11b, which has the most TX power and the best receive sensitivity, sets max TX power (`TX_POWER_DBM`) and disables modem sleep. If the hotspot won't accept 802.11b, the plane switches between 802.11b and 802.11g every 15 s until it connects.

* The phone hotspot is usually the weakest end of the link. For more range, put both the phone and the plane on a 2.4 GHz access point with a better antenna (b/g/n mixed mode, client isolation off, SSID and password matching the sketch).

* Max TX power draws 170 mA or more in peaks. Use a low dropout regulator rated for 500 mA or more with a 470 µF+ capacitor next to the module, or the ESP may reset when the motors spin up.
