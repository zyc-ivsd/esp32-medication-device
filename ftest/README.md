# ftest —— 独立固件测试

与 `firmware/` 平级的测试目录，放**一次性、自包含**的固件验证程序。

和 `firmware/` 的区别：

| | `firmware/` | `ftest/` |
|---|---|---|
| 用途 | 正式原型固件 | 单点问题的最小复现 |
| 依赖 | BLE / SPIFFS / NVS / 主循环全都要 | 尽量不依赖任何东西 |
| 生命周期 | 长期维护 | 问题查清后即可删除 |

单个测试一个子目录，目录名即 sketch 名（Arduino 要求 `.ino` 与所在文件夹同名）。

## lightsleep_wake

浅睡眠 GPIO4 唤醒的最小测试。**只用串口**，不含 LED、BLE、SPIFFS。

背景：正式固件进入浅睡眠后，按 GPIO4 无任何反应，不写文件、也无法连接手机。
已确认的两个事实：进睡眠前 `digitalRead(GPIO4)=1`（上拉正常），
`gpio_wakeup_enable` / `esp_sleep_enable_gpio_wakeup` 都返回 `ESP_OK`。
所以"上拉丢失""配置失败"两条推测已排除。本测试要回答的是：
**去掉所有其它代码后，浅睡眠 GPIO 唤醒本身能不能工作。**

### 运行流程

1. 上电 → 打印状态 → 等待按键
2. 按下 GPIO4 → 打印 `SLEEPING IN 5 SECONDS`，随后 5 秒每秒打印一次状态
3. 5 秒结束 → 进入浅睡眠
4. 再次按下 GPIO4 → 唤醒 → 打印 `WOKEN UP` 和唤醒原因
5. 回到第 1 步循环

### 接线

GPIO4 —— 按钮 —— GND（松开为高电平，按下为低电平）。

编译烧录方式同正式固件，串口 115200。监视器要**先打开再复位板子**，否则看不到开头的输出。

### 怎么看结果

按键唤醒后应出现：

```
**************** WOKEN UP ****************
esp_light_sleep_start returned 0 (0=ESP_OK)
WAKE_CAUSE=7 (GPIO (button))
sleeps=1 wakes=1
GPIO4 level after wake: 1
RESULT: woken by GPIO4 -- light sleep wake works.
```

| 现象 | 含义 |
|---|---|
| `WAKE_CAUSE=7`，`RESULT: woken by GPIO4` | 浅睡眠唤醒本身正常 → 问题在正式固件的 `stopBLE()` / `detachInterrupt()` 等操作 |
| `WAKE_CAUSE=UNDEFINED` | `esp_light_sleep_start()` 立刻返回，压根没睡进去 |
| 唤醒了但 cause 不是 7 | 被其它源唤醒，GPIO 唤醒没生效 |
| 按按钮后完全没有 `WOKEN UP` | 浅睡眠 GPIO 唤醒在这块板子上不工作，需要改用 deep sleep 方案 |

### 注意

- 睡眠期间 USB-CDC 掉电，串口会静默，这是正常现象；唤醒后会恢复。
- 浅睡眠唤醒**不会**重启 sketch，所以 `setup()` 里出现非零 cause 说明是复位而非唤醒。
- `sleeps` / `wakes` 存在 RTC 域，跨浅睡眠累加，但断电或按 RST 会清零。

### 变体测试（当前版本）

第一版测试证明：**只调用 `gpio_wakeup_enable()` 然后睡眠，可以正常唤醒**
（`WAKE_CAUSE=7`）。所以唤醒机制本身没问题，故障一定来自正式固件在睡眠前
多做的那些操作。本版本用**按键次数选择变体**，一个固件跑完全部对比，不必反复烧录。

| 按几下 | 变体 | 睡眠前的额外操作 |
|---|---|---|
| 1 | A | 什么都不做（对照，已知能醒） |
| 2 | B | `attachInterrupt(FALLING)` + `detachInterrupt` |
| 3 | C | B + `pinMode(INPUT_PULLUP)` 重申 |
| 4 | D | B，但 **GPIO 唤醒先登记**，之后再 attach/detach |
| 0 | A | 默认（不按就是 A） |

选完变体后**再按一下**开始 5 秒倒计时，然后进入浅睡眠，按按钮唤醒，
打印 `RESULT`（`=> WOKE BY BUTTON` 或 `=> NOT WOKEN BY BUTTON`），
随后自动回到变体选择。

### 实测结论（2026-10-06）

| 变体 | 顺序 | 结果 |
|---|---|---|
| A | `gpio_wakeup_enable` | ✅ 唤醒 |
| B | `detachInterrupt` → `gpio_wakeup_enable` | ✅ 唤醒 |
| C | `detachInterrupt` → `pinMode` → `gpio_wakeup_enable` | ✅ 唤醒 |
| **D** | **`gpio_wakeup_enable` → `attachInterrupt` → `detachInterrupt`** | ❌ **不唤醒** |

D 两次测试均稳定复现。**根因：`attachInterrupt()` / `detachInterrupt()` 会作废已经登记的
light-sleep GPIO 唤醒源**，而 `gpio_wakeup_enable()`、`esp_sleep_enable_gpio_wakeup()`、
`detachInterrupt()` 全部返回 `ESP_OK`，所以日志看起来完全正常。

正式固件原来的顺序正是 D：

```cpp
if (... && configureLightSleepWakeup()) {   // 先登记唤醒源
    detachInterrupt(...);                    // 再作废它  <- BUG
}
```

修复方式是把 `detachInterrupt()` 提到 `configureLightSleepWakeup()` 之前，即变体 B 的顺序。
已应用到 `firmware/esp32-c3/main/main.ino`，实测唤醒、写记录、软件重启、校时、
同步、归档全链路正常。

### 源码

```cpp
/*
 * Light-sleep wake variant test -- ESP32-C3, serial only.
 *
 * The previous test (sleep with nothing but gpio_wakeup_enable) WOKE CORRECTLY:
 * WAKE_CAUSE=7. So the wake mechanism itself works. The production firmware
 * instead does extra work before sleeping and does NOT wake. This sketch isolates
 * which of those extra steps breaks it, without reflashing between runs.
 *
 * Pick a variant by the number of GPIO4 presses seen during the 6-second
 * selection window after boot:
 *
 *   1 press  -> A: nothing (control, known to work)
 *   2 presses-> B: attachInterrupt + detachInterrupt        (main suspect)
 *   3 presses-> C: attachInterrupt + detachInterrupt + pinMode re-assert
 *   4 presses-> D: attachInterrupt + detachInterrupt + GPIO wake armed FIRST
 *   0 presses-> defaults to A
 *
 * Then press once more to run the 5s countdown and sleep. After sleeping, press
 * to wake. The wake result is printed and the sketch returns to selection so the
 * next variant can be run without reflashing.
 *
 * No LED, no BLE, no SPIFFS. Only Serial at 115200.
 *
 * Button: GPIO4 -- button -- GND. Released = HIGH (pull-up), pressed = LOW.
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
