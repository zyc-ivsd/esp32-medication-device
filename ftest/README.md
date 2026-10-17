# Isolated firmware diagnostics

This directory contains self-contained Arduino sketches for investigating individual firmware issues. Each sketch lives in a matching directory. These tests concern the project's **ESP32-C3** prototype.

## Light-sleep GPIO wake test

`lightsleep_wake` uses serial output without BLE, SPIFFS, or LEDs. Connect a button between GPIO4 and GND. Use 115200 baud and open the serial monitor before resetting the board.

Select a variant by pressing the button during the six-second selection window, then press once more to start the five-second sleep countdown. Press again to wake the board and inspect `WOKEN UP`, the wake cause, and `RESULT`.

| Presses | Variant | Operations before sleep |
|---|---|---|
| 0 or 1 | A | Configure GPIO wake only |
| 2 | B | Attach/detach interrupt, then configure wake |
| 3 | C | B, with input pull-up reapplied before configuring wake |
| 4 | D | Configure wake before attaching/detaching the interrupt |

A GPIO wake result is expected for a successful button wake. An undefined or different cause needs investigation; no output alone is not sufficient to diagnose the board because USB serial behavior can also change during sleep. Light-sleep return resumes execution rather than restarting the sketch.

## Wake-source configuration

The firmware configures the GPIO wake source after detaching the runtime button interrupt. Variants A–D compare the ordering of wake configuration, interrupt attachment/detachment, and input pull-up configuration. The serial report identifies the selected variant, sleep return code, wake cause, and counters.

## Reference source

