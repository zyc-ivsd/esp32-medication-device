#include <esp_sleep.h>
#include <driver/gpio.h>
#include "../log/log.h"

// Explicit light sleep stops BLE. GPIO4 wakes the device; a phone cannot scan or
// connect until advertising has restarted. UART/USB wake is not promised.
//
// gpio_wakeup_enable() only supports level-triggered wake on ESP32-C3, so the
// button (INPUT_PULLUP, pressed = LOW) is configured for GPIO_INTR_LOW_LEVEL.
bool configureLightSleepWakeup() {
  esp_err_t error = gpio_wakeup_enable(static_cast<gpio_num_t>(BUTTON_PIN), GPIO_INTR_LOW_LEVEL);
  if (error == ESP_OK) error = esp_sleep_enable_gpio_wakeup();
  if (error != ESP_OK) LOG("SLEEP_WAKE_CONFIG_FAILED: %d\n", error);
  return error == ESP_OK;
}
bool enterLightSleep() {
  if (clockValid && !saveTimeToNVS()) LOGLN("CLOCK_SNAPSHOT_FAILED: RTC remains active in light sleep");
  LOGLN("LIGHT_SLEEP: press GPIO4 button to wake, then reconnect in app");
  logFlush();
  const esp_err_t error = esp_light_sleep_start();
  if (error != ESP_OK) {
    LOG("LIGHT_SLEEP_FAILED: %d; returning to advertising\n", error);
    return false;
  }
  // Log the actual cause so a failed wake is diagnosable instead of silent.
  const esp_sleep_wakeup_cause_t cause = esp_sleep_get_wakeup_cause();
  LOG("WAKE_CAUSE: %d\n", static_cast<int>(cause));
  // Any cause other than UNDEFINED means we really woke from sleep. UNDEFINED
  // only happens on a cold boot, which cannot occur here because we just slept.
  return cause != ESP_SLEEP_WAKEUP_UNDEFINED;
}
