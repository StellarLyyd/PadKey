# PadKey three-channel firmware

This Arduino sketch records three independent 16 kHz waveform channels:

- INMP441 digital microphone over I2S
- MAX4466 analog microphone on A5
- protected piezo contact sensor on A8

## Arduino IDE settings

- Board: `XIAO_ESP32S3`
- ESP32 board package: 3.3.10 or newer
- USB CDC On Boot: Enabled
- Upload the sketch, then close Serial Monitor and Serial Plotter before connecting PadKey Studio.
- PadKey Studio USB speed: 921600

The sketch has been compile-checked against the installed ESP32 3.3.10 board package.

## Wiring

| Sensor | Sensor pin | XIAO ESP32-S3 |
| --- | --- | --- |
| INMP441 | VDD | 3V3 |
| INMP441 | GND | GND |
| INMP441 | SCK/BCLK | D1 |
| INMP441 | SD | D2 |
| INMP441 | WS/LRCLK | D3 |
| INMP441 | L/R | GND |
| MAX4466 | VCC | 3V3 |
| MAX4466 | GND | GND |
| MAX4466 | OUT | A5 |
| Piezo input | protected signal | A8 |

Start the MAX4466 gain potentiometer low. Raise it gradually while watching its waveform; back it down if the waveform flattens at its top or bottom.

## Piezo protection

Do not connect an unprotected piezo directly to A8. A piezo can create voltage spikes beyond the ESP32-S3 input limits. Use a qualified protection network, such as a 100 kOhm series resistor, a high-impedance mid-supply bias, and Schottky clamps to 0 V and 3.3 V. Confirm the protected A8 node stays within the board's absolute limits with an oscilloscope before hard impacts.

## Wi-Fi

Wi-Fi is optional and disabled by default. To enable it:

1. Install `ArduinoWebsockets` by Gil Maimon.
2. Set `PADKEY_ENABLE_WIFI` to `1` in the sketch.
3. Add the Wi-Fi name and password.
4. Connect Studio to `ws://padkey.local:81` or the IP address printed after boot.
