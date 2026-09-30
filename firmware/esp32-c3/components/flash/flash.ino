#include "SPIFFS.h"
#include <Arduino.h>

// ===================== 对外接口前置声明 =====================
bool writeFile();
bool sendAllFiles();
extern uint8_t packetBuffer[];
extern uint32_t packetNumber;
extern volatile bool deviceConnected;
extern BLECharacteristic *pCharacteristic;

/*
 *   向文件系统中写入数据
 */
bool writeFile()
{
    time_t now = time(nullptr);
    struct tm timeinfo;
    localtime_r(&now, &timeinfo);

    // 写记录时顺带把当前时间持久化到 NVS，断电后可恢复到最近一次记录的时间
    saveTimeToNVS();

    char timeString[32];
    strftime(timeString, sizeof(timeString), "%Y-%m-%d_%H-%M-%S", &timeinfo);

    String fileName = "/data_" + String(timeString) + ".txt";
    File file = SPIFFS.open(fileName, FILE_WRITE);
    if (!file)
    {
        Serial.print("文件打开失败: ");
        Serial.println(fileName);
        return false;
    }

    file.println(timeString);
    file.close();
    Serial.print("已创建文件: ");
    Serial.println(fileName);
    return true;
}

/*
 *   通过蓝牙发送文件数据
 */
bool sendAllFiles()
{
    if (!deviceConnected)
        return false;

    File root = SPIFFS.open("/");
    if (!root || !root.isDirectory())
    {
        Serial.println("无法打开 SPIFFS 根目录");
        return false;
    }

    File file = root.openNextFile();
    while (file && deviceConnected)
    {
        if (!file.isDirectory())
        {
            Serial.print("FILE: ");
            Serial.println(file.name());
            Serial.print("SIZE: ");
            Serial.println(file.size());

            while (file.available() && deviceConnected)
            {
                size_t length = file.read(packetBuffer, PACKET_SIZE);
                if (length == 0)
                    break;

                pCharacteristic->setValue(packetBuffer, length);
                pCharacteristic->notify();

                Serial.print("发送 Packet: ");
                Serial.print(packetNumber++);
                Serial.print("  长度: ");
                Serial.println(length);
                delay(20);
            }
        }

        file.close();
        file = root.openNextFile();
    }
    root.close();

    if (!deviceConnected)
    {
        Serial.println("发送过程中手机断开，保留文件以便下次重发");
        return false;
    }

    Serial.println("所有文件发送完成");

    // 与原程序一致：发送成功后清空 SPIFFS；如需保留文件，请注释此段。
    if (SPIFFS.format())
    {
        Serial.println("SPIFFS 已清空");
    }
    else
    {
        Serial.println("SPIFFS 清空失败");
    }
    return true;
}