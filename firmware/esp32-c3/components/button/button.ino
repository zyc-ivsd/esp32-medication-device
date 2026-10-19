#include <driver/timer.h>
#include <esp_intr_alloc.h>
#include <esp_timer.h>
#include <hal/gpio_ll.h>
#include <soc/gpio_struct.h>

// Use the legacy timer's explicitly IRAM-safe interrupt API. The prebuilt
// Arduino SDK does not enable GPTIMER_ISR_CACHE_SAFE; its normal callback path
// can therefore be delayed by SPIFFS/NVS writes. This component exclusively owns
// TIMER_GROUP_0/TIMER_0; do not mix it with Arduino's GPTimer-based timer APIs.
struct ButtonEvent { int64_t capturedUs; uint64_t retainedUtc; };
constexpr size_t BUTTON_EVENT_CAPACITY = 32;
constexpr int64_t BUTTON_DEBOUNCE_US = 250000;
constexpr uint64_t BUTTON_PULSE_US = 4000000;
static DRAM_ATTR StaticQueue_t buttonQueueStorage;
static DRAM_ATTR uint8_t buttonQueueBuffer[BUTTON_EVENT_CAPACITY * sizeof(ButtonEvent)];
static DRAM_ATTR QueueHandle_t buttonQueue = nullptr;
static DRAM_ATTR portMUX_TYPE buttonMux = portMUX_INITIALIZER_UNLOCKED;
static DRAM_ATTR bool buttonPulseActive = false;
static DRAM_ATTR bool buttonHasAcceptedPress = false;
static DRAM_ATTR int64_t buttonLastPressUs = 0;
static DRAM_ATTR uint64_t buttonPulseDeadline = 0;
static DRAM_ATTR uint32_t buttonDroppedEvents = 0;
static bool buttonInterruptAttached = false;
static bool buttonControlReady = false;
static bool buttonRecordPending = false;
static uint64_t buttonRecordUtc = 0;
static int64_t buttonRecordRetryAtUs = 0;
static timer_isr_handle_t buttonTimerInterrupt = nullptr;

// Only a controlled software restart consumes this journal. It allows BLE to
// recover even if SPIFFS is full, so the phone can sync and reclaim archives.
// RTC RAM is not durable across power loss. No records are written to Flash by
// this handoff, and corrupt/unrelated reset state is rejected before replay.
struct ButtonRestartJournal {
  uint32_t magic;
  uint32_t count;
  uint32_t checksum;
  uint64_t utc[BUTTON_EVENT_CAPACITY + 1];
};
static RTC_NOINIT_ATTR ButtonRestartJournal buttonRestartJournal;
constexpr uint32_t BUTTON_JOURNAL_MAGIC = 0x42544e31;

uint32_t buttonJournalChecksum() {
  uint32_t hash = 2166136261u ^ buttonRestartJournal.count;
  for (uint32_t i = 0; i < buttonRestartJournal.count; ++i) {
    const uint64_t utc = buttonRestartJournal.utc[i];
    for (uint8_t byte = 0; byte < 8; ++byte) {
      hash = (hash ^ static_cast<uint8_t>(utc >> (byte * 8))) * 16777619u;
    }
  }
  return hash;
}

void restoreButtonRecordsAfterRestart() {
  const bool valid = esp_reset_reason() == ESP_RST_SW &&
    buttonRestartJournal.magic == BUTTON_JOURNAL_MAGIC &&
    buttonRestartJournal.count > 0 && buttonRestartJournal.count <= BUTTON_EVENT_CAPACITY + 1 &&
    buttonRestartJournal.checksum == buttonJournalChecksum();
  if (valid) {
    buttonRecordPending = true;
    buttonRecordUtc = buttonRestartJournal.utc[0];
    for (uint32_t i = 1; i < buttonRestartJournal.count; ++i) {
      const ButtonEvent event = {0, buttonRestartJournal.utc[i]};
      xQueueSend(buttonQueue, &event, 0);
    }
  }
  buttonRestartJournal.magic = 0; // Consume once; never replay an old snapshot.
}

