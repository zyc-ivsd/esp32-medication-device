#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include <BLE2901.h>
#include <time.h>
#include <sys/time.h>
#include <string.h>

#define PACKET_SIZE 30
#define BLE_WAIT_TIMEOUT_MS 30000UL
#define SEND_FINISH_DELAY_MS 1000UL

// 时间校准指令：手机发送文本 "TM" + "YYYY-MM-DD HH:MM:SS"
// 例如 "TM2026-08-29 22:30:00"（共 21 字节，含前缀）
#define TIME_PREFIX "TM"

#define SERVICE_UUID "4fafc201-1fb5-459e-8fcc-c5c9c331914b"
#define CHARACTERISTIC_UUID "beb5483e-36e1-4688-b7f5-ea07361b26a8"

// ===================== 对外接口前置声明 =====================
void startAdvertising();
bool setTimeFromString(const String &s);
bool setTimeFromUnix(uint32_t ts);
void refreshSleepDeadline();
bool deadlineReached(uint32_t deadline);
bool shouldEnterLightSleep();
extern BLEServer *pServer;
extern BLECharacteristic *pCharacteristic;

BLEServer *pServer = nullptr;
BLECharacteristic *pCharacteristic = nullptr;
BLE2901 *descriptor_2901 = nullptr;

volatile bool deviceConnected = false;
volatile bool keyPressed = false;
bool oldDeviceConnected = false;
bool dataSent = false;

uint8_t packetBuffer[PACKET_SIZE];
uint32_t packetNumber = 0;

// 轻睡眠期限：无蓝牙连接且到点后进入轻度睡眠
static uint32_t sleepDeadline = 0;

// 睡眠期限相关（供 main.ino 使用）
void refreshSleepDeadline()
{
    sleepDeadline = millis() + BLE_WAIT_TIMEOUT_MS;
}

bool deadlineReached(uint32_t deadline)
{
    return (int32_t)(millis() - deadline) >= 0;
}

bool shouldEnterLightSleep()
{
    return !deviceConnected && deadlineReached(sleepDeadline);
}

/*
 *  为调试提供状态反馈
 */

class MyServerCallbacks : public BLEServerCallbacks
{
    void onConnect(BLEServer *server) override
    {
        deviceConnected = true;
        dataSent = false;
        Serial.println("手机已连接");
    }

    void onDisconnect(BLEServer *server) override
    {
        deviceConnected = false;
        Serial.println("手机已断开");
    }
};

/*
 *  接受手机端的数据：
 *  1. 协议 SET_TIME 帧（推荐，见 protocol/ble-gatt.md）：
 *     0x03 + timestamp(uint32 小端) —— 共 5 字节二进制
 *  2. 文本调试指令："TM" + "YYYY-MM-DD HH:MM:SS"
 *     例：TM2026-08-29 22:30:00（nRF Connect 可直接手敲）
 *  3. 其他数据：串口打印调试。
 *  校准成功后设备回复当前时间字符串；失败回复 TIME_ERR。
 *  手机 App 每次连接后建议先发送一次时间进行校准。
 */
class MyCharacteristicCallbacks : public BLECharacteristicCallbacks
{
    void onWrite(BLECharacteristic *characteristic) override
    {
        String rxValue = characteristic->getValue();
        if (rxValue.length() == 0)
            return;

        size_t len = rxValue.length();
        const uint8_t *data = (const uint8_t *)rxValue.c_str();

        auto replyText = [&](const char *text)
        {
            pCharacteristic->setValue((uint8_t *)text, strlen(text));
            pCharacteristic->notify();
        };

        // --- 1. 协议 SET_TIME 帧：0x03 + uint32 小端 ---
        if (len == 5 && data[0] == 0x03)
        {
            uint32_t ts = (uint32_t)data[1] | ((uint32_t)data[2] << 8) |
                          ((uint32_t)data[3] << 16) | ((uint32_t)data[4] << 24);
            if (setTimeFromUnix(ts))
            {
                Serial.println("时间校准成功（SET_TIME）");
                replyText("TIME_OK");
            }
            else
            {
                Serial.println("时间戳非法，校准失败");
                replyText("TIME_ERR");
            }
            return;
        }

        // --- 2. 文本时间校准指令 ---
        if (rxValue.startsWith(TIME_PREFIX))
        {
            if (setTimeFromString(rxValue))
            {
                Serial.println("时间校准成功");
                // 回复设备当前时间（字符串），便于手机端确认
                time_t now = time(nullptr);
                struct tm timeinfo;
                localtime_r(&now, &timeinfo);
                char buf[24];
                strftime(buf, sizeof(buf), "%Y-%m-%d %H:%M:%S", &timeinfo);
                replyText(buf);
            }
            else
            {
                Serial.println("时间格式非法，校准失败（应为 TMYYYY-MM-DD HH:MM:SS）");
                replyText("TIME_ERR");
            }
            return;
        }

        // --- 3. 普通调试数据 ---
        Serial.print("手机发送的数据: ");
        Serial.println(rxValue);
    }
};

/*
 *  开始广播
 */
void startAdvertising()
{
    BLEDevice::startAdvertising();
    Serial.println("BLE 开始广播");
}
