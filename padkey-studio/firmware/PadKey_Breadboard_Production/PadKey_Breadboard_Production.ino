/*
  PadKey Breadboard Production Firmware
  Target: Seeed Studio XIAO ESP32-S3

  Sensors:
    - INMP441 I2S microphone
    - MAX4466 analog electret microphone on A5
    - Piezo contact sensor on A8

  Outputs:
    - USB: newline-delimited JSON, including Base64 PCM audio
    - Wi-Fi (optional): JSON telemetry + efficient binary PCM over WebSocket

  PadKey Studio settings for USB:
    - Connection: Wired USB
    - Baud rate: 921600

  IMPORTANT ELECTRICAL NOTES:
    - Power the INMP441 from 3.3 V, never 5 V.
    - Connect the INMP441 L/R pin to GND for the left channel selected below.
    - Power the MAX4466 from 3.3 V. Its OUT pin must remain between 0 V and
      3.3 V. Set the gain potentiometer low before the first recording, then
      raise it only until normal speech is clear without clipping.
    - A piezo can generate voltage spikes above the ESP32-S3 ADC rating. Use
      at least a 100 kOhm series resistor, a 1 MOhm bleed resistor, and
      Schottky clamps to 0 V / 3.3 V. For a bipolar contact waveform, bias the
      protected ADC input at about 1.65 V. Firmware cannot protect a GPIO.

  Wi-Fi is disabled by default. To enable it:
    1. Install "ArduinoWebsockets" by Gil Maimon in Arduino Library Manager.
    2. Change PADKEY_ENABLE_WIFI to 1.
    3. Enter PADKEY_WIFI_SSID and PADKEY_WIFI_PASSWORD below.
    4. Connect PadKey Studio to ws://padkey.local:81 or ws://<board-ip>:81.
*/

#include <Arduino.h>
#include <driver/i2s.h>
#include <esp_adc/adc_continuous.h>
#include <esp_err.h>
#include <mbedtls/base64.h>
#include <soc/soc_caps.h>

#ifndef PADKEY_ENABLE_WIFI
#define PADKEY_ENABLE_WIFI 0
#endif

#ifndef PADKEY_WIFI_SSID
#define PADKEY_WIFI_SSID "YOUR_WIFI_NAME"
#endif

#ifndef PADKEY_WIFI_PASSWORD
#define PADKEY_WIFI_PASSWORD "YOUR_WIFI_PASSWORD"
#endif

#if PADKEY_ENABLE_WIFI
#include <ArduinoWebsockets.h>
#include <ESPmDNS.h>
#include <WiFi.h>
#endif

namespace Config {

// INMP441 connections.
constexpr i2s_port_t kI2sPort = I2S_NUM_0;
constexpr int kI2sSckPin = D1;  // INMP441 SCK / BCLK
constexpr int kI2sWsPin = D3;   // INMP441 WS / LRCLK
constexpr int kI2sSdPin = D2;   // INMP441 SD

// Other hardware.
constexpr int kMax4466Pin = A5;
constexpr int kPiezoPin = A8;
constexpr int kLedPin = 21;
constexpr bool kLedActiveLow = true;

// Audio stream.
constexpr uint32_t kSampleRate = 16000;
constexpr size_t kSamplesPerPacket = 256;
constexpr int kI2sSampleShift = 14;
constexpr uint32_t kUsbBaudRate = 921600;
constexpr bool kStreamUsbPcm = true;
constexpr bool kStreamWifiPcm = true;

// ADC1 continuous DMA samples both analog sensors without blocking I2S. The
// frequency is the aggregate conversion rate, so two channels at 16 kHz each
// require 32,000 conversions/second.
constexpr uint32_t kAnalogSampleRatePerChannel = 16000;
constexpr uint32_t kAnalogAggregateSampleRate =
    kAnalogSampleRatePerChannel * 2;
constexpr size_t kAnalogReadBufferBytes =
    kSamplesPerPacket * 2 * SOC_ADC_DIGI_RESULT_BYTES;
constexpr size_t kAnalogPoolBytes = kAnalogReadBufferBytes * 4;

// Sensor detection.
constexpr int32_t kInitialNoiseFloor = 1000;
constexpr int32_t kMinimumMicGate = 40;
constexpr uint32_t kCalibrationPacketCount = 64;  // About one second.
constexpr uint16_t kPiezoThreshold = 100;
constexpr uint16_t kMax4466Threshold = 300;
constexpr uint8_t kTelemetryEveryPackets = 4;     // About 15.6 Hz.

// I2S DMA. Four 256-sample buffers provide about 64 ms of buffering.
constexpr int kDmaBufferCount = 4;
constexpr int kDmaBufferLength = kSamplesPerPacket;
constexpr TickType_t kI2sReadTimeout = pdMS_TO_TICKS(100);

#if PADKEY_ENABLE_WIFI
constexpr uint16_t kWebSocketPort = 81;
constexpr char kMdnsHostname[] = "padkey";
constexpr uint32_t kWifiRetryIntervalMs = 5000;
#endif

}  // namespace Config

