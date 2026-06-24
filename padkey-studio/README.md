# PadKey Studio

PadKey Studio is the browser workspace for recording, improving, reviewing, and exporting audio from the PadKey sensor prototype. The default Studio view is intentionally simple; engineering diagnostics, signal training, and protocol details live under **Advanced**.

## What it does

- Connects to a XIAO ESP32-S3 over USB, low-power BLE, or a Wi-Fi WebSocket.
- Records separate waveform channels from the INMP441 digital microphone, MAX4466 analog microphone, and protected piezo contact sensor.
- Can record the MacBook's built-in microphone as a baseline channel for comparison.
- Displays the Charger BFF battery estimate and whether the board appears battery- or externally powered.
- Shows live and recorded waveforms with independent channel selection and visibility controls.
- Imports WAV or MP3 recordings up to 100 MB or ten minutes.
- Applies non-destructive **Reduce noise**, **Clarity**, **Voice strength**, and **Loudness** adjustments with Natural, Clear, and Strong presets.
- Supports listening, Original/Enhanced comparison, start/end trimming, and local project autosave.
- Exports enhanced audio as 16-bit WAV or 128 kbps MP3.
- Uses Whisper Tiny English in the browser to turn a recording into editable text. The model requires one initial internet download.
- Keeps signal plots, packet diagnostics, labeled batch capture, model training, Speech Lab, and the PadKey dictionary under **Advanced**.

Audio editing and project storage stay in the browser. PadKey Studio does not require an audio-upload backend.

## Launch locally

### Requirements

- Node.js 20 or newer
- npm
- Chrome or Microsoft Edge for USB access through Web Serial

Safari can open imported files and use the Mac microphone, but it does not support the USB connection used by this app.

### Start the development app

```bash
cd padkey-studio
npm install
npm run dev
```

Open [http://127.0.0.1:5174](http://127.0.0.1:5174).

### Build the production version

```bash
npm run build
npm run preview
```

Open [http://127.0.0.1:4174](http://127.0.0.1:4174).

## Record from PadKey over USB

1. Flash [`firmware/PadKey_Breadboard_Production/PadKey_Breadboard_Production.ino`](./firmware/PadKey_Breadboard_Production/PadKey_Breadboard_Production.ino) with Arduino IDE.
2. Use the Arduino settings listed in the [firmware README](./firmware/PadKey_Breadboard_Production/README.md), including **USB CDC On Boot: Enabled**.
3. Close Arduino Serial Monitor and Serial Plotter; only one app can own the serial port.
4. Launch PadKey Studio in Chrome or Edge.
5. Choose **Connect PadKey**, select **USB cable**, and pick the XIAO ESP32-S3 port.
6. Confirm the status reads `PadKey connected · Signal good`, choose the inputs you want, then press **Record**.

The production firmware streams actual 16 kHz waveform samples at 921600 baud. Older telemetry-only sketches can move the signal meters but cannot create playable recordings; Studio labels that state `Recording unavailable`.

## Record the MacBook baseline

Enable **MacBook baseline** under **Record these inputs** and allow microphone access when the browser asks. The browser captures this channel locally and never relabels it as PadKey sensor data. It is useful for comparing conventional airborne speech with the INMP441, MAX4466, and piezo channels.

## Connect over Wi-Fi

Wi-Fi is optional. Enable it and set the network details in the production firmware, then connect Studio to the WebSocket address shown by the board, such as:

```text
ws://padkey.local:81
```

USB and Wi-Fi use the same channel-aware stream contract documented in [PADKEY_STREAM_PROTOCOL.md](./PADKEY_STREAM_PROTOCOL.md).

## Connect over BLE

BLE is enabled by default in the production firmware and advertises as `PadKey-S3`. Install the XIAO's external antenna, choose **Connect PadKey → BLE**, and select `PadKey-S3` in Chrome or Edge.

BLE carries sensor telemetry, battery level, and low-power waveform snapshots. Those snapshots are deliberately not treated as continuous audio, so Studio will not export them as a misleading WAV or MP3. Choose USB or Wi-Fi for playable PadKey recordings.

## Test without hardware

Run the included mock PadKey in a second terminal:

```bash
cd padkey-studio
npm run mock-device
```

In Studio, choose **Connect PadKey → Wi-Fi** and connect to `ws://127.0.0.1:8787`. The mock sends telemetry plus INMP441, MAX4466, and piezo waveform packets.

## Studio workflow

1. **Record from PadKey** or **Import audio**.
2. Choose a channel and listen to its waveform.
3. Pick Natural, Clear, or Strong and fine-tune the four plain-language sound controls.
4. Switch between **Original** and **Enhanced** while listening.
5. Drag the trim handles to keep the useful section.
6. Choose **Make text** for a transcript.
7. Choose **Save audio** and export WAV or MP3.

Projects are autosaved in IndexedDB in the current browser profile. They are not automatically deleted. Export important work before clearing browser data.

## Advanced workflows

- **Signals:** live values, waveforms, sensor toggles, packet status, and CSV/WAV/MP3 session capture.
- **Signal trainer:** collect labeled batches, train a local controlled-vocabulary classifier, and export its dataset/model.
- **Speech lab:** inspect detected speech segments, processing, transcription, and training-data export.
- **Learn:** a visual system guide and searchable plain-language dictionary.

The signal trainer recognizes only phrases represented in its labeled training batches. Open-ended dictation requires raw microphone waveform data and the Whisper path.

## Troubleshooting

- **Connected but recording unavailable:** the board is sending scalar telemetry but no channel waveform packets. Flash the included production firmware and reconnect at 921600 baud.
- **No USB device picker:** use Chrome or Edge on desktop and serve the app from localhost or HTTPS.
- **Port already in use:** close Arduino Serial Monitor, Serial Plotter, and any other serial app, then reconnect.
- **No MacBook baseline:** enable the channel, grant microphone permission, and check the browser's site permissions.
- **Make text cannot prepare offline:** connect once so the Whisper model can download; playback and export remain available offline.
- **Choppy recording or dropped packets:** use a data-capable USB cable, avoid a congested hub, or use the firmware's binary Wi-Fi audio mode.

## Hardware and protocol notes

- Target board: Seeed Studio XIAO ESP32-S3
- PadKey waveform format: mono signed 16-bit PCM at 16 kHz
- Sensors: INMP441 over I2S, MAX4466 on A5, protected piezo input on A8
- BLE is the low-power monitoring path; USB and Wi-Fi are the continuous recording paths.
- Do not connect an unprotected piezo directly to the ESP32-S3 analog input. Follow the protection guidance in the firmware README.

See [PADKEY_STREAM_PROTOCOL.md](./PADKEY_STREAM_PROTOCOL.md) for packet formats and [FRONTEND_SIX_CHANNEL_CAPTURE_CODE.md](./FRONTEND_SIX_CHANNEL_CAPTURE_CODE.md) for additional capture notes.
