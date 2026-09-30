#include <time.h>
#include <sys/time.h>
#include <stdio.h>
#include <Arduino.h>
#include "nvs_flash.h"
#include "nvs.h"

// ===================== 对外接口前置声明 =====================
// （这些 .ino 文件通过 #include 拼进 main.ino，Arduino 不会自动生成原型）
void setManualTime(int year, int month, int day, int hour, int minute, int second);
bool setTimeFromString(const String &s);
bool setTimeFromUnix(uint32_t ts);
void saveTimeToNVS();
void restoreTimeFromNVS();
void printTime();
bool isTimeValid();
bool isTimeSynced();

// ===================== 内部状态 =====================
static bool s_timeValid = false;  // 当前系统时钟是否有效
static bool s_timeSynced = false; // 是否已被手机校准过

bool isTimeValid() { return s_timeValid; }
bool isTimeSynced() { return s_timeSynced; }

// ===================== 设置系统时钟 =====================
static void applyTime(time_t t, bool synced)
{
    struct timeval now = {};
    now.tv_sec = t;
    now.tv_usec = 0;
    settimeofday(&now, nullptr);
    s_timeValid = true;
    s_timeSynced = synced;
}

// 手动设置时间（保留原接口，调试用）
void setManualTime(int year, int month, int day, int hour, int minute, int second)
{
    struct tm timeinfo = {};
    timeinfo.tm_year = year - 1900;
    timeinfo.tm_mon = month - 1;
    timeinfo.tm_mday = day;
    timeinfo.tm_hour = hour;
    timeinfo.tm_min = minute;
    timeinfo.tm_sec = second;

    time_t timestamp = mktime(&timeinfo);
    applyTime(timestamp, false);
}

// 手机下发文本时间："TM" + "YYYY-MM-DD HH:MM:SS"（如 TM2026-08-29 22:30:00）
// 用 ASCII 文本而非二进制，避免 0x00 字节被 String 截断，调试时也能直接手敲
bool setTimeFromString(const String &s)
{
    int year = 0, month = 0, day = 0, hour = 0, minute = 0, second = 0;

    // 允许 "TM" 前缀（校验已在 ble.ino 完成）或直接的时间字符串
    const char *p = s.c_str();
    if (p[0] == 'T' && p[1] == 'M')
        p += 2;

    int matched = sscanf(p, "%d-%d-%d %d:%d:%d",
                         &year, &month, &day, &hour, &minute, &second);
    if (matched != 6)
        return false;

    // 合法性检查
    if (year < 2000 || year > 2099 || month < 1 || month > 12 ||
        day < 1 || day > 31 || hour > 23 || minute > 59 || second > 59)
        return false;

    struct tm timeinfo = {};
    timeinfo.tm_year = year - 1900;
    timeinfo.tm_mon = month - 1;
    timeinfo.tm_mday = day;
    timeinfo.tm_hour = hour;
    timeinfo.tm_min = minute;
    timeinfo.tm_sec = second;

    time_t timestamp = mktime(&timeinfo);
    if (timestamp < 0)
        return false;

    applyTime(timestamp, true);
    saveTimeToNVS(); // 校准后立刻持久化

    Serial.println("时间已通过手机校准");
    printTime();
    return true;
}

// 协议 SET_TIME 帧：0x03 + Unix 时间戳（uint32 小端，见 protocol/ble-gatt.md）
bool setTimeFromUnix(uint32_t ts)
{
    if (ts < 946684800U) // 早于 2000-01-01 视为非法
        return false;

    applyTime((time_t)ts, true);
    saveTimeToNVS();

    Serial.println("时间已通过手机校准（SET_TIME 帧）");
    printTime();
    return true;
}

// ===================== NVS 持久化 =====================
// 说明：轻度睡眠期间 RTC 计时器持续走时，时钟不会丢；
// NVS 保存"最后已知时间"，用于冷启动（断电重上电）后恢复。
static bool s_nvsReady = false;

static bool ensureNVSReady()
{
    if (s_nvsReady)
        return true;
    esp_err_t err = nvs_flash_init();
    if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND)
    {
        nvs_flash_erase();
        err = nvs_flash_init();
    }
    if (err != ESP_OK)
    {
        Serial.printf("NVS 初始化失败: %d\n", err);
        return false;
    }
    s_nvsReady = true;
    return true;
}

void saveTimeToNVS()
{
    if (!ensureNVSReady() || !s_timeValid)
        return;

    nvs_handle_t handle;
    if (nvs_open("rtc", NVS_READWRITE, &handle) != ESP_OK)
        return;

    time_t now = time(nullptr);
    nvs_set_u32(handle, "tlo", (uint32_t)((uint64_t)now & 0xFFFFFFFFULL));
    nvs_set_u32(handle, "thi", (uint32_t)((uint64_t)now >> 32));
    nvs_set_u32(handle, "tvalid", 1);
    nvs_commit(handle);
    nvs_close(handle);
}

void restoreTimeFromNVS()
{
    s_timeValid = false;
    s_timeSynced = false;

    if (!ensureNVSReady())
        return;

    nvs_handle_t handle;
    if (nvs_open("rtc", NVS_READONLY, &handle) != ESP_OK)
        return;

    uint32_t hi = 0, lo = 0, valid = 0;
    nvs_get_u32(handle, "thi", &hi);
    nvs_get_u32(handle, "tlo", &lo);
    nvs_get_u32(handle, "tvalid", &valid);
    nvs_close(handle);

    if (!valid)
        return;

    time_t saved = (time_t)(((int64_t)hi << 32) | lo);
    applyTime(saved, false);
    Serial.println("时钟已从 NVS 恢复（断电期间走时丢失，可能偏慢）");
}

// ===================== 通过串口反馈当前时间 =====================
void printTime()
{
    if (!s_timeValid)
    {
        Serial.println("时间未同步");
        return;
    }
    time_t now;
    time(&now);
    struct tm timeinfo;
    localtime_r(&now, &timeinfo);

    Serial.printf("%04d-%02d-%02d %02d:%02d:%02d\n",
                  timeinfo.tm_year + 1900,
                  timeinfo.tm_mon + 1,
                  timeinfo.tm_mday,
                  timeinfo.tm_hour,
                  timeinfo.tm_min,
                  timeinfo.tm_sec);
}
