#include <Arduino.h>
#define BUTTON_PIN 4
#include "../components/time/time.ino"
#include "../components/ble/ble.ino"
#include "../components/flash/flash.ino"
#include "../components/deepsleep/deepsleep.ino"

// ESP32-C3 GPIO4 -- button -- GND. No sleep while connected or syncing.
void IRAM_ATTR keyISR() { keyPressed = true; }
MyServerCallbacks serverCallbacks;
MyCharacteristicCallbacks characteristicCallbacks;
bool bleReady = false;
uint32_t lastButtonAt = 0;

bool setupBLE() {
  if (!BLEDevice::init("ESP32-C3")) { Serial.println("BLE_INIT_FAILED"); return false; }
  Serial.printf("FIRMWARE P01/TIME1 READY_FIX_1; BLE stack=%s\n", BLEDevice::getBLEStackString().c_str());
  pServer = BLEDevice::createServer();
  pServer->setCallbacks(&serverCallbacks);
  pService = pServer->createService(SERVICE_UUID);
  pCharacteristic = pService->createCharacteristic(CHARACTERISTIC_UUID,
    BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_NOTIFY);
  pCharacteristic->setCallbacks(&characteristicCallbacks);
#if defined(CONFIG_BLUEDROID_ENABLED)
  notifyDescriptor = new BLE2902();
  pCharacteristic->addDescriptor(notifyDescriptor);
#endif
  // NimBLE creates CCCD automatically; subscription state comes from onSubscribe.
  pService->start();
  BLEAdvertising *advertising = BLEDevice::getAdvertising();
  advertising->addServiceUUID(SERVICE_UUID);
  advertising->setScanResponse(false);
  advertisePending = false;
  startAdvertising();
  return true;
}
void stopBLE() {
  // Arduino-ESP32 3.3.11 lacks public ownership cleanup for BLEService. Recreating
  // GATT objects in a loop leaks services. After wake we save the record/clock and
  // do a software restart, rebuilding BLE once in a fresh heap without erasing NVS.
  BLEDevice::deinit(false);
  notifyDescriptor = nullptr;
  pCharacteristic = nullptr;
  pService = nullptr;
  pServer = nullptr;
  deviceConnected = false;
  ++connectionGeneration;
  xQueueReset(commandQueue);
  resetSync();
  bleReady = false;
}
void recordButtonPress() {
  lastButtonAt = millis();
  refreshSleepDeadline();
  if (writeFile()) Serial.println("Press Re-sync in app to fetch new files");
  else Serial.println("BUTTON_RECORD_FAILED: check SPIFFS and NVS; no auto-format");
}
void setup() {
  Serial.begin(115200);
  delay(500);
  pinMode(BUTTON_PIN, INPUT_PULLUP);
  storageReady = SPIFFS.begin(false);
  counterReady = fileCounter.begin("proto-files", false);
  Serial.println(storageReady ? "SPIFFS mounted" : "SPIFFS unavailable; no auto-format");
  restoreTimeFromNVS();
  printTime();
  // Boot and reconnection do not create phantom button records.
  char identity[13];
  const uint64_t chipId = ESP.getEfuseMac();
  snprintf(identity, sizeof(identity), "%04X%08X", (uint16_t)(chipId >> 32), (uint32_t)chipId);
  stableDeviceId = identity;
  commandQueue = xQueueCreate(12, sizeof(ControlCommand));
  if (!commandQueue) { Serial.println("CONTROL_QUEUE_ALLOCATION_FAILED"); return; }
  bleReady = setupBLE();
  attachInterrupt(digitalPinToInterrupt(BUTTON_PIN), keyISR, FALLING);
  refreshSleepDeadline();
}
void loop() {
  if (!commandQueue) { delay(100); return; }
  if (!bleReady) {
    bleReady = setupBLE();
    refreshSleepDeadline();
    delay(1000);
    return;
  }
  if (!deviceConnected && advertisePending) {
    advertisePending = false;
    startAdvertising();
  }
  serviceSync();
  // A held button must not block ACK processing. The falling edge captures even
  // a short press released before the main loop; debounce rejects contact bounce.
  if (keyPressed) {
    keyPressed = false;
    if (millis() - lastButtonAt > 250) recordButtonPress();
  }
  if (!deviceConnected && !syncActive && !keyPressed && digitalRead(BUTTON_PIN) == HIGH &&
      uxQueueMessagesWaiting(commandQueue) == 0 && millis() - lastActivityAt >= IDLE_SLEEP_MS &&
      configureLightSleepWakeup()) {
    BLEDevice::getAdvertising()->stop();
    if (deviceConnected) { refreshSleepDeadline(); return; }
    detachInterrupt(digitalPinToInterrupt(BUTTON_PIN));
    stopBLE();
    // Preserve an edge caught during teardown, and a short wake press even if
    // it has been released before the software restart rebuilds BLE.
    const bool pressedDuringTeardown = keyPressed || digitalRead(BUTTON_PIN) == LOW;
    const bool wokeByButton = pressedDuringTeardown || enterLightSleep();
    keyPressed = false;
    if (wokeByButton) recordButtonPress();
    // Save the still-running RTC immediately before restart. No boot record is
    // generated; the wake button has already been flushed to SPIFFS above.
    if (clockValid && !saveTimeToNVS()) Serial.println("CLOCK_SNAPSHOT_FAILED_BEFORE_RESTART");
    Serial.println("BLE_RESTART: wake record retained; restarting advertising without filesystem erase");
    Serial.flush();
    ESP.restart();
  }
  delay(10);
}
