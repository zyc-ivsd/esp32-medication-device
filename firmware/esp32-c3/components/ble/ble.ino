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
#if defined(CONFIG_NIMBLE_ENABLED)
volatile bool notifySubscribed = false;
volatile uint16_t activeConnectionHandle = BLE_HS_CONN_HANDLE_NONE;
#endif
volatile bool keyPressed = false;
volatile uint32_t connectionGeneration = 0;
volatile bool advertisePending = false;
struct ControlCommand { char text[21]; uint32_t generation; };
QueueHandle_t commandQueue = nullptr;
const uint32_t IDLE_SLEEP_MS = 30000;
volatile uint32_t lastActivityAt = 0;
void refreshSleepDeadline() { lastActivityAt = millis(); }

bool notifyReady() {
  if (!deviceConnected || !pCharacteristic ||
      !(pCharacteristic->getProperties() & BLECharacteristic::PROPERTY_NOTIFY)) return false;
#if defined(CONFIG_NIMBLE_ENABLED)
  // BLE2902::getNotifications() reports PROPERTY_NOTIFY on NimBLE, not CCCD.
  // Only the native subscription callback confirms that the phone is listening.
  return notifySubscribed;
#else
  return notifyDescriptor && notifyDescriptor->getNotifications();
#endif
}

class MyServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer *) override {
    ++connectionGeneration;
#if defined(CONFIG_NIMBLE_ENABLED)
    notifySubscribed = false;
    activeConnectionHandle = BLE_HS_CONN_HANDLE_NONE;
#else
    // This API resets CCCD only on Bluedroid. On NimBLE it disables the
    // characteristic's notification capability and prevents READY forever.
    if (notifyDescriptor) notifyDescriptor->setNotifications(false);
#endif
    deviceConnected = true;
    refreshSleepDeadline();
    Serial.println("CONNECTED: waiting for HELLO and Notify subscription");
  }
#if defined(CONFIG_NIMBLE_ENABLED)
  void onConnect(BLEServer *, ble_gap_conn_desc *connection) override {
    if (connection) activeConnectionHandle = connection->conn_handle;
  }
#endif
  void onDisconnect(BLEServer *) override {
    deviceConnected = false;
#if defined(CONFIG_NIMBLE_ENABLED)
    notifySubscribed = false;
    activeConnectionHandle = BLE_HS_CONN_HANDLE_NONE;
#endif
    ++connectionGeneration;
    advertisePending = true;
    refreshSleepDeadline();
    Serial.println("DISCONNECTED: files retained");
  }
};
class MyCharacteristicCallbacks : public BLECharacteristicCallbacks {
#if defined(CONFIG_NIMBLE_ENABLED)
  void onSubscribe(BLECharacteristic *characteristic, ble_gap_conn_desc *connection, uint16_t value) override {
    if (!deviceConnected || characteristic != pCharacteristic || !connection ||
        connection->conn_handle != activeConnectionHandle) return;
    notifySubscribed = (value & 0x0001) != 0;
    Serial.println(notifySubscribed ? "NOTIFY_SUBSCRIBED: can reply READY" : "NOTIFY_UNSUBSCRIBED: waiting for phone");
  }
#endif
  void onWrite(BLECharacteristic *characteristic) override {
    const auto value = characteristic->getValue();
    if (value.length() == 0 || value.length() > 20 || !deviceConnected) return;
    ControlCommand command = {};
    memcpy(command.text, value.c_str(), value.length());
    command.generation = connectionGeneration;
    Serial.printf("CONTROL_RX %s (generation %lu)\n", command.text, static_cast<unsigned long>(command.generation));
    // BLE callbacks never touch SPIFFS or wait for a database/network response.
    if (xQueueSend(commandQueue, &command, 0) != pdTRUE)
      Serial.println("CONTROL_QUEUE_FULL: client can retry");
  }
};
void startAdvertising() {
  BLEDevice::startAdvertising();
  Serial.println("BLE advertising");
}
