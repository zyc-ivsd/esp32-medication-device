#include "esp_sleep.h"
#include "driver/gpio.h"
#include "driver/uart.h"
#include "Arduino.h"

// ===================== 对外接口前置声明 =====================
void enterLightSleep();
void configureLightSleepWakeup();
void saveTimeToNVS();
void refreshSleepDeadline();
bool shouldEnterLightSleep();
extern volatile bool keyPressed;

// ESP32-C3 的 RTC GPIO 为 GPIO0~GPIO5，按键固定在 GPIO4，引脚不变。
// 按键接线：GPIO4 -- 按键 -- GND（按下为低电平）。
#define BUTTON_PIN 4

/*
 *  配置轻睡眠期间的唤醒源：仅 GPIO4 低电平唤醒。
 *  esp_sleep_enable_gpio_wakeup() 只支持低电平唤醒，正好匹配按键电路。
 *  按键是 RTC GPIO（0~5），轻睡眠期间保持内部上拉生效，不会误唤醒。
 */
void configureLightSleepWakeup()
{
    esp_err_t err = gpio_wakeup_enable((gpio_num_t)BUTTON_PIN, GPIO_INTR_LOW_LEVEL);
    if (err != ESP_OK)
    {
        Serial.printf("gpio_wakeup_enable 失败: %d\n", err);
        return;
    }

    err = esp_sleep_enable_gpio_wakeup();
    if (err != ESP_OK)
    {
        Serial.printf("esp_sleep_enable_gpio_wakeup 失败: %d\n", err);
    }
    else
    {
        Serial.println("GPIO4 低电平唤醒已配置");
    }

    // 串口有数据时也唤醒（调试用；若 Serial 为 USB-CDC 则此配置无副作用）
    err = esp_sleep_enable_uart_wakeup(UART_NUM_0);
    if (err == ESP_OK)
    {
        Serial.println("串口唤醒已配置");
    }
}

void enterLightSleep()
{
    configureLightSleepWakeup();

    saveTimeToNVS(); // 睡前把当前时间存 NVS（轻睡 RTC 计时，醒来时钟仍准）
    Serial.println("无蓝牙连接超时，进入轻度睡眠（按 GPIO4 按键或蓝牙连接触发唤醒）...");
    Serial.flush();
    delay(20); // 等 UART 发送完成

    while (true)
    {
        esp_light_sleep_start();

        esp_sleep_wakeup_cause_t cause = esp_sleep_get_wakeup_cause();
        if (cause == ESP_SLEEP_WAKEUP_GPIO)
        {
            Serial.println("按键唤醒");
            keyPressed = true; // 与正常按键中断路径一致，交由 loop 消抖处理
            return;
        }
        if (cause == ESP_SLEEP_WAKEUP_UART)
        {
            Serial.println("串口唤醒");
            return;
        }
        if (cause != ESP_SLEEP_WAKEUP_UNDEFINED)
        {
            Serial.printf("其他唤醒源: %d，返回主循环\n", cause);
            return;
        }
        // UNDEFINED = sleep 被打断直接返回，继续睡。
    }
}
