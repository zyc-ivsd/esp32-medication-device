#include <SPIFFS.h>
#include <Preferences.h>
#include <vector>
#include <algorithm>
#include <time.h>

// Raw prototype files are retained even after COMMIT. Never format on send or
// mount failure. The formal binary protocol will define scoped reclamation.
const size_t MAX_SYNC_FILES = 256;
const uint32_t ACK_TIMEOUT_MS = 1500;
const uint8_t MAX_RETRIES = 3;
bool storageReady = false;
Preferences fileCounter;
bool counterReady = false;
String stableDeviceId;
String syncToken;
std::vector<String> syncFiles;
size_t syncIndex = 0;
bool syncActive = false;
bool waitingStart = false;
bool waitingCommit = false;
bool helloPending = false;
bool helloReady = false;
String lastFrame;
String completedToken;
uint32_t lastFrameAt = 0;
uint8_t retryCount = 0;
uint32_t syncGeneration = 0;

uint16_t textCrc(const String &body) {
  uint16_t crc = 0xffff;
  for (size_t i = 0; i < body.length(); ++i) {
    crc ^= (uint16_t)(uint8_t)body[i] << 8;
    for (uint8_t bit = 0; bit < 8; ++bit)
      crc = (crc & 0x8000) ? (crc << 1) ^ 0x1021 : crc << 1;
  }
  return crc;
}
bool sendFrame(const String &body) {
  if (!notifyReady()) return false;
  const uint32_t generation = connectionGeneration;
  char crc[5];
  snprintf(crc, sizeof(crc), "%04x", textCrc(body));
  const String frame = "\n" + body + "|" + String(crc) + "\n";
  for (size_t offset = 0; offset < frame.length(); offset += PACKET_SIZE) {
    if (!notifyReady() || generation != connectionGeneration) return false;
    const size_t length = std::min((size_t)PACKET_SIZE, frame.length() - offset);
    pCharacteristic->setValue((uint8_t *)frame.c_str() + offset, length);
    pCharacteristic->notify();
    delay(20);
  }
  Serial.println("NOTIFY " + body);
  return true;
}
void resetSync() {
  syncActive = false;
  waitingStart = false;
  waitingCommit = false;
  helloPending = false;
  helloReady = false;
  syncFiles.clear();
  syncToken = "";
  completedToken = "";
  lastFrame = "";
}
void syncError(const String &reason) {
  sendFrame("ERROR|" + syncToken + "|" + reason);
  syncActive = false;
  waitingStart = false;
  waitingCommit = false;
  Serial.println("SYNC_ERROR " + reason + ": files retained");
}
bool writeFile() {
  if (!storageReady || !counterReady) return false;
  struct tm timeinfo;
  getDeviceLocalTime(timeinfo);
  char timeString[32];
  strftime(timeString, sizeof(timeString), "%Y-%m-%d_%H-%M-%S", &timeinfo);
  uint32_t counter = fileCounter.getUInt("next", 1);
  String fileName;
  // Never reuse a filename, including clock corrections and same-second presses.
  do {
    if (counter == UINT32_MAX) { Serial.println("FILE_COUNTER_EXHAUSTED"); return false; }
    fileName = "/data_" + String(timeString) + "_" + String(counter++) + ".txt";
  } while (SPIFFS.exists(fileName));
  if (fileCounter.putUInt("next", counter) != sizeof(uint32_t)) return false;
  File file = SPIFFS.open(fileName, FILE_WRITE);
  if (!file) { Serial.println("WRITE_FAILED: storage may be full"); return false; }
  const String line = String(timeString) + "\n";
  const size_t written = file.print(line);
  file.flush();
  file.close();
  if (written != line.length()) { Serial.println("WRITE_INCOMPLETE " + fileName); return false; }
  if (clockValid && !saveTimeToNVS()) Serial.println("CLOCK_SNAPSHOT_FAILED: file is still retained");
  if (!clockSynced) Serial.println("RECORD_TIME_UNCALIBRATED: raw text only");
  Serial.println("CREATED " + fileName);
  return true;
}
bool validTimestamp(const String &value) {
  if (value.length() != 19) return false;
  for (size_t i = 0; i < 19; ++i) {
    const char expected = (i == 4 || i == 7 || i == 13 || i == 16) ? '-' : (i == 10 ? '_' : 0);
    if (expected ? value[i] != expected : !isDigit(value[i])) return false;
  }
  return true;
}
void sendNext() {
  if (!syncActive || syncGeneration != connectionGeneration) return;
  if (syncIndex == syncFiles.size()) {
    waitingCommit = true;
    lastFrame = "END|" + syncToken + "|" + String(syncFiles.size());
  } else {
    File file = SPIFFS.open("/" + syncFiles[syncIndex], FILE_READ);
    if (!file) { syncError("READ_FAILED"); return; }
    if (file.size() < 19 || file.size() > 21) { file.close(); syncError("BAD_FILE"); return; }
    const String raw = file.readStringUntil('\n');
    const bool extra = file.available();
    file.close();
    String value = raw;
    value.trim();
    if (extra || !validTimestamp(value)) { syncError("BAD_FILE"); return; }
    lastFrame = "R|" + syncToken + "|" + String(syncIndex) + "|" + syncFiles[syncIndex] + "|" + value;
  }
  retryCount = 0;
  sendFrame(lastFrame);
  lastFrameAt = millis();
}
bool validToken(const String &token) {
  if (token.length() != 8) return false;
  for (size_t i = 0; i < 8; ++i) if (!isHexadecimalDigit(token[i])) return false;
  return true;
}
void beginSync(const String &token) {
  syncToken = token;
  completedToken = "";
  syncFiles.clear();
  syncActive = false;
  waitingCommit = false;
  waitingStart = false;
  if (!storageReady) { syncError("STORAGE_UNAVAILABLE"); return; }
  File root = SPIFFS.open("/");
  if (!root || !root.isDirectory()) { syncError("STORAGE_UNAVAILABLE"); return; }
  File file = root.openNextFile();
  while (file) {
    String name = file.name();
    if (name.startsWith("/")) name.remove(0, 1);
    if (!file.isDirectory() && name.startsWith("data_") && name.endsWith(".txt")) {
      syncFiles.push_back(name);
      if (syncFiles.size() > MAX_SYNC_FILES) {
        file.close(); root.close(); syncError("TOO_MANY_FILES"); return;
      }
    }
    file.close();
    file = root.openNextFile();
  }
  root.close();
  std::sort(syncFiles.begin(), syncFiles.end(), [](const String &a, const String &b) { return a.compareTo(b) < 0; });
  syncGeneration = connectionGeneration;
  syncIndex = 0;
  syncActive = true;
  waitingStart = true;
  lastFrame = "BEGIN|" + syncToken + "|" + String(syncFiles.size());
  retryCount = 0;
  sendFrame(lastFrame);
  lastFrameAt = millis();
}
void handleCommand(const String &command) {
  Serial.println("CONTROL " + command);
  if (command == "HELLO") {
    helloPending = true;
    if (!notifyReady()) Serial.println("HELLO_WAIT_NOTIFY: phone has not enabled notifications yet");
    return;
  }
  if (!helloReady || !notifyReady()) return;
  if (command.startsWith("TIME|")) {
    PhoneClockCommand clock;
    if (!parsePhoneClock(command.c_str(), clock)) { sendFrame("TIME_ERR|BAD_TIME"); return; }
    if (syncActive) { sendFrame("TIME_ERR|BUSY"); return; }
    static String lastClockCommand;
    static uint32_t clockGeneration = UINT32_MAX;
    // Lost acknowledgments retry the same command without moving the clock back.
    if (clockGeneration != connectionGeneration || lastClockCommand != command) {
      if (!setPhoneTime(clock.utc, clock.offset)) { sendFrame("TIME_ERR|CLOCK_STORAGE"); return; }
      lastClockCommand = command;
      clockGeneration = connectionGeneration;
      printTime();
    }
    sendFrame("TIME_OK|" + command.substring(5));
  } else if (command.startsWith("SYNC_REQ|")) {
    const String token = command.substring(9);
    if (validToken(token)) beginSync(token);
  } else if (syncActive && waitingStart && command == "START|" + syncToken) {
    waitingStart = false;
    sendNext();
  } else if (syncActive && !waitingStart && !waitingCommit && command == "ACK|" + syncToken + "|" + String(syncIndex)) {
    ++syncIndex;
    sendNext();
  } else if (command.startsWith("COMMIT|")) {
    const String token = command.substring(7);
    if (syncActive && waitingCommit && token == syncToken) {
      // Prototype retention is intentional. COMMIT confirms receipt, and does
      // not authorize formatting the device or removing unrelated/new files.
      completedToken = token;
      syncActive = false;
      waitingCommit = false;
      sendFrame("DONE|" + token);
      Serial.println("COMPLETED: all files retained");
    } else if (validToken(token) && token == completedToken) {
      sendFrame("DONE|" + token);
    }
  }
}
void serviceSync() {
  static uint32_t observedGeneration = UINT32_MAX;
  if (observedGeneration != connectionGeneration) {
    observedGeneration = connectionGeneration;
    resetSync();
  }
  ControlCommand command;
  while (xQueueReceive(commandQueue, &command, 0) == pdTRUE) {
    if (deviceConnected && command.generation == connectionGeneration)
      handleCommand(String(command.text));
  }
  if (helloPending && notifyReady()) {
    // A disconnect or subscription change can occur between frame fragments.
    // Keep HELLO pending until the complete READY has actually been attempted.
    if (sendFrame("READY|" + stableDeviceId + "|P01|TIME1")) {
      helloPending = false;
      helloReady = true;
    }
  }
  if (syncActive && deviceConnected && millis() - lastFrameAt >= ACK_TIMEOUT_MS) {
    if (retryCount++ >= MAX_RETRIES) { syncError("ACK_TIMEOUT"); return; }
    sendFrame(lastFrame);
    lastFrameAt = millis();
  }
}
