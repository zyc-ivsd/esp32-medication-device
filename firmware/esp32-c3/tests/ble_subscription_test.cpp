#include "../components/ble/ble.ino"
#include <stdio.h>
#define CHECK(condition) do { if (!(condition)) { \
  fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #condition); return 1; \
} } while (0)

int main() {
  BLEServer server;
  BLECharacteristic characteristic;
  BLE2902 descriptor;
  descriptor.characteristic = &characteristic;
  pCharacteristic = &characteristic;
  notifyDescriptor = &descriptor;
  MyServerCallbacks serverCallbacks;
  BLEServerCallbacks &serverEvents = serverCallbacks;
  MyCharacteristicCallbacks characteristicCallbacks;
  BLECharacteristicCallbacks &characteristicEvents = characteristicCallbacks;
  CHECK(!notifyReady());
  serverEvents.onConnect(&server);
  // This fails on 55714de: its onConnect calls setNotifications(false), which
  // removes PROPERTY_NOTIFY on the pinned C3 NimBLE SDK.
  CHECK(characteristic.getProperties() & BLECharacteristic::PROPERTY_NOTIFY);
  CHECK(!notifyReady());
#if defined(CONFIG_NIMBLE_ENABLED)
  ble_gap_conn_desc connection = {7};
  serverEvents.onConnect(&server, &connection);
  // A notifiable characteristic alone is NOT proof of client subscription.
  CHECK(descriptor.getNotifications());
  CHECK(!notifyReady());
#endif
  FakeQueue queue(sizeof(ControlCommand));
  commandQueue = &queue;
  characteristic.value = "HELLO";
  characteristicEvents.onWrite(&characteristic);
  CHECK(queue.items.size() == 1);
  ControlCommand hello = {};
  memcpy(&hello, queue.items[0].data(), sizeof(hello));
  CHECK(strcmp(hello.text, "HELLO") == 0);
  CHECK(hello.generation == connectionGeneration);
  CHECK(!notifyReady());

#if defined(CONFIG_NIMBLE_ENABLED)
  ble_gap_conn_desc stale = {99};
  characteristicEvents.onSubscribe(&characteristic, &stale, 1);
  CHECK(!notifyReady());
  characteristicEvents.onSubscribe(&characteristic, &connection, 2); // indications only
  CHECK(!notifyReady());
  characteristicEvents.onSubscribe(&characteristic, &connection, 1);
#else
  descriptor.setNotifications(true); // Client writes CCCD 0x0001 on Bluedroid.
#endif
  CHECK(notifyReady());
#if defined(CONFIG_NIMBLE_ENABLED)
  characteristicEvents.onSubscribe(&characteristic, &connection, 0);
  CHECK(!notifyReady());
  CHECK(characteristic.getProperties() & BLECharacteristic::PROPERTY_NOTIFY);
  characteristicEvents.onSubscribe(&characteristic, &connection, 1);
  CHECK(notifyReady());
#endif
  serverEvents.onDisconnect(&server);
  CHECK(!notifyReady());
  characteristicEvents.onWrite(&characteristic);
  CHECK(queue.items.size() == 1); // Disconnected HELLO is never queued.
  serverEvents.onConnect(&server);
  CHECK(!notifyReady()); // Never reuse the previous connection's subscription.
#if defined(CONFIG_NIMBLE_ENABLED)
  ble_gap_conn_desc reconnected = {8};
  serverEvents.onConnect(&server, &reconnected);
  characteristicEvents.onSubscribe(&characteristic, &connection, 1);
  CHECK(!notifyReady());
  characteristicEvents.onSubscribe(&characteristic, &reconnected, 1);
#else
  descriptor.setNotifications(true);
#endif
  CHECK(notifyReady());
  puts("Production BLE callbacks: Notify preserved, HELLO queued, subscription/reconnect gates passed");
}
