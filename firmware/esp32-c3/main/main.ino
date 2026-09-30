// 注意：time.ino 必须最先包含，其他模块要用到它提供的函数
#include <../components/time/time.ino>
#include <../components/ble/ble.ino>
#include <../components/flash/flash.ino>
#include <../components/deepsleep/deepsleep.ino>
#include <Arduino.h>

#include <time.h>
#include <sys/time.h>

// ESP32-C3 的 RTC GPIO 为 GPIO0~GPIO5，这里使用 GPIO4 进行轻睡唤醒。
// 按键接线：GPIO4 -- 按键 -- GND。
#define BUTTON_PIN 4

// 轻睡眠时保持 GPIO4 的内部上拉（esp_light_sleep_start 会重新加载 pad 配置）
static void keepButtonPullupDuringSleep()
{
    gpio_pullup_en((gpio_num_t)BUTTON_PIN);
    gpio_pulldown_dis((gpio_num_t)BUTTON_PIN);
}

void IRAM_ATTR keyISR()
{
    keyPressed = true;
}

// BLE 初始化：首次启动和每次轻睡唤醒后都调用
// （轻睡眠期间蓝牙控制器断电，唤醒后重建服务并重新广播）
static void setupBLE()
{
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
}

// 按键中断挂载/摘除（睡前摘除，唤醒后重新挂载）
static void attachButtonInterrupt()
{
    attachInterrupt(digitalPinToInterrupt(BUTTON_PIN), keyISR, FALLING);
}

static void detachButtonInterrupt()
{
    detachInterrupt(digitalPinToInterrupt(BUTTON_PIN));
}

void setup()
{
    Serial.begin(115200);
    delay(500);

    Serial.println();
    Serial.println("ESP32-C3 启动");

    // ---- 按键：上拉输入 + 下降沿中断 ----
    pinMode(BUTTON_PIN, INPUT_PULLUP);
    keepButtonPullupDuringSleep();

    if (!SPIFFS.begin(true))
    {
        Serial.println("SPIFFS Mount Failed");
        return;
    }
    Serial.println("SPIFFS Mounted");

    // ---- 时钟：先尝试从 NVS 恢复，失败则用默认手动时间 ----
    restoreTimeFromNVS();
    if (!isTimeValid())
    {
        Serial.println("NVS 无有效时钟，使用默认时间（等待手机校准）");
        setManualTime(2026, 8, 29, 22, 30, 0);
    }
    printTime();

    // 开机/唤醒时不再自动写记录，只有按键触发才记录数据

    // ---- BLE（含时间校准服务）----
    setupBLE();

    // ---- 按键中断：在 BLE 初始化之后再挂，避免蓝牙内部 GPIO 校准破坏配置 ----
    attachButtonInterrupt();

    refreshSleepDeadline();
    Serial.println("Waiting a client connection...");
}

void loop()
{
    // ---- BLE 连接/断开状态切换 ----
    if (!deviceConnected && oldDeviceConnected)
    {
        delay(100);
        startAdvertising();
        oldDeviceConnected = false;
        dataSent = false;
        refreshSleepDeadline();
    }

    if (deviceConnected && !oldDeviceConnected)
    {
        oldDeviceConnected = true;
        dataSent = false;
    }

    // ---- 按键处理（中断只置标志，消抖和文件操作放这里） ----
    if (keyPressed)
    {
        delay(30); // 消抖

        if (digitalRead(BUTTON_PIN) == LOW)
        {
            Serial.println("按键按下");
            while (digitalRead(BUTTON_PIN) == LOW)
                delay(1); // 等待释放

            writeFile();
            dataSent = false;
            Serial.println("按键释放");
        }
        keyPressed = false;
    }

    // ---- 数据发送 ----
    if (deviceConnected && !dataSent)
    {
        dataSent = sendAllFiles();
    }

    // ---- 无蓝牙连接超时 → 轻度睡眠（GPIO4 按键 / 串口可唤醒） ----
    if (shouldEnterLightSleep())
    {
        detachButtonInterrupt();
        BLEDevice::deinit(false); // 关闭蓝牙再睡，省电且唤醒后状态干净
        enterLightSleep();

        // 走到这里说明已被唤醒：恢复外设、重建蓝牙、挂回中断
        // （按键唤醒时 enterLightSleep 已置 keyPressed，由上面的按键逻辑处理）
        Serial.println("轻睡眠唤醒，恢复运行");
        keepButtonPullupDuringSleep();
        setupBLE();
        attachButtonInterrupt();
        refreshSleepDeadline();

        printTime(); // 打印当前时间，确认轻睡期间时钟持续走时
    }

    delay(10);
}
