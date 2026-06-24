# PadKey

PadKey is a voice, contact-sensing, dictation, and Mac-control system built around the Seeed Studio XIAO ESP32-S3. This repository contains the production firmware, browser Studio, and a unified native macOS application.

## PadKey for macOS

The standalone native app lives in [`macos/PadKey/`](./macos/PadKey/). It combines the complete PadKey Studio workflow with local dictation, cross-app text insertion, Notes and browser actions, confirmed FaceTime preparation, Scratchpad, personal vocabulary, voice setup, and pipeline diagnostics.

It is a separate application with bundle identifier `com.stellarlyyd.padkey`. Installing it does not replace the standalone OwoFlow app or the browser-only PadKey Studio.

Build, sign, install, and launch it with:

```bash
git clone https://github.com/StellarLyyd/PadKey.git
cd PadKey/macos/PadKey
./script/build_and_run.sh
```

The script builds the sibling Studio frontend, embeds it in the native app, installs `~/Applications/PadKey.app`, and launches it. The native bridge supplies USB serial and BLE access that WebKit does not expose; Wi-Fi continues through the Studio WebSocket transport.

## PadKey Studio

The front end lives in [`padkey-studio/`](./padkey-studio/). It provides a human-friendly workflow for:

- connecting a PadKey over USB, recordable BLE, or Wi-Fi;
- recording independent INMP441, MAX4466, and piezo waveform channels over USB, Wi-Fi, or synchronized three-channel BLE;
- recording the MacBook microphone as a baseline comparison;
- viewing the Charger BFF battery estimate and power state;
- viewing, listening to, comparing, and trimming waveforms;
- improving recordings with plain-language sound controls;
- exporting WAV or MP3 audio;
- creating editable transcripts with browser-based Whisper;
- collecting labeled signal batches and training a local controlled-vocabulary model under Advanced.

## Launch the front end

Install [Node.js 20 or newer](https://nodejs.org/), then run:

```bash
git clone https://github.com/StellarLyyd/PadKey.git
cd PadKey/padkey-studio
npm install
npm run dev
```

Open [http://127.0.0.1:5174](http://127.0.0.1:5174) in Chrome or Microsoft Edge. Those browsers are required for the USB connection through Web Serial.

For a production build:

```bash
npm run build
npm run preview
```

Open [http://127.0.0.1:4174](http://127.0.0.1:4174).

See the [full PadKey Studio guide](./padkey-studio/README.md) for firmware setup, USB/BLE/Wi-Fi connection steps, MacBook baseline capture, the mock device, troubleshooting, and a complete feature overview.

## Production breadboard firmware

The current three-channel sketch is:

[`padkey-studio/firmware/PadKey_Breadboard_Production/PadKey_Breadboard_Production.ino`](./padkey-studio/firmware/PadKey_Breadboard_Production/PadKey_Breadboard_Production.ino)

It streams 16 kHz signed waveform data for the INMP441, MAX4466 on A5, and a protected piezo input on A8; monitors the Charger BFF on A0; and advertises over BLE as `PadKey-S3`. BLE carries synchronized 8 kHz IMA ADPCM for all three sensors in MTU-safe packets, which Studio expands to signed 16-bit PCM. Follow the adjacent [firmware README](./padkey-studio/firmware/PadKey_Breadboard_Production/README.md) before wiring or uploading it.

The standalone `.ino`, Python, and Wi-Fi files at the repository root are earlier experiments retained for reference.

## Important safety note

Do not connect an unprotected piezo directly to the ESP32-S3 analog input. Piezo elements can produce damaging voltage spikes. Use the protection guidance in the production firmware documentation and verify the signal stays inside the board's electrical limits.

Connect only the Charger BFF's divided `A2/BATMON` output to XIAO `A0`; that wire measures the battery but does not power the XIAO. Never connect raw battery voltage directly to an ADC pin or place two charger circuits on the same cell.
