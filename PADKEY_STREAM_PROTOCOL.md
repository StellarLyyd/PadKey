# PadKey Stream Protocol

The front end accepts line-oriented telemetry and three separately identified waveform channels. USB, BLE, and Wi-Fi use the same sensor names.

PadKey Studio may also add a fourth browser-local channel named `macbook`.
That reference is captured directly from the Mac's selected built-in microphone;
it never travels through, or gets relabeled as, a PadKey firmware packet.

## 1. Current telemetry line

The existing sketch already emits the accepted format:

```text
INMP441:1820,MAX4466:860,NoiseFloor:1000,Gate:1600,PIEZO:114
```

Terminate each USB line with `\n`. A Wi-Fi WebSocket may send one line per message or several newline-delimited lines in one message.

The front end computes detection as:

```text
INMP441 > Gate OR PIEZO > 100
```

JSON telemetry is also accepted:

```json
{
  "type": "telemetry",
  "inmp441": 1820,
  "max4466": 860,
  "noiseFloor": 1000,
  "gate": 1600,
  "piezo": 114,
  "thresholdPiezo": 100,
  "soundDetected": true,
  "batteryVoltage": 3.92,
  "batteryPercent": 69,
  "powerMode": "battery"
}
```

## 2. Raw PCM as JSON

This format works over USB at a high baud rate and over a WebSocket:

```json
{
  "type": "audio",
  "format": "pcm_s16le",
  "channel": "inmp441",
  "sampleRate": 16000,
  "channels": 1,
  "sequence": 42,
  "pcm": "BASE64_SIGNED_16_BIT_LITTLE_ENDIAN_SAMPLES"
}
```

`channel` is `inmp441`, `max4466`, or `piezo`. Recommended packet size is 256 to 1024 samples. Keep all channels at one sample rate.

Do not send raw PCM at `115200` baud. Sixteen-kilohertz mono 16-bit audio is 32,000 bytes/second before framing and Base64 overhead. Use `921600`, native USB CDC, or Wi-Fi.

The frontend checks monotonically increasing `sequence` values and reports dropped PCM packets.

## 3. Efficient binary WebSocket audio

For Wi-Fi, the front end also accepts this binary packet:

| Offset | Size | Value |
| --- | ---: | --- |
| 0 | 4 | ASCII `PKAU` |
| 4 | 1 | protocol version `3` |
| 5 | 1 | channel count `1` |
| 6 | 4 | sample rate, unsigned 32-bit little-endian |
| 10 | 4 | packet sequence, unsigned 32-bit little-endian |
| 14 | 1 | source: `0` INMP441, `1` MAX4466, `2` piezo |
| 15 | remaining | signed 16-bit PCM little-endian |

Binary WebSocket packets avoid Base64 expansion and are the preferred Wi-Fi audio path.

## 4. BLE recording packets

BLE advertises as `PadKey-S3` with custom service `7f23c000-2c44-4e7d-9f53-000000000001`.

| Characteristic | UUID | Purpose |
| --- | --- | --- |
| Telemetry | `7f23c001-2c44-4e7d-9f53-000000000001` | Compact all-sensor JSON at about 8 Hz |
| Recordable audio | `7f23c002-2c44-4e7d-9f53-000000000001` | Synchronized three-channel IMA ADPCM |
| Control | `7f23c003-2c44-4e7d-9f53-000000000001` | Reserved device commands |

BLE audio uses protocol version `6`, three channels, an 8 kHz sample rate, and consecutive packet sequence numbers. Byte 14 is the sample count per channel (`104`). The payload contains fixed-order INMP441, MAX4466, and piezo blocks. Each block is a signed 16-bit initial predictor, an 8-bit IMA step index, and 52 packed ADPCM bytes. The complete packet is 180 bytes, below the common 182-byte ATT value negotiated by macOS at MTU 185. Studio expands every block to signed 16-bit PCM for waveform display, processing, and export. Versions 4 and 5 remain accepted for older firmware.

The control characteristic accepts UTF-8 JSON:

```json
{"type":"set_source","sourceId":1}
{"type":"set_streaming","enabled":true}
```

`set_source` is retained for compatibility and UI focus only. Version 6 always streams all three sensors.

The firmware also publishes the standard Battery Service `0x180F` and Battery Level characteristic `0x2A19`.

## 5. Converting the INMP441 samples

The current peak loop discards sign with `abs(...)`. Raw audio must preserve signed samples. Use the same signed shift you use for peak inspection, clamp it to the 16-bit range, and stream the result before applying `abs`:

```cpp
int32_t shifted = samples[i] >> 14;
int16_t pcm = (int16_t)constrain(shifted, -32768, 32767);
```

The exact shift should be calibrated against the INMP441 bit alignment in your working hardware build. If recordings clip or are extremely quiet, adjust the shift before adding software gain.

## 6. Wi-Fi server responsibility

The dashboard is a WebSocket client. The ESP32-S3 firmware must:

1. join the chosen Wi-Fi network or start an access point;
2. host a WebSocket endpoint, for example `ws://padkey.local:81`;
3. publish telemetry lines at a useful UI rate, typically 20-50 Hz;
4. publish every raw PCM sample in ordered, channel-identified audio packets;
5. keep I2S capture non-blocking so network transmission does not starve the DMA reader.

## 7. Breadboard PCM firmware

The wired reference sketch is available at:

```text
firmware/PadKey_Breadboard_PCM_USB/PadKey_Breadboard_PCM_USB.ino
```

The production sketch at `firmware/PadKey_Breadboard_Production/PadKey_Breadboard_Production.ino` captures the INMP441 over I2S plus the MAX4466 on A5, protected piezo input on A8, and Charger BFF BATMON on A0 through ADC1 continuous DMA. It sends independent 16 kHz signed PCM channels over USB or Wi-Fi and synchronized 8 kHz ADPCM for all three sensors over BLE.