namespace {

struct RuntimeState {
  uint32_t packetSequence = 0;
  uint32_t calibrationPackets = 0;
  int32_t noiseFloor = Config::kInitialNoiseFloor;
  int32_t micGate = (Config::kInitialNoiseFloor * 8) / 5;
  uint32_t i2sReadErrors = 0;
  uint32_t adcReadErrors = 0;
  uint32_t adcPoolOverflows = 0;
  uint32_t usbEncodeErrors = 0;
  int32_t max4466DcQ16 = 0;
  int32_t piezoDcQ16 = 0;
  bool max4466DcReady = false;
  bool piezoDcReady = false;
  int32_t max4466Peak = 0;
  int32_t piezoPeak = 0;
  bool usbWasConnected = false;
};

RuntimeState state;

int32_t i2sSamples[Config::kSamplesPerPacket];
int16_t inmp441Pcm[Config::kSamplesPerPacket];
int16_t max4466Pcm[Config::kSamplesPerPacket];
int16_t piezoPcm[Config::kSamplesPerPacket];
size_t max4466PcmCount = 0;
size_t piezoPcmCount = 0;

adc_continuous_handle_t adcHandle = nullptr;
adc_channel_t max4466AdcChannel = ADC_CHANNEL_0;
adc_channel_t piezoAdcChannel = ADC_CHANNEL_0;
uint8_t analogReadBuffer[Config::kAnalogReadBufferBytes];

// Base64 needs four output bytes for each three input bytes, rounded up.
constexpr size_t kPcmBytesPerPacket =
    Config::kSamplesPerPacket * sizeof(int16_t);
constexpr size_t kBase64Capacity =
    ((kPcmBytesPerPacket + 2) / 3) * 4 + 1;
char base64Pcm[kBase64Capacity];

char telemetryJson[480];

enum class AudioSourceId : uint8_t {
  kInmp441 = 0,
  kMax4466 = 1,
  kPiezo = 2,
};

const char* audioSourceName(AudioSourceId source) {
  switch (source) {
    case AudioSourceId::kMax4466:
      return "max4466";
    case AudioSourceId::kPiezo:
      return "piezo";
    case AudioSourceId::kInmp441:
    default:
      return "inmp441";
  }
}

#if PADKEY_ENABLE_WIFI
using namespace websockets;

WebsocketsServer webSocketServer;
WebsocketsClient webSocketClient;
bool webSocketServerStarted = false;
uint32_t lastWifiAttemptMs = 0;

// PKAU version 3 header (15 bytes) followed by signed 16-bit LE PCM.
uint8_t wifiAudioPacket[15 + kPcmBytesPerPacket];
#endif

void setLed(bool on) {
  const bool outputHigh = Config::kLedActiveLow ? !on : on;
  digitalWrite(Config::kLedPin, outputHigh ? HIGH : LOW);
}

void sendStatus(const char* level, const char* message) {
  if (!Serial) {
    return;
  }

  Serial.printf(
      "{\"type\":\"status\",\"level\":\"%s\",\"message\":\"%s\"}\n",
      level,
      message);
}

[[noreturn]] void haltWithError(const char* operation, esp_err_t error) {
  if (Serial) {
    Serial.printf(
        "{\"type\":\"status\",\"level\":\"fatal\","
        "\"message\":\"%s failed\",\"espError\":\"%s\","
        "\"code\":%ld}\n",
        operation,
        esp_err_to_name(error),
        static_cast<long>(error));
  }

  // A repeating double blink makes a boot failure visible without a console.
  while (true) {
    setLed(true);
    delay(120);
    setLed(false);
    delay(120);
    setLed(true);
    delay(120);
    setLed(false);
    delay(1000);
  }
}

int16_t convertI2sSample(int32_t rawSample) {
  // The working INMP441 build places its signed sample in a 32-bit I2S slot.
  // Keep the shift tunable: increase it if recordings clip, decrease it if
  // they are too quiet. Saturation prevents signed wrap-around distortion.
  const int32_t shifted = rawSample >> Config::kI2sSampleShift;
  if (shifted > INT16_MAX) {
    return INT16_MAX;
  }
  if (shifted < INT16_MIN) {
    return INT16_MIN;
  }
  return static_cast<int16_t>(shifted);
}

int32_t sampleMagnitude(int16_t sample) {
  // Convert before negating so INT16_MIN is handled safely.
  const int32_t expanded = sample;
  return expanded < 0 ? -expanded : expanded;
}

void updateAdaptiveGate(int32_t blockPeak) {
  if (state.calibrationPackets < Config::kCalibrationPacketCount) {
    // Fast settling during the first second after boot.
    state.noiseFloor = ((state.noiseFloor * 7) + blockPeak) / 8;
    state.calibrationPackets += 1;
  } else if (blockPeak <= state.micGate) {
    // Slow tracking during apparent silence. Speech is intentionally excluded
    // so a sustained utterance does not become the new noise floor.
    state.noiseFloor = ((state.noiseFloor * 63) + blockPeak) / 64;
  }

  state.noiseFloor = max<int32_t>(1, state.noiseFloor);
  state.micGate = max<int32_t>(
      Config::kMinimumMicGate,
      (state.noiseFloor * 8) / 5);  // 1.6 times the noise floor.
}

bool initializeI2s() {
  const i2s_config_t i2sConfig = {
      .mode = static_cast<i2s_mode_t>(I2S_MODE_MASTER | I2S_MODE_RX),
      .sample_rate = Config::kSampleRate,
      .bits_per_sample = I2S_BITS_PER_SAMPLE_32BIT,
      .channel_format = I2S_CHANNEL_FMT_ONLY_LEFT,
      .communication_format = I2S_COMM_FORMAT_STAND_I2S,
      .intr_alloc_flags = ESP_INTR_FLAG_LEVEL1,
      .dma_buf_count = Config::kDmaBufferCount,
      .dma_buf_len = Config::kDmaBufferLength,
      .use_apll = false,
      .tx_desc_auto_clear = false,
      .fixed_mclk = 0,
      .mclk_multiple = I2S_MCLK_MULTIPLE_256,
      .bits_per_chan = I2S_BITS_PER_CHAN_32BIT,
  };

  const i2s_pin_config_t pinConfig = {
      .mck_io_num = I2S_PIN_NO_CHANGE,
      .bck_io_num = Config::kI2sSckPin,
      .ws_io_num = Config::kI2sWsPin,
      .data_out_num = I2S_PIN_NO_CHANGE,
      .data_in_num = Config::kI2sSdPin,
  };

  esp_err_t result = i2s_driver_install(
      Config::kI2sPort,
      &i2sConfig,
      0,
      nullptr);
  if (result != ESP_OK) {
    haltWithError("i2s_driver_install", result);
  }

  result = i2s_set_pin(Config::kI2sPort, &pinConfig);
  if (result != ESP_OK) {
    i2s_driver_uninstall(Config::kI2sPort);
    haltWithError("i2s_set_pin", result);
  }

  result = i2s_zero_dma_buffer(Config::kI2sPort);
  if (result != ESP_OK) {
    i2s_driver_uninstall(Config::kI2sPort);
    haltWithError("i2s_zero_dma_buffer", result);
  }

  return true;
}

void initializeAnalogCapture() {
  adc_unit_t max4466Unit = ADC_UNIT_1;
  adc_unit_t piezoUnit = ADC_UNIT_1;
  esp_err_t result = adc_continuous_io_to_channel(
      Config::kMax4466Pin,
      &max4466Unit,
      &max4466AdcChannel);
  if (result != ESP_OK || max4466Unit != ADC_UNIT_1) {
    haltWithError("MAX4466 ADC pin mapping", result != ESP_OK ? result : ESP_ERR_INVALID_ARG);
  }

  result = adc_continuous_io_to_channel(
      Config::kPiezoPin,
      &piezoUnit,
      &piezoAdcChannel);
  if (result != ESP_OK || piezoUnit != ADC_UNIT_1) {
    haltWithError("piezo ADC pin mapping", result != ESP_OK ? result : ESP_ERR_INVALID_ARG);
  }

  adc_continuous_handle_cfg_t handleConfig = {};
  handleConfig.max_store_buf_size = Config::kAnalogPoolBytes;
  handleConfig.conv_frame_size = Config::kAnalogReadBufferBytes;
  handleConfig.flags.flush_pool = 1;
  result = adc_continuous_new_handle(&handleConfig, &adcHandle);
  if (result != ESP_OK) {
    haltWithError("adc_continuous_new_handle", result);
  }

  adc_digi_pattern_config_t patterns[2] = {};
  patterns[0].atten = ADC_ATTEN_DB_11;
  patterns[0].channel = max4466AdcChannel;
  patterns[0].unit = ADC_UNIT_1;
  patterns[0].bit_width = ADC_BITWIDTH_12;
  patterns[1].atten = ADC_ATTEN_DB_11;
  patterns[1].channel = piezoAdcChannel;
  patterns[1].unit = ADC_UNIT_1;
  patterns[1].bit_width = ADC_BITWIDTH_12;

  adc_continuous_config_t adcConfig = {};
  adcConfig.pattern_num = 2;
  adcConfig.adc_pattern = patterns;
  adcConfig.sample_freq_hz = Config::kAnalogAggregateSampleRate;
  adcConfig.conv_mode = ADC_CONV_SINGLE_UNIT_1;
  adcConfig.format = ADC_DIGI_OUTPUT_FORMAT_TYPE2;
  result = adc_continuous_config(adcHandle, &adcConfig);
  if (result != ESP_OK) {
    haltWithError("adc_continuous_config", result);
  }

  result = adc_continuous_start(adcHandle);
  if (result != ESP_OK) {
    haltWithError("adc_continuous_start", result);
  }
}

int16_t convertAnalogSample(
    uint16_t rawSample,
    int32_t& dcQ16,
    bool& dcReady) {
  const int32_t targetQ16 = static_cast<int32_t>(rawSample) << 16;
  if (!dcReady) {
    dcQ16 = targetQ16;
    dcReady = true;
  } else {
    // Slow DC tracking removes the module's mid-supply bias without removing
    // speech or contact vibration.
    dcQ16 += (targetQ16 - dcQ16) >> 10;
  }

  const int32_t centered = static_cast<int32_t>(rawSample) - (dcQ16 >> 16);
  const int32_t scaled = centered << 4;  // Map signed 12-bit ADC range to PCM16.
  if (scaled > INT16_MAX) return INT16_MAX;
  if (scaled < INT16_MIN) return INT16_MIN;
  return static_cast<int16_t>(scaled);
}

void collectAnalogSamples() {
  if (!adcHandle ||
      (max4466PcmCount >= Config::kSamplesPerPacket &&
       piezoPcmCount >= Config::kSamplesPerPacket)) {
    return;
  }

  uint32_t bytesRead = 0;
  const esp_err_t result = adc_continuous_read(
      adcHandle,
      analogReadBuffer,
      sizeof(analogReadBuffer),
      &bytesRead,
      4);
  if (result == ESP_ERR_TIMEOUT) return;
  if (result != ESP_OK) {
    state.adcReadErrors += 1;
    return;
  }

  for (uint32_t offset = 0;
       offset + SOC_ADC_DIGI_RESULT_BYTES <= bytesRead;
       offset += SOC_ADC_DIGI_RESULT_BYTES) {
    const auto* sample = reinterpret_cast<const adc_digi_output_data_t*>(
        &analogReadBuffer[offset]);
    const adc_channel_t channel =
        static_cast<adc_channel_t>(sample->type2.channel);
    const uint16_t raw = sample->type2.data;

    if (channel == max4466AdcChannel &&
        max4466PcmCount < Config::kSamplesPerPacket) {
      const int16_t pcm = convertAnalogSample(
          raw,
          state.max4466DcQ16,
          state.max4466DcReady);
      max4466Pcm[max4466PcmCount++] = pcm;
      state.max4466Peak = max(state.max4466Peak, sampleMagnitude(pcm));
    } else if (channel == piezoAdcChannel &&
               piezoPcmCount < Config::kSamplesPerPacket) {
      const int16_t pcm = convertAnalogSample(
          raw,
          state.piezoDcQ16,
          state.piezoDcReady);
      piezoPcm[piezoPcmCount++] = pcm;
      state.piezoPeak = max(state.piezoPeak, sampleMagnitude(pcm));
    }
  }
}

void serviceUsbConnection() {
  const bool usbConnected = static_cast<bool>(Serial);
  if (usbConnected && !state.usbWasConnected) {
    sendStatus("ready", "PadKey USB PCM stream connected");
  }
  state.usbWasConnected = usbConnected;
}

void sendUsbAudio(
    AudioSourceId source,
    const int16_t* samples,
    size_t sampleCount,
    uint32_t sequence) {
  if (!Config::kStreamUsbPcm || !Serial || sampleCount == 0) {
    return;
  }

  size_t encodedLength = 0;
  const size_t pcmByteCount = sampleCount * sizeof(int16_t);
  const int result = mbedtls_base64_encode(
      reinterpret_cast<unsigned char*>(base64Pcm),
      sizeof(base64Pcm),
      &encodedLength,
      reinterpret_cast<const unsigned char*>(samples),
      pcmByteCount);

  if (result != 0 || encodedLength >= sizeof(base64Pcm)) {
    state.usbEncodeErrors += 1;
    if ((state.usbEncodeErrors & 0x3F) == 1) {
      sendStatus("error", "PCM Base64 encoding failed");
    }
    return;
  }

  base64Pcm[encodedLength] = '\0';
  Serial.printf(
      "{\"type\":\"audio\",\"format\":\"pcm_s16le\","
      "\"channel\":\"%s\",\"sampleRate\":%lu,"
      "\"channels\":1,\"sequence\":%lu,\"pcm\":\"",
      audioSourceName(source),
      static_cast<unsigned long>(Config::kSampleRate),
      static_cast<unsigned long>(sequence));
  Serial.write(reinterpret_cast<const uint8_t*>(base64Pcm), encodedLength);
  Serial.println("\"}");
}

size_t formatTelemetry(
    int32_t micPeak,
    bool soundDetected) {
  const int written = snprintf(
      telemetryJson,
      sizeof(telemetryJson),
      "{\"type\":\"telemetry\",\"inmp441\":%ld,"
      "\"max4466\":%ld,\"piezo\":%ld,"
      "\"noiseFloor\":%ld,\"gate\":%ld,"
      "\"thresholdMax4466\":%u,\"thresholdPiezo\":%u,"
      "\"soundDetected\":%s,\"sampleRate\":%lu,"
      "\"sequence\":%lu,\"i2sReadErrors\":%lu,\"adcReadErrors\":%lu,"
      "\"usbEncodeErrors\":%lu}",
      static_cast<long>(micPeak),
      static_cast<long>(state.max4466Peak),
      static_cast<long>(state.piezoPeak),
      static_cast<long>(state.noiseFloor),
      static_cast<long>(state.micGate),
      static_cast<unsigned>(Config::kMax4466Threshold),
      static_cast<unsigned>(Config::kPiezoThreshold),
      soundDetected ? "true" : "false",
      static_cast<unsigned long>(Config::kSampleRate),
      static_cast<unsigned long>(state.packetSequence),
      static_cast<unsigned long>(state.i2sReadErrors),
      static_cast<unsigned long>(state.adcReadErrors),
      static_cast<unsigned long>(state.usbEncodeErrors));

  if (written <= 0 || static_cast<size_t>(written) >= sizeof(telemetryJson)) {
    return 0;
  }
  return static_cast<size_t>(written);
}

#if PADKEY_ENABLE_WIFI
void putUint32LittleEndian(uint8_t* destination, uint32_t value) {
  destination[0] = static_cast<uint8_t>(value & 0xFF);
  destination[1] = static_cast<uint8_t>((value >> 8) & 0xFF);
  destination[2] = static_cast<uint8_t>((value >> 16) & 0xFF);
  destination[3] = static_cast<uint8_t>((value >> 24) & 0xFF);
}

void beginWifiConnection() {
  lastWifiAttemptMs = millis();
  WiFi.begin(PADKEY_WIFI_SSID, PADKEY_WIFI_PASSWORD);
}

void initializeWifi() {
  WiFi.mode(WIFI_STA);
  WiFi.setSleep(false);
  WiFi.setAutoReconnect(true);
  WiFi.setHostname(Config::kMdnsHostname);
  beginWifiConnection();
  sendStatus("info", "Wi-Fi connection started");
}

void configureWebSocketClient(WebsocketsClient& client) {
  client.onEvent([](
                     WebsocketsClient&,
                     WebsocketsEvent event,
                     String) {
    if (event == WebsocketsEvent::ConnectionOpened) {
      sendStatus("info", "PadKey WebSocket client connected");
    } else if (event == WebsocketsEvent::ConnectionClosed) {
      sendStatus("info", "PadKey WebSocket client disconnected");
    }
  });

  // The frontend does not need to send commands yet, but polling incoming
  // frames is required to service ping, pong, and close control messages.
  client.onMessage([](WebsocketsClient&, WebsocketsMessage) {});
}

void serviceWifi() {
  if (WiFi.status() != WL_CONNECTED) {
    if (millis() - lastWifiAttemptMs >= Config::kWifiRetryIntervalMs) {
      WiFi.disconnect();
      beginWifiConnection();
    }
    return;
  }

  if (!webSocketServerStarted) {
    webSocketServer.listen(Config::kWebSocketPort);
    webSocketServerStarted = true;

    if (MDNS.begin(Config::kMdnsHostname)) {
      MDNS.addService("ws", "tcp", Config::kWebSocketPort);
    }

    if (Serial) {
      Serial.printf(
          "{\"type\":\"status\",\"level\":\"ready\","
          "\"message\":\"Wi-Fi WebSocket ready\","
          "\"url\":\"ws://%s:%u\"}\n",
          WiFi.localIP().toString().c_str(),
          Config::kWebSocketPort);
    }
  }

  if (!webSocketClient.available() && webSocketServer.poll()) {
    WebsocketsClient candidate = webSocketServer.accept();
    if (candidate.available()) {
      configureWebSocketClient(candidate);
      webSocketClient = candidate;
    }
  }

  if (webSocketClient.available()) {
    webSocketClient.poll();
  }
}

void sendWifiAudio(
    AudioSourceId source,
    const int16_t* samples,
    size_t sampleCount,
    uint32_t sequence) {
  if (!Config::kStreamWifiPcm || !webSocketClient.available() || sampleCount == 0) {
    return;
  }

  wifiAudioPacket[0] = 'P';
  wifiAudioPacket[1] = 'K';
  wifiAudioPacket[2] = 'A';
  wifiAudioPacket[3] = 'U';
  wifiAudioPacket[4] = 3;  // Protocol version.
  wifiAudioPacket[5] = 1;  // Mono.
  putUint32LittleEndian(&wifiAudioPacket[6], Config::kSampleRate);
  putUint32LittleEndian(&wifiAudioPacket[10], sequence);
  wifiAudioPacket[14] = static_cast<uint8_t>(source);

  const size_t pcmByteCount = sampleCount * sizeof(int16_t);
  memcpy(&wifiAudioPacket[15], samples, pcmByteCount);
  webSocketClient.sendBinary(
      reinterpret_cast<const char*>(wifiAudioPacket),
      15 + pcmByteCount);
}

void sendWifiTelemetry(size_t jsonLength) {
  if (jsonLength > 0 && webSocketClient.available()) {
    webSocketClient.send(telemetryJson, jsonLength);
  }
}
#else
void initializeWifi() {}
void serviceWifi() {}
void sendWifiAudio(AudioSourceId, const int16_t*, size_t, uint32_t) {}
void sendWifiTelemetry(size_t) {}
#endif

}  // namespace

