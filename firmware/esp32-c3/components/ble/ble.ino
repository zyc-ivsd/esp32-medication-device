#include <Arduino.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include <freertos/FreeRTOS.h>
#include <freertos/queue.h>

#define PACKET_SIZE 20
#define SERVICE_UUID "4fafc201-1fb5-459e-8fcc-c5c9c331914b"
#define CHARACTERISTIC_UUID "beb5483e-36e1-4688-b7f5-ea07361b26a8"

BLEServer *pServer = nullptr;
BLEService *pService = nullptr;
BLECharacteristic *pCharacteristic = nullptr;
BLE2902 *notifyDescriptor = nullptr;
volatile bool deviceConnected = false;
volatile bool keyPressed = false;
volatile uint32_t connectionGeneration = 0;
volatile bool advertisePending = false;
struct ControlCommand { char text[21]; uint32_t generation; };
QueueHandle_t commandQueue = nullptr;
const uint32_t IDLE_SLEEP_MS = 30000;
volatile uint32_t lastActivityAt = 0;
void refreshSleepDeadline() { lastActivityAt = millis(); }

class MyServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer *) override {
    ++connectionGeneration;
    if (notifyDescriptor) notifyDescriptor->setNotifications(false);
    deviceConnected = true;
    refreshSleepDeadline();
    Serial.println("CONNECTED: waiting for HELLO and Notify subscription");
  }
  void onDisconnect(BLEServer *) override {
    deviceConnected = false;
    ++connectionGeneration;
    advertisePending = true;
    refreshSleepDeadline();
    Serial.println("DISCONNECTED: files retained");
  }
};
class MyCharacteristicCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic *characteristic) override {
    const auto value = characteristic->getValue();
    if (value.length() == 0 || value.length() > 20 || !deviceConnected) return;
    ControlCommand command = {};
    memcpy(command.text, value.c_str(), value.length());
    command.generation = connectionGeneration;
    // BLE callbacks never touch SPIFFS or wait for a database/network response.
    if (xQueueSend(commandQueue, &command, 0) != pdTRUE)
      Serial.println("CONTROL_QUEUE_FULL: client can retry");
  }
};
void startAdvertising() {
  BLEDevice::startAdvertising();
  Serial.println("BLE advertising");
}
