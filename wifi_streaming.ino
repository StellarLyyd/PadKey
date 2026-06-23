#include "driver/i2s_std.h"
#include <WiFi.h>
#include <ArduinoWebsockets.h>

#define I2S_BCLK D7
#define I2S_WS   D8
#define I2S_DIN  D9

#define BUFFER_LEN 1024

int32_t rawBuffer[BUFFER_LEN];
int16_t sendBuffer[BUFFER_LEN];

i2s_chan_handle_t rx_handle;

const char* ssid = "Rev Member";
const char* password = "incubator";

const char* websocket_server_host = "10.101.3.15";
const uint16_t websocket_server_port = 8888;

using namespace websockets;

WebsocketsClient client;
bool isWebSocketConnected = false;

void onEventsCallback(WebsocketsEvent event, String data) {
  if (event == WebsocketsEvent::ConnectionOpened) {
    Serial.println("Connection Opened");
    isWebSocketConnected = true;
  } else if (event == WebsocketsEvent::ConnectionClosed) {
    Serial.println("Connection Closed");
    isWebSocketConnected = false;
  }
}

void connectWiFi() {
  WiFi.begin(ssid, password);

  Serial.print("Connecting to WiFi");
  while (WiFi.status() != WL_CONNECTED) {
    delay(500);
    Serial.print(".");
  }

  Serial.println();
  Serial.println("WiFi connected");
  Serial.print("ESP32 IP: ");
  Serial.println(WiFi.localIP());
}

void connectWSServer() {
  client.onEvent(onEventsCallback);

  Serial.print("Connecting to WebSocket");
  while (!client.connect(websocket_server_host, websocket_server_port, "/")) {
    Serial.print(".");
    delay(1000);
  }

  Serial.println();
  Serial.println("WebSocket Connected!");
}

void i2s_install_new() {
  i2s_chan_config_t chan_cfg =
    I2S_CHANNEL_DEFAULT_CONFIG(I2S_NUM_0, I2S_ROLE_MASTER);

  esp_err_t err = i2s_new_channel(&chan_cfg, NULL, &rx_handle);
  Serial.print("i2s_new_channel: ");
  Serial.println(err);

  i2s_std_config_t std_cfg = {
    .clk_cfg = I2S_STD_CLK_DEFAULT_CONFIG(16000),
    .slot_cfg = I2S_STD_MSB_SLOT_DEFAULT_CONFIG(
      I2S_DATA_BIT_WIDTH_32BIT,
      I2S_SLOT_MODE_MONO
    ),
    .gpio_cfg = {
      .mclk = I2S_GPIO_UNUSED,
      .bclk = (gpio_num_t)I2S_BCLK,
      .ws = (gpio_num_t)I2S_WS,
      .dout = I2S_GPIO_UNUSED,
      .din = (gpio_num_t)I2S_DIN,
      .invert_flags = {
        .mclk_inv = false,
        .bclk_inv = false,
        .ws_inv = false,
      },
    },
  };

  err = i2s_channel_init_std_mode(rx_handle, &std_cfg);
  Serial.print("i2s_channel_init_std_mode: ");
  Serial.println(err);

  err = i2s_channel_enable(rx_handle);
  Serial.print("i2s_channel_enable: ");
  Serial.println(err);
}

void micTask(void* parameter) {
  i2s_install_new();

  size_t bytesIn = 0;

  while (true) {
    client.poll();

    esp_err_t result = i2s_channel_read(
      rx_handle,
      rawBuffer,
      sizeof(rawBuffer),
      &bytesIn,
      1000
    );

    if (result == ESP_OK && bytesIn > 0 && isWebSocketConnected) {
      int samplesRead = bytesIn / sizeof(int32_t);

      int16_t minVal = 32767;
      int16_t maxVal = -32768;

      for (int i = 0; i < samplesRead; i++) {
        // Convert INMP441 32-bit sample to 16-bit PCM
        sendBuffer[i] = rawBuffer[i] >> 16;

        if (sendBuffer[i] < minVal) minVal = sendBuffer[i];
        if (sendBuffer[i] > maxVal) maxVal = sendBuffer[i];
      }

      Serial.print("send min: ");
      Serial.print(minVal);
      Serial.print(" max: ");
      Serial.println(maxVal);

      client.sendBinary(
        (const char*)sendBuffer,
        samplesRead * sizeof(int16_t)
      );
    } else {
      Serial.print("I2S read error: ");
      Serial.println(result);
    }

    delay(1);
  }
}

void setup() {
  Serial.begin(115200);
  delay(1000);

  connectWiFi();
  connectWSServer();

  xTaskCreatePinnedToCore(
    micTask,
    "micTask",
    12000,
    NULL,
    1,
    NULL,
    1
  );
}

void loop() {
  client.poll();
  delay(100);
}