void setup() {
  pinMode(Config::kLedPin, OUTPUT);
  setLed(false);

  Serial.begin(Config::kUsbBaudRate);
  delay(250);

  initializeI2s();
  initializeAnalogCapture();
  initializeWifi();
  sendStatus("ready", "PadKey sensors initialized");
}

void loop() {
  serviceUsbConnection();
  serviceWifi();

  size_t bytesRead = 0;
  const esp_err_t readResult = i2s_read(
      Config::kI2sPort,
      i2sSamples,
      sizeof(i2sSamples),
      &bytesRead,
      Config::kI2sReadTimeout);

  if (readResult != ESP_OK) {
    state.i2sReadErrors += 1;
    if ((state.i2sReadErrors & 0x3F) == 1 && Serial) {
      Serial.printf(
          "{\"type\":\"status\",\"level\":\"error\","
          "\"message\":\"I2S read failed\",\"espError\":\"%s\"}\n",
          esp_err_to_name(readResult));
    }
    return;
  }

  const size_t sampleCount = min(
      bytesRead / sizeof(int32_t),
      Config::kSamplesPerPacket);
  if (sampleCount == 0) {
    return;
  }

  int32_t blockPeak = 0;
  for (size_t index = 0; index < sampleCount; index += 1) {
    const int16_t pcm = convertI2sSample(i2sSamples[index]);
    inmp441Pcm[index] = pcm;
    blockPeak = max(blockPeak, sampleMagnitude(pcm));
  }

  collectAnalogSamples();
  const bool analogPacketReady =
      max4466PcmCount == Config::kSamplesPerPacket &&
      piezoPcmCount == Config::kSamplesPerPacket;
  const bool micDetected = blockPeak > state.micGate;
  const bool max4466Detected =
      state.max4466Peak > Config::kMax4466Threshold;
  const bool piezoDetected = state.piezoPeak > Config::kPiezoThreshold;
  const bool soundDetected =
      micDetected || max4466Detected || piezoDetected;

  updateAdaptiveGate(blockPeak);
  setLed(soundDetected);

  const uint32_t sequence = state.packetSequence++;
  sendUsbAudio(AudioSourceId::kInmp441, inmp441Pcm, sampleCount, sequence);
  sendWifiAudio(AudioSourceId::kInmp441, inmp441Pcm, sampleCount, sequence);
  if (analogPacketReady) {
    sendUsbAudio(
        AudioSourceId::kMax4466,
        max4466Pcm,
        max4466PcmCount,
        sequence);
    sendUsbAudio(
        AudioSourceId::kPiezo,
        piezoPcm,
        piezoPcmCount,
        sequence);
    sendWifiAudio(
        AudioSourceId::kMax4466,
        max4466Pcm,
        max4466PcmCount,
        sequence);
    sendWifiAudio(
        AudioSourceId::kPiezo,
        piezoPcm,
        piezoPcmCount,
        sequence);
  }

  if ((sequence % Config::kTelemetryEveryPackets) == 0) {
    const size_t jsonLength = formatTelemetry(blockPeak, soundDetected);
    if (jsonLength > 0 && Serial) {
      Serial.write(
          reinterpret_cast<const uint8_t*>(telemetryJson),
          jsonLength);
      Serial.write('\n');
    }
    sendWifiTelemetry(jsonLength);
  }

  if (analogPacketReady) {
    max4466PcmCount = 0;
    piezoPcmCount = 0;
    state.max4466Peak = 0;
    state.piezoPeak = 0;
  }

  serviceWifi();
}
