# PadKey

PadKey is an experimental voice and contact-sensing system built around the Seeed Studio XIAO ESP32-S3. This repository contains the device experiments, production breadboard firmware, and the PadKey Studio browser application.

## PadKey Studio

The front end lives in [`padkey-studio/`](./padkey-studio/). It provides a human-friendly workflow for:

- connecting a PadKey over USB or Wi-Fi;
- recording independent INMP441, MAX4466, and piezo waveform channels;
- recording the MacBook microphone as a baseline comparison;
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

See the [full PadKey Studio guide](./padkey-studio/README.md) for firmware setup, USB and Wi-Fi connection steps, MacBook baseline capture, the mock device, troubleshooting, and a complete feature overview.

## Production breadboard firmware

The current three-channel sketch is:

[`padkey-studio/firmware/PadKey_Breadboard_Production/PadKey_Breadboard_Production.ino`](./padkey-studio/firmware/PadKey_Breadboard_Production/PadKey_Breadboard_Production.ino)

It streams 16 kHz signed waveform data for the INMP441, MAX4466 on A5, and a protected piezo input on A8. Follow the adjacent [firmware README](./padkey-studio/firmware/PadKey_Breadboard_Production/README.md) before wiring or uploading it.

The standalone `.ino`, Python, and Wi-Fi files at the repository root are earlier experiments retained for reference.

## Important safety note

Do not connect an unprotected piezo directly to the ESP32-S3 analog input. Piezo elements can produce damaging voltage spikes. Use the protection guidance in the production firmware documentation and verify the signal stays inside the board's electrical limits.
