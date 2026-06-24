#include <driver/i2s.h>
#include <mbedtls/base64.h>

// INMP441 pins
#define I2S_SCK D1
#define I2S_WS  D3
#define I2S_SD  D2

#define PIEZO_PIN A8
#define LED_PIN 21

#define SAMPLE_RATE 16000
#define SAMPLE_COUNT 256
#define PIEZO_THRESHOLD 100
#define PCM_SERIAL_BAUD 921600
#define TELEMETRY_EVERY_N_BLOCKS 4

static uint32_t packetSequence = 0;
static int32_t noiseFloor = 1000;
static int32_t gate = 1600;

// Base64 requires four output bytes for every three input bytes.
static char encodedPcm[((SAMPLE_COUNT * sizeof(int16_t) + 2) / 3) * 4 + 1];

void setup() {
  Serial.begin(PCM_SERIAL_BAUD);
  pinMode(LED_PIN, OUTPUT);
  digitalWrite(LED_PIN, HIGH);

  i2s_config_t i2s_config = {
    .mode = (i2s_mode_t)(I2S_MODE_MASTER | I2S_MODE_RX),
    .sample_rate = SAMPLE_RATE,
    .bits_per_sample = I2S_BITS_PER_SAMPLE_32BIT,
    .channel_format = I2S_CHANNEL_FMT_ONLY_LEFT,
    .communication_format = I2S_COMM_FORMAT_STAND_I2S,
    .intr_alloc_flags = ESP_INTR_FLAG_LEVEL1,
    .dma_buf_count = 4,
    .dma_buf_len = SAMPLE_COUNT,
    .use_apll = false,
    .tx_desc_auto_clear = false,
    .fixed_mclk = 0
  };

  i2s_pin_config_t pin_config = {
    .bck_io_num = I2S_SCK,
    .ws_io_num = I2S_WS,
    .data_out_num = I2S_PIN_NO_CHANGE,
    .data_in_num = I2S_SD
  };

  i2s_driver_install(I2S_NUM_0, &i2s_config, 0, NULL);
  i2s_set_pin(I2S_NUM_0, &pin_config);
  i2s_zero_dma_buffer(I2S_NUM_0);
}

void loop() {
  int32_t i2sSamples[SAMPLE_COUNT];
  int16_t pcmSamples[SAMPLE_COUNT];
  size_t bytesRead = 0;
  i2s_read(I2S_NUM_0, i2sSamples, sizeof(i2sSamples), &bytesRead, portMAX_DELAY);

  const int sampleCount = bytesRead / sizeof(int32_t);
  int32_t peak = 0;
  for (int index = 0; index < sampleCount; index++) {
    // Preserve the signed waveform for PCM. Tune this shift if recordings
    // clip or are too quiet on the physical INMP441 build.
    const int32_t shifted = i2sSamples[index] >> 14;
    pcmSamples[index] = (int16_t)constrain(shifted, -32768, 32767);
    peak = max(peak, abs(shifted));
  }

  const int piezoValue = analogRead(PIEZO_PIN);
  const bool micDetected = peak > gate;
  const bool soundDetected = micDetected || piezoValue > PIEZO_THRESHOLD;

  // Do not let sustained speech become the new noise floor.
  if (!micDetected) {
    noiseFloor = (noiseFloor * 15 + peak) / 16;
    gate = max((int32_t)40, (int32_t)(noiseFloor * 1.6f));
  }

  digitalWrite(LED_PIN, soundDetected ? LOW : HIGH);

  size_t encodedLength = 0;
  const size_t pcmBytes = sampleCount * sizeof(int16_t);
  const int encodeResult = mbedtls_base64_encode(
    (unsigned char *)encodedPcm,
    sizeof(encodedPcm) - 1,
    &encodedLength,
    (const unsigned char *)pcmSamples,
    pcmBytes
  );

  if (encodeResult == 0) {
    encodedPcm[encodedLength] = '\0';
    Serial.print("{\"type\":\"audio\",\"format\":\"pcm_s16le\",\"sampleRate\":16000,\"channels\":1,\"sequence\":");
    Serial.print(packetSequence++);
    Serial.print(",\"pcm\":\"");
    Serial.print(encodedPcm);
    Serial.println("\"}");
  }

  if (packetSequence % TELEMETRY_EVERY_N_BLOCKS == 0) {
    Serial.print("INMP441:");
    Serial.print(peak);
    Serial.print(",NoiseFloor:");
    Serial.print(noiseFloor);
    Serial.print(",Gate:");
    Serial.print(gate);
    Serial.print(",PIEZO:");
    Serial.println(piezoValue);
  }
}