```cpp
/*
 * ESP32-C3 light-sleep GPIO wake configuration test.
 * Select variants A-D by the number of button presses during the selection window.
 * Press once more to start the countdown, then press to wake the board.
 * Serial: 115200 baud. Button: GPIO4 -- button -- GND, with input pull-up.
 */

#include <esp_sleep.h>
#include <driver/gpio.h>

#define BUTTON_PIN 4
#define SERIAL_BAUD 115200
#define SELECT_WINDOW_MS 6000

RTC_DATA_ATTR static uint32_t sleepCount = 0;
RTC_DATA_ATTR static uint32_t wakeCount = 0;

static const char *causeName(esp_sleep_wakeup_cause_t cause) {
  switch (cause) {
    case ESP_SLEEP_WAKEUP_UNDEFINED: return "UNDEFINED (sleep never actually ran)";
    case ESP_SLEEP_WAKEUP_GPIO:      return "GPIO (button)";
    case ESP_SLEEP_WAKEUP_TIMER:     return "TIMER";
    case ESP_SLEEP_WAKEUP_TOUCHPAD:  return "TOUCHPAD";
    case ESP_SLEEP_WAKEUP_UART:      return "UART";
    case ESP_SLEEP_WAKEUP_BT:        return "BT";
    default:                         return "OTHER";
  }
}

static void isrStub() {}  // stand-in for the production keyISR

// Waits for HIGH then LOW, so a stuck-low pin is not read as a press and a press
// between samples is not missed.
static bool waitForPress(uint32_t timeoutMs) {
  const uint32_t deadline = millis() + timeoutMs;
  while (digitalRead(BUTTON_PIN) == HIGH) {
    if (timeoutMs != 0 && (int32_t)(millis() - deadline) >= 0) return false;
    delay(10);
  }
  delay(30);  // debounce
  return true;
}

static const char *variantName(int v) {
  switch (v) {
    case 0: return "A: baseline (nothing extra)";
    case 1: return "B: attachInterrupt + detachInterrupt";
    case 2: return "C: B + pinMode re-assert";
    case 3: return "D: B + GPIO wake armed FIRST";
    default: return "?";
  }
}

// Applies the per-variant pre-sleep operations. Returns false if the GPIO wake
// could not be armed.
static bool armWakeForVariant(int v) {
  Serial.printf("VARIANT %s\n", variantName(v));

  const bool doInterrupt = (v == 1 || v == 2 || v == 3);
  const bool doPinMode = (v == 2);
  const bool wakeFirst = (v == 3);

  if (wakeFirst) {
    const esp_err_t e = gpio_wakeup_enable((gpio_num_t)BUTTON_PIN, GPIO_INTR_LOW_LEVEL);
    Serial.printf("  [pre] gpio_wakeup_enable=%d\n", (int)e);
    if (e != ESP_OK) return false;
  }

  if (doInterrupt) {
    // Mirror the production order: attach in setup(), detach just before sleep.
    attachInterrupt(digitalPinToInterrupt(BUTTON_PIN), isrStub, FALLING);
    Serial.println("  attachInterrupt(FALLING) done");
    detachInterrupt(digitalPinToInterrupt(BUTTON_PIN));
    Serial.println("  detachInterrupt done");
  }

  if (doPinMode) {
    pinMode(BUTTON_PIN, INPUT_PULLUP);
    Serial.println("  pinMode(INPUT_PULLUP) re-asserted");
  }

  if (!wakeFirst) {
    const esp_err_t e = gpio_wakeup_enable((gpio_num_t)BUTTON_PIN, GPIO_INTR_LOW_LEVEL);
    Serial.printf("  gpio_wakeup_enable=%d\n", (int)e);
    if (e != ESP_OK) return false;
  }

  const esp_err_t e = esp_sleep_enable_gpio_wakeup();
  Serial.printf("  esp_sleep_enable_gpio_wakeup=%d\n", (int)e);
  if (e != ESP_OK) return false;

  return true;
}

void setup() {
  Serial.begin(SERIAL_BAUD);
  delay(1500);

  pinMode(BUTTON_PIN, INPUT_PULLUP);

  Serial.println();
  Serial.println("====== light-sleep wake VARIANT test ======");
  Serial.printf("build %s %s\n", __DATE__, __TIME__);
  const esp_sleep_wakeup_cause_t cause = esp_sleep_get_wakeup_cause();
  Serial.printf("setup(): cause=%d (%s) sleeps=%lu wakes=%lu\n",
                (int)cause, causeName(cause),
                (unsigned long)sleepCount, (unsigned long)wakeCount);
  if (cause != ESP_SLEEP_WAKEUP_UNDEFINED) {
    Serial.println("NOTE: cause!=0 at setup() means a reset, not a light-sleep wake.");
  }
  Serial.println("===========================================");
}

void loop() {
  // ---------- 1. Variant selection by press count ----------
  Serial.println();
  Serial.println("SELECT VARIANT: presses during the next 6s");
  Serial.println("   1 = A baseline (nothing extra)");
  Serial.println("   2 = B attachInterrupt + detachInterrupt");
  Serial.println("   3 = C B + pinMode re-assert");
  Serial.println("   4 = D B + GPIO wake armed FIRST");
  Serial.println("   0 = defaults to A");
  Serial.print("counting");

  // A held button must be released before counting starts.
  const uint32_t releaseDeadline = millis() + 10000;
  while (digitalRead(BUTTON_PIN) == LOW) {
    if ((int32_t)(millis() - releaseDeadline) >= 0) {
      Serial.println("\nWARN: GPIO4 stuck LOW; assuming released");
      break;
    }
    delay(20);
  }

  int presses = 0;
  const uint32_t windowEnd = millis() + SELECT_WINDOW_MS;
  while ((int32_t)(millis() - windowEnd) < 0) {
    if (digitalRead(BUTTON_PIN) == LOW) {
      ++presses;
      Serial.printf(" [%d]", presses);
      // Wait for release so one hold is not counted repeatedly.
      while (digitalRead(BUTTON_PIN) == LOW) delay(10);
    }
    delay(10);
  }
  Serial.println();

  int variant = presses - 1;          // 1 press -> variant 0 (A)
  if (presses <= 0) variant = 0;      // none -> A
  if (variant > 3) { variant = 3; }   // clamp; extra presses just pick D
  Serial.printf("selected presses=%d -> variant %d (%s)\n",
                presses, variant, variantName(variant));

  // ---------- 2. Brief settle so the selection press is done ----------
  delay(500);

  // ---------- 3. Wait for the run press ----------
  Serial.println("PRESS GPIO4 once more to run the 5s countdown and sleep");
  waitForPress(0);
  Serial.println(">>> RUN: SLEEPING IN 5 SECONDS <<<");

  for (int remaining = 5; remaining >= 1; --remaining) {
    Serial.printf("... %d | GPIO4=%d\n", remaining, digitalRead(BUTTON_PIN));
    delay(1000);
  }
  Serial.printf("GPIO4 just before sleep: %d (must be 1)\n", digitalRead(BUTTON_PIN));

  // ---------- 4. Apply the variant and sleep ----------
  if (!armWakeForVariant(variant)) {
    Serial.println("FATAL: could not arm wake; skipping sleep this round");
    delay(5000);
    return;
  }

  Serial.println(">>> ENTERING LIGHT SLEEP NOW -- press GPIO4 to wake <<<");
  Serial.flush();
  delay(50);

  ++sleepCount;
  const esp_err_t sleepErr = esp_light_sleep_start();

  // ---------- 5. Report ----------
  ++wakeCount;
  const esp_sleep_wakeup_cause_t cause = esp_sleep_get_wakeup_cause();
  Serial.println();
  Serial.println("************ RESULT ************");
  Serial.printf("variant %d (%s)\n", variant, variantName(variant));
  Serial.printf("esp_light_sleep_start returned %d\n", (int)sleepErr);
  Serial.printf("WAKE_CAUSE=%d (%s)\n", (int)cause, causeName(cause));
  Serial.printf("sleeps=%lu wakes=%lu  GPIO4=%d\n",
                (unsigned long)sleepCount, (unsigned long)wakeCount,
                digitalRead(BUTTON_PIN));
  if (cause == ESP_SLEEP_WAKEUP_GPIO) {
    Serial.println("=> WOKE BY BUTTON: this variant does NOT break wake.");
  } else {
    Serial.println("=> NOT WOKEN BY BUTTON: this variant BREAKS the wake.");
  }
  Serial.println("********************************");

  delay(1500);  // let it be read, then back to variant selection
}
```
