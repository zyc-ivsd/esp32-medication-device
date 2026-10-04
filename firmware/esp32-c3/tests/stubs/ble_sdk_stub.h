#pragma once
#include <stdint.h>
#include <string.h>
#include <string>
#include <vector>

// Host model of only the SDK calls used by the production BLE callbacks.
// Crucial Arduino-ESP32 3.3.11 contract: NimBLE BLE2902::setNotifications
// changes the characteristic PROPERTY_NOTIFY, not the client's subscription.
// See the pinned upstream BLE2902.cpp, not the legacy Bluedroid semantics.
using String = std::string;
// Frozen clock, but delay() advances it so bounded-wait loops in the firmware
// terminate instead of spinning forever on host.
inline uint32_t &fakeNow() {
  static uint32_t now = 1000;
  return now;
}
inline uint32_t millis() { return fakeNow(); }
inline void delay(uint32_t ms) { fakeNow() += ms == 0 ? 1 : ms; }
struct FakeSerial {
  // Model a port with no monitor attached: no writable space, so the firmware's
  // monitor probe never enables logging and nothing blocks. write() counts the
  // bytes the probe tried to park.
  size_t parked = 0;
  int availableForWrite() const { return 0; }
  void write(char) { ++parked; }
  void println() {}
  void println(const char *) {}
  void println(const String &) {}
  template <typename... Args> void printf(const char *, Args...) {}
};
static FakeSerial Serial;
struct ble_gap_conn_desc { uint16_t conn_handle; };
static const uint16_t BLE_HS_CONN_HANDLE_NONE = 0xffff;
class BLEServer {};
class BLEService {};
class BLECharacteristic {
 public:
  static const uint16_t PROPERTY_NOTIFY = 0x10;
  uint16_t properties = PROPERTY_NOTIFY;
  String value;
  uint16_t getProperties() const { return properties; }
  void setNotifyProperty(bool enabled) {
    if (enabled) properties |= PROPERTY_NOTIFY;
    else properties &= ~PROPERTY_NOTIFY;
  }
  String getValue() const { return value; }
};
class BLE2902 {
 public:
  BLECharacteristic *characteristic = nullptr;
  bool subscribed = false;
  void setNotifications(bool enabled) {
#if defined(CONFIG_NIMBLE_ENABLED)
    if (characteristic) characteristic->setNotifyProperty(enabled);
#else
    subscribed = enabled;
#endif
  }
  bool getNotifications() const {
#if defined(CONFIG_NIMBLE_ENABLED)
    return characteristic && (characteristic->getProperties() & BLECharacteristic::PROPERTY_NOTIFY);
#else
    return subscribed;
#endif
  }
};
class BLEServerCallbacks {
 public:
  virtual ~BLEServerCallbacks() {}
  virtual void onConnect(BLEServer *) {}
  virtual void onDisconnect(BLEServer *) {}
#if defined(CONFIG_NIMBLE_ENABLED)
  virtual void onConnect(BLEServer *, ble_gap_conn_desc *) {}
#endif
};
class BLECharacteristicCallbacks {
 public:
  virtual ~BLECharacteristicCallbacks() {}
  virtual void onWrite(BLECharacteristic *) {}
#if defined(CONFIG_NIMBLE_ENABLED)
  virtual void onSubscribe(BLECharacteristic *, ble_gap_conn_desc *, uint16_t) {}
#endif
};
class BLEDevice { public: static void startAdvertising() {} };
struct FakeQueue {
  explicit FakeQueue(size_t size) : itemSize(size) {}
  size_t itemSize;
  std::vector<std::vector<uint8_t>> items;
};
using QueueHandle_t = FakeQueue *;
static const int pdTRUE = 1;
inline int xQueueSend(QueueHandle_t queue, const void *item, int) {
  if (!queue) return 0;
  const uint8_t *bytes = static_cast<const uint8_t *>(item);
  queue->items.emplace_back(bytes, bytes + queue->itemSize);
  return pdTRUE;
}
