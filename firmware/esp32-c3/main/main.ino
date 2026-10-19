#include <Arduino.h>
#include <driver/gpio.h>

#define BUTTON_PIN 4
#define BUTTON_OUTPUT_PIN 9
#include "../components/log/log.h"
#include "../components/time/time.ino"
#include "../components/ble/ble.ino"
#include "../components/flash/flash.ino"
#include "../components/button/button.ino"
#include "../components/deepsleep/deepsleep.ino"

// ESP32-C3 GPIO4 -- button -- GND. No sleep while connected or syncing.
MyServerCallbacks serverCallbacks;
MyCharacteristicCallbacks characteristicCallbacks;
bool bleReady = false;
bool restartPending = false;

void initializeStartupPins() {
  // SuperMini general-purpose pins: GPIO0..10, except the GPIO4 button input.
  // Preserve GPIO11 (VDD_SPI), GPIO12..17 (flash), GPIO18/19 (USB), and
  // GPIO20/21 (UART), which must retain their peripheral functions.
  for (uint8_t pin = 0; pin <= 10; ++pin) {
    if (pin == BUTTON_PIN) continue;
    // Preload LOW before enabling output, including after a software restart.
    gpio_set_level(static_cast<gpio_num_t>(pin), LOW);
    pinMode(pin, OUTPUT);
  }
  pinMode(BUTTON_PIN, INPUT_PULLUP);
}

bool setupBLE() {
  if (!BLEDevice::init("ESP32-C3")) { LOGLN("BLE_INIT_FAILED"); return false; }
  LOG("FIRMWARE P01/TIME1 READY_FIX_1; BLE stack=%s\n", BLEDevice::getBLEStackString().c_str());
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
void setup() {
  initializeStartupPins();
  const bool buttonReady = initializeButtonControl();
  Serial.begin(115200);
  delay(500);
  // Park a probe in the USB-CDC buffer before any real logging. If no monitor
  // is attached the probe stays there, logging stays off, and the link runs at
  // full speed instead of waiting on USB writes nobody is reading.
  logdetail::primeMonitorProbe();
  if (!buttonReady) LOGLN("BUTTON_CONTROL_INIT_FAILED: GPIO9 remains LOW");
  storageReady = SPIFFS.begin(false);
  counterReady = fileCounter.begin("proto-files", false);
  loadArchiveState();
  LOGLN(storageReady ? "SPIFFS mounted" : "SPIFFS unavailable; no auto-format");
  restoreTimeFromNVS();
  printTime();
  // Boot and reconnection do not create phantom button records.
  char identity[13];
  const uint64_t chipId = ESP.getEfuseMac();
  snprintf(identity, sizeof(identity), "%04X%08X", (uint16_t)(chipId >> 32), (uint32_t)chipId);
  stableDeviceId = identity;
  commandQueue = xQueueCreate(12, sizeof(ControlCommand));
  if (!commandQueue) { LOGLN("CONTROL_QUEUE_ALLOCATION_FAILED"); return; }
  bleReady = setupBLE();
  refreshSleepDeadline();
}
void loop() {
  // GPIO9 is controlled entirely by IRAM interrupts. Persist one captured
  // event per iteration, without moving its original timestamp to write time.
  serviceButtonRecords();
  if (restartPending) {
    // BLE was torn down for sleep. Finish the wake pulse before restarting so
    // resetting the GPIO cannot truncate it; further presses remain recordable.
    if (!isButtonPulseActive()) {
      if (clockValid && !saveTimeToNVS()) LOGLN("CLOCK_SNAPSHOT_FAILED_BEFORE_RESTART");
      LOGLN("BLE_RESTART: wake record retained; restarting advertising without filesystem erase");
      logFlush();
      // A new press can arrive during NVS/logging. Recheck after disabling edge
      // capture so restart cannot truncate a just-started pulse or lose its file.
      detachButtonInterrupt();
      if (!isButtonPulseActive()) {
        stageButtonRecordsForRestart();
        ESP.restart();
      }
      attachButtonInterrupt();
    }
    delay(10);
    return;
  }
  if (!commandQueue) { delay(100); return; }
  // Cheap check that turns logging on once a monitor is seen draining the port.
  logdetail::pollMonitor();
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
  if (buttonControlReady && !deviceConnected && !syncActive && !buttonRecordsPending() &&
      !isButtonPulseActive() && digitalRead(BUTTON_PIN) == HIGH &&
      uxQueueMessagesWaiting(commandQueue) == 0 && millis() - lastActivityAt >= IDLE_SLEEP_MS) {
    // Keep edge capture enabled during slow NVS/log/BLE teardown operations.
    prepareLightSleep();
    if (deviceConnected || buttonRecordsPending() || isButtonPulseActive() ||
        digitalRead(BUTTON_PIN) == LOW) return;
    BLEDevice::getAdvertising()->stop();
    if (deviceConnected) {
      refreshSleepDeadline();
      return;
    }
    stopBLE();
    // Release the runtime interrupt BEFORE arming level-triggered wake. Doing
    // so afterwards can disable the board's GPIO wake source.
    detachButtonInterrupt();
    if (!buttonRecordsPending() && !isButtonPulseActive()) {
      if (digitalRead(BUTTON_PIN) == LOW) {
        captureWakeButtonPress(esp_timer_get_time());
      } else if (configureLightSleepWakeup()) {
        timer_pause(TIMER_GROUP_0, TIMER_0);
        int64_t wokeAtUs = 0;
        const bool wokeByButton = enterLightSleep(wokeAtUs);
        timer_start(TIMER_GROUP_0, TIMER_0);
        // Start the wake pulse before serial logging or filesystem work.
        if (wokeByButton) captureWakeButtonPress(wokeAtUs);
        attachButtonInterrupt();
        LOG("WAKE_CAUSE: %d; sleep result: %d\n", static_cast<int>(lastSleepWakeCause), lastSleepError);
      }
    }
    restartPending = true;
    attachButtonInterrupt();
  }
  delay(10);
}