void stageButtonRecordsForRestart() {
  // The caller has detached the button IRQ and confirmed the pulse is LOW.
  buttonRestartJournal.magic = 0;
  __sync_synchronize();
  buttonRestartJournal.count = 0;
  struct timeval now = {};
  gettimeofday(&now, nullptr);
  const int64_t utcOffset = static_cast<int64_t>(now.tv_sec) * 1000000 + now.tv_usec - esp_timer_get_time();
  if (buttonRecordPending) buttonRestartJournal.utc[buttonRestartJournal.count++] = buttonRecordUtc;
  ButtonEvent event;
  while (buttonRestartJournal.count < BUTTON_EVENT_CAPACITY + 1 &&
         xQueueReceive(buttonQueue, &event, 0) == pdTRUE) {
    const int64_t utcUs = utcOffset + event.capturedUs;
    buttonRestartJournal.utc[buttonRestartJournal.count++] = event.retainedUtc ? event.retainedUtc :
      (utcUs > 0 ? static_cast<uint64_t>(utcUs / 1000000) : 0);
  }
  buttonRestartJournal.checksum = buttonJournalChecksum();
  __sync_synchronize();
  buttonRestartJournal.magic = BUTTON_JOURNAL_MAGIC;
  __sync_synchronize();
}

void IRAM_ATTR buttonPulseTimerISR(void *) {
  portENTER_CRITICAL_ISR(&buttonMux);
  timer_group_clr_intr_status_in_isr(TIMER_GROUP_0, TIMER_0);
  const uint64_t now = timer_group_get_counter_value_in_isr(TIMER_GROUP_0, TIMER_0);
  if (buttonPulseActive && now >= buttonPulseDeadline) {
    gpio_ll_set_level(&GPIO, BUTTON_OUTPUT_PIN, LOW);
    buttonPulseActive = false;
  } else if (buttonPulseActive) {
    // A falling edge may have extended the deadline after an alarm became
    // pending. Preserve the new pulse instead of applying the stale alarm.
    timer_group_set_alarm_value_in_isr(TIMER_GROUP_0, TIMER_0, buttonPulseDeadline);
    timer_group_enable_alarm_in_isr(TIMER_GROUP_0, TIMER_0);
  }
  portEXIT_CRITICAL_ISR(&buttonMux);
}

bool IRAM_ATTR acceptButtonPress(int64_t capturedUs) {
  portENTER_CRITICAL_SAFE(&buttonMux);
  if (buttonHasAcceptedPress && capturedUs - buttonLastPressUs <= BUTTON_DEBOUNCE_US) {
    portEXIT_CRITICAL_SAFE(&buttonMux);
    return false;
  }
  buttonHasAcceptedPress = true;
  buttonLastPressUs = capturedUs;
  const uint64_t now = timer_group_get_counter_value_in_isr(TIMER_GROUP_0, TIMER_0);
  gpio_ll_set_level(&GPIO, BUTTON_OUTPUT_PIN, HIGH);
  buttonPulseActive = true;
  buttonPulseDeadline = now + BUTTON_PULSE_US;
  timer_group_set_alarm_value_in_isr(TIMER_GROUP_0, TIMER_0, buttonPulseDeadline);
  timer_group_enable_alarm_in_isr(TIMER_GROUP_0, TIMER_0);
  portEXIT_CRITICAL_SAFE(&buttonMux);
  return true;
}

void IRAM_ATTR keyISR(void *) {
  const ButtonEvent event = {esp_timer_get_time(), 0};
  if (!acceptButtonPress(event.capturedUs)) return;
  BaseType_t taskWoken = pdFALSE;
  if (xQueueSendFromISR(buttonQueue, &event, &taskWoken) != pdTRUE) {
    portENTER_CRITICAL_ISR(&buttonMux);
    ++buttonDroppedEvents;
    portEXIT_CRITICAL_ISR(&buttonMux);
  }
  if (taskWoken) portYIELD_FROM_ISR();
}

bool attachButtonInterrupt() {
  if (buttonInterruptAttached) return true;
  esp_err_t error = gpio_set_intr_type(static_cast<gpio_num_t>(BUTTON_PIN), GPIO_INTR_NEGEDGE);
  if (error == ESP_OK) error = gpio_isr_handler_add(static_cast<gpio_num_t>(BUTTON_PIN), keyISR, nullptr);
  buttonInterruptAttached = error == ESP_OK;
  if (!buttonInterruptAttached) LOG("BUTTON_INTERRUPT_FAILED: %d\n", error);
  return buttonInterruptAttached;
}

void detachButtonInterrupt() {
  gpio_intr_disable(static_cast<gpio_num_t>(BUTTON_PIN));
  if (buttonInterruptAttached) gpio_isr_handler_remove(static_cast<gpio_num_t>(BUTTON_PIN));
  buttonInterruptAttached = false;
}

