#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>

#define MIC_PIN 4

#define SAMPLE_RATE 4000
#define SAMPLES_PER_PACKET 100

#define SERVICE_UUID "12345678-1234-1234-1234-1234567890ab"
#define AUDIO_CHAR_UUID "abcd1234-1234-1234-1234-abcdef123456"

BLECharacteristic *audioChar;
bool deviceConnected = false;

int16_t audioBuffer[SAMPLES_PER_PACKET];

class ServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer *pServer) {
    deviceConnected = true;
  }

  void onDisconnect(BLEServer *pServer) {
    deviceConnected = false;
    BLEDevice::startAdvertising();
  }
};

void setup() {
  Serial.begin(115200);
  analogReadResolution(12);

  BLEDevice::init("ESP32_Audio");

  BLEServer *server = BLEDevice::createServer();
  server->setCallbacks(new ServerCallbacks());

  BLEService *service = server->createService(SERVICE_UUID);

  audioChar = service->createCharacteristic(
    AUDIO_CHAR_UUID,
    BLECharacteristic::PROPERTY_NOTIFY
  );

  audioChar->addDescriptor(new BLE2902());

  service->start();

  BLEAdvertising *advertising = BLEDevice::getAdvertising();
  advertising->addServiceUUID(SERVICE_UUID);
  advertising->start();

  Serial.println("BLE audio ready");
}

void loop() {
  if (!deviceConnected) {
    delay(10);
    return;
  }

  static float dc = 2048;

  for (int i = 0; i < SAMPLES_PER_PACKET; i++) {
    int raw = analogRead(MIC_PIN);

    // Remove DC bias
    dc = 0.999 * dc + 0.001 * raw;

    int sample = raw - dc;

    // Gain adjustment
    sample *= 8;

    if (sample > 32767) sample = 32767;
    if (sample < -32768) sample = -32768;

    audioBuffer[i] = sample;

    delayMicroseconds(250);   // 4 kHz
  }

  audioChar->setValue((uint8_t*)audioBuffer, sizeof(audioBuffer));
  audioChar->notify();
}