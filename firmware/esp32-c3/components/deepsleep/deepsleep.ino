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
void prepareLightSleep() {
  if (clockValid && !saveTimeToNVS()) LOGLN("CLOCK_SNAPSHOT_FAILED: RTC remains active in light sleep");
  LOGLN("LIGHT_SLEEP: press GPIO4 button to wake, then reconnect in app");
  logFlush();
}
esp_err_t lastSleepError = ESP_OK;
esp_sleep_wakeup_cause_t lastSleepWakeCause = ESP_SLEEP_WAKEUP_UNDEFINED;
bool enterLightSleep(int64_t &wokeAtUs) {
  lastSleepError = esp_light_sleep_start();
  wokeAtUs = esp_timer_get_time();
  lastSleepWakeCause = lastSleepError == ESP_OK ? esp_sleep_get_wakeup_cause() : ESP_SLEEP_WAKEUP_UNDEFINED;
  // Do not create a phantom button record for another wake source or failure.
  return lastSleepWakeCause == ESP_SLEEP_WAKEUP_GPIO;
}