bool initializeButtonControl() {
  buttonQueue = xQueueCreateStatic(BUTTON_EVENT_CAPACITY, sizeof(ButtonEvent),
                                  buttonQueueBuffer, &buttonQueueStorage);
  if (!buttonQueue) return false;
  restoreButtonRecordsAfterRestart();
  timer_config_t config = {};
  config.alarm_en = TIMER_ALARM_DIS;
  config.counter_en = TIMER_PAUSE;
  config.intr_type = TIMER_INTR_LEVEL;
  config.counter_dir = TIMER_COUNT_UP;
  config.auto_reload = TIMER_AUTORELOAD_DIS;
  config.clk_src = TIMER_SRC_CLK_XTAL;
  config.divider = CONFIG_XTAL_FREQ; // MHz / divider = a 1 MHz counter.
  if (timer_init(TIMER_GROUP_0, TIMER_0, &config) != ESP_OK) return false;
  if (timer_isr_register(TIMER_GROUP_0, TIMER_0, buttonPulseTimerISR, nullptr,
                        ESP_INTR_FLAG_IRAM | ESP_INTR_FLAG_LEVEL1, &buttonTimerInterrupt) != ESP_OK ||
      timer_enable_intr(TIMER_GROUP_0, TIMER_0) != ESP_OK ||
      timer_start(TIMER_GROUP_0, TIMER_0) != ESP_OK) return false;
  // Install a direct IRAM GPIO handler, avoiding Arduino's flash-resident ISR
  // trampoline. No other component in this firmware installs a GPIO ISR service.
  if (gpio_install_isr_service(ESP_INTR_FLAG_IRAM | ESP_INTR_FLAG_LEVEL1) != ESP_OK) return false;
  buttonControlReady = attachButtonInterrupt();
  return buttonControlReady;
}

bool isButtonPulseActive() {
  portENTER_CRITICAL(&buttonMux);
  const bool active = buttonPulseActive;
  portEXIT_CRITICAL(&buttonMux);
  return active;
}

bool buttonRecordsPending() {
  return buttonRecordPending || (buttonQueue && uxQueueMessagesWaiting(buttonQueue) != 0);
}

void captureWakeButtonPress(int64_t capturedUs) {
  if (!buttonControlReady || !acceptButtonPress(capturedUs)) return;
  const ButtonEvent event = {capturedUs, 0};
  if (xQueueSend(buttonQueue, &event, 0) != pdTRUE) {
    portENTER_CRITICAL(&buttonMux);
    ++buttonDroppedEvents;
    portEXIT_CRITICAL(&buttonMux);
  }
}

void serviceButtonRecords() {
  static uint32_t reportedDrops = 0;
  portENTER_CRITICAL(&buttonMux);
  const uint32_t drops = buttonDroppedEvents;
  portEXIT_CRITICAL(&buttonMux);
  if (drops != reportedDrops && logdetail::loggingEnabled()) {
    LOG("BUTTON_QUEUE_OVERFLOW: %lu record(s) not queued\n", static_cast<unsigned long>(drops));
    reportedDrops = drops;
  }
  const int64_t nowUs = esp_timer_get_time();
  if (!buttonRecordPending) {
    ButtonEvent event;
    if (!buttonQueue || xQueueReceive(buttonQueue, &event, 0) != pdTRUE) return;
    // Translate the captured monotonic edge time using the current UTC mapping.
    // Neither queueing delays nor Flash writes become part of the event time.
    struct timeval now = {};
    gettimeofday(&now, nullptr);
    const int64_t utcUs = static_cast<int64_t>(now.tv_sec) * 1000000 + now.tv_usec;
    const int64_t recordedUs = utcUs - (esp_timer_get_time() - event.capturedUs);
    buttonRecordUtc = event.retainedUtc ? event.retainedUtc :
      (recordedUs > 0 ? static_cast<uint64_t>(recordedUs / 1000000) : 0);
    buttonRecordPending = true;
    buttonRecordRetryAtUs = 0;
    refreshSleepDeadline();
  }
  if (nowUs < buttonRecordRetryAtUs) return;
  if (writeFile(buttonRecordUtc)) {
    buttonRecordPending = false;
    LOGLN("BUTTON_RECORDED: synchronization pending");
  } else {
    // Keep the event in RAM. Controlled BLE restarts hand it over in RTC RAM;
    // normal idle sleep is postponed until persistence succeeds.
    buttonRecordRetryAtUs = esp_timer_get_time() + 1000000;
    LOGLN("BUTTON_RECORD_RETRY: storage unavailable; no auto-format");
  }
}
