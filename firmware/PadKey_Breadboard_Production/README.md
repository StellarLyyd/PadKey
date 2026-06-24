# PadKey battery + BLE production firmware

Target: Seeed Studio XIAO ESP32-S3 with three independent sensor channels, battery monitoring, USB, BLE, and optional Wi-Fi.

## What the sketch provides

- INMP441 digital microphone at 16 kHz over I2S
- MAX4466 analog microphone on A5
- protected piezo contact sensor on A8
- Adafruit Charger BFF A2/BATMON sensing on XIAO A0
- USB full-waveform streaming at 921600 baud
- BLE all-sensor telemetry, battery level, and synchronized three-channel 8 kHz recording as `PadKey-S3`
- optional Wi-Fi WebSocket full-waveform streaming

BLE streams all three sensors without saturating the wireless link. Each 180-byte notification contains synchronized 8 kHz IMA ADPCM for INMP441, MAX4466, and piezo and remains below the common macOS BLE payload limit. Studio expands each channel to signed 16-bit PCM before playback or export. USB and Wi-Fi retain higher-fidelity 16 kHz PCM.

## Arduino IDE settings

- Board: `XIAO_ESP32S3`
- ESP32 board package: 3.3.10 or newer
- USB CDC On Boot: Enabled
- PadKey Studio USB speed: 921600

BLE support is included with the ESP32 Arduino core. Wi-Fi mode additionally requires `ArduinoWebsockets` by Gil Maimon.

The sketch has been compile-checked against ESP32 Arduino core 3.3.10 with BLE enabled.

## Sensor wiring

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
| Charger BFF | A2/BATMON | A0 |

Start the MAX4466 gain potentiometer low. Increase it only until normal speech is clear without flattening the waveform at its limits.

## Battery and Charger BFF wiring

The supplied cell is a protected 3.7 V, 500 mAh lithium-polymer battery with a 4.2 V charging limit. The Adafruit Charger BFF uses an MCP73831 charger at 200 mA, which is below the battery datasheet's 500 mA maximum quick-charge current.

The cell datasheet limits continuous discharge to 500 mA. Measure the completed breadboard's real current, especially during Wi-Fi transmission, rather than assuming the battery is adequate from capacity alone.

- Plug the battery into the Charger BFF JST connector with verified polarity.
- Connect the Charger BFF power output to the XIAO 5V/VBUS and GND rails as intended by the BFF design.
- Tie the Charger BFF and XIAO grounds together.
- Connect Charger BFF `A2/BATMON` to XIAO `A0` for voltage sensing.
- Do not connect the raw battery positive terminal to A0. The valid A0 connection is the BFF's already-divided BATMON signal.
- Do not connect the same battery to both the Charger BFF and the XIAO battery pads. That would place two charging paths on one cell.

The BFF divides the monitored rail by 2, so the firmware doubles the A0 voltage estimate. Battery percentage is approximate; calibrate the displayed voltage against a multimeter before relying on it.

### What the Charger BFF LED means

- The yellow charge LED turns on only while USB power is present and the battery is actively charging.
- The LED normally turns off when USB is removed; that does not mean battery power is off.
- The BFF slide switch controls battery output only when USB is absent. Put it in **ON** for wireless use.

If BLE disconnects immediately when USB is removed, the XIAO lost power. Check the BFF switch, JST polarity/seating, shared ground, and the BFF-to-XIAO 5V power connection. With USB removed and the BFF switched on, verify the XIAO power rail with a multimeter before debugging software. A2/BATMON to A0 is only a sensing wire and cannot power the XIAO.

The production firmware blinks the XIAO user LED three times after a successful boot. After that, the user LED resumes its sound-detection role. This LED is separate from the Charger BFF's charge LED.

## Piezo protection

Do not connect an unprotected piezo directly to A8. Piezo elements can generate damaging voltage spikes. Use a qualified protection network, such as a 100 kOhm series resistor, a high-impedance mid-supply bias, and Schottky clamps to 0 V and 3.3 V. Verify the protected node remains inside the ESP32-S3 input limits with an oscilloscope before hard impacts.

## BLE

BLE is enabled by default:

```cpp
#define PADKEY_ENABLE_BLE 1
```

Install the XIAO's external Wi-Fi/Bluetooth antenna before testing. Upload the sketch, power the breadboard, then choose **BLE → Connect BLE → PadKey-S3** in PadKey Studio.

The custom service uses:

- service: `7f23c000-2c44-4e7d-9f53-000000000001`
- telemetry: `7f23c001-2c44-4e7d-9f53-000000000001`
- recordable audio: `7f23c002-2c44-4e7d-9f53-000000000001`
- control: `7f23c003-2c44-4e7d-9f53-000000000001`
- standard Battery Service: `0x180F`

## Wi-Fi

Wi-Fi is disabled by default. To enable it:

1. Install `ArduinoWebsockets` by Gil Maimon.
2. Set `PADKEY_ENABLE_WIFI` to `1`.
3. Replace `YOUR_WIFI_NAME` and `YOUR_WIFI_PASSWORD` locally.
4. Upload the sketch and connect Studio to `ws://padkey.local:81` or the IP address printed over USB.

Do not commit real Wi-Fi credentials to GitHub.

For best battery life, use BLE's compressed three-channel stream. Use Wi-Fi when you need all three waveforms at the full 16 kHz sample rate.
