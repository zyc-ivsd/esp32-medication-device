#include <Arduino.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include <BLE2901.h>
#include <time.h>
#include <sys/time.h>
#include "SPIFFS.h"
#include "esp_sleep.h"

// ESP32-C3 的 RTC GPIO 为 GPIO0~GPIO5，这里使用 GPIO4 进行深睡唤醒。
// 按键接线：GPIO4 -- 按键 -- GND。
#define BUTTON_PIN 4
#define PACKET_SIZE 30
#define BLE_WAIT_TIMEOUT_MS 30000UL
#define SEND_FINISH_DELAY_MS 1000UL

#define SERVICE_UUID "4fafc201-1fb5-459e-8fcc-c5c9c331914b"
#define CHARACTERISTIC_UUID "beb5483e-36e1-4688-b7f5-ea07361b26a8"

BLEServer *pServer = nullptr;
BLECharacteristic *pCharacteristic = nullptr;
BLE2901 *descriptor_2901 = nullptr;

volatile bool deviceConnected = false;
volatile bool keyPressed = false;
bool oldDeviceConnected = false;
bool dataSent = false;

uint8_t packetBuffer[PACKET_SIZE];
uint32_t packetNumber = 0;
uint32_t sleepDeadline = 0;

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

class MyCharacteristicCallbacks : public BLECharacteristicCallbacks
{
  void onWrite(BLECharacteristic *characteristic) override
  {
    String rxValue = characteristic->getValue();
    if (rxValue.length() > 0)
    {
      Serial.print("手机发送的数据: ");
      Serial.println(rxValue);
    }
  }
};

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
  struct timeval now = {};
  now.tv_sec = timestamp;
  settimeofday(&now, nullptr);
}

void printTime()
{
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

void IRAM_ATTR keyISR()
{
  keyPressed = true;
}

bool writeFile()
{
  time_t now = time(nullptr);
  struct tm timeinfo;
  localtime_r(&now, &timeinfo);

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

void startAdvertising()
{
  BLEDevice::startAdvertising();
  Serial.println("BLE 开始广播");
}

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

bool deadlineReached(uint32_t deadline)
{
  return static_cast<int32_t>(millis() - deadline) >= 0;
}

void enterDeepSleep()
{
  Serial.println("准备进入 Deep Sleep...");
  Serial.flush();
  delay(100);
  esp_deep_sleep_start();
}

void setup()
{
  Serial.begin(115200);
  delay(500);

  Serial.println();
  Serial.println("ESP32-C3 启动");

  pinMode(BUTTON_PIN, INPUT_PULLUP);
/*
  // 单个 GPIO4 低电平唤醒。GPIO4 是 ESP32-C3 的 RTC GPIO。
  gpio_wakeup_enable((gpio_num_t)BUTTON_PIN, GPIO_INTR_LOW_LEVEL);
esp_err_t wakeupResult = esp_sleep_enable_gpio_wakeup();
  if (wakeupResult != ESP_OK)
  {
    Serial.print("深睡唤醒配置失败，错误码: ");
    Serial.println(wakeupResult);
  }
  else
  {
    Serial.println("GPIO4 低电平深睡唤醒已启用");
  }
*/
  if (!SPIFFS.begin(true))
  {
    Serial.println("SPIFFS Mount Failed");
    return;
  }
  Serial.println("SPIFFS Mounted");

  // 保留原程序的手动时间设置。
  setManualTime(2026, 8, 29, 22, 30, 0);
  Serial.println("Time calibrated.");
  printTime();

  // 每次启动或深睡唤醒时创建一条记录。
  writeFile();

  BLEDevice::init("ESP32-C3");
  pServer = BLEDevice::createServer();
  pServer->setCallbacks(new MyServerCallbacks());

  BLEService *pService = pServer->createService(SERVICE_UUID);
  pCharacteristic = pService->createCharacteristic(
      CHARACTERISTIC_UUID,
      BLECharacteristic::PROPERTY_READ |
          BLECharacteristic::PROPERTY_WRITE |
          BLECharacteristic::PROPERTY_NOTIFY |
          BLECharacteristic::PROPERTY_INDICATE);
  pCharacteristic->setCallbacks(new MyCharacteristicCallbacks());
  pCharacteristic->addDescriptor(new BLE2902());

  descriptor_2901 = new BLE2901();
  descriptor_2901->setDescription("ESP32-C3 data characteristic");
  descriptor_2901->setAccessPermissions(ESP_GATT_PERM_READ);
  pCharacteristic->addDescriptor(descriptor_2901);

  pService->start();

  BLEAdvertising *advertising = BLEDevice::getAdvertising();
  advertising->addServiceUUID(SERVICE_UUID);
  advertising->setScanResponse(false);
  advertising->setMinPreferred(0x0);
  startAdvertising();

  attachInterrupt(digitalPinToInterrupt(BUTTON_PIN), keyISR, FALLING);

  //sleepDeadline = millis() + BLE_WAIT_TIMEOUT_MS;
  Serial.println("Waiting a client connection...");
}

void loop()
{
  if (!deviceConnected && oldDeviceConnected)
  {
    delay(100);
    startAdvertising();
    oldDeviceConnected = false;
    dataSent = false;
    //sleepDeadline = millis() + BLE_WAIT_TIMEOUT_MS;
  }

  if (deviceConnected && !oldDeviceConnected)
  {
    oldDeviceConnected = true;
    dataSent = false;
    //sleepDeadline = millis() + BLE_WAIT_TIMEOUT_MS;
  }

  if (keyPressed)
  {
    // 中断函数只设置标志，消抖和文件操作放到 loop() 中执行。
    delay(30);

    if (digitalRead(BUTTON_PIN) == LOW)
    {
      Serial.println("按键按下");
      while (digitalRead(BUTTON_PIN) == LOW)
        delay(1);

      writeFile();
      dataSent = false;
      //sleepDeadline = millis() + BLE_WAIT_TIMEOUT_MS;
      Serial.println("按键释放");
    }
    keyPressed = false;
  }

  if (deviceConnected && !dataSent)
  {
    dataSent = sendAllFiles();
    //if (dataSent)
      //sleepDeadline = millis() + SEND_FINISH_DELAY_MS;
  }
/*
  if (!deviceConnected && deadlineReached(sleepDeadline))
  {
    enterDeepSleep();
  }

  if (deviceConnected && dataSent && deadlineReached(sleepDeadline))
  {
    enterDeepSleep();
  }
*/
  delay(10);
}