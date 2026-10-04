#include <SPIFFS.h>
#include <Preferences.h>
#include <esp_system.h>
#include <vector>
#include <algorithm>
#include <time.h>
#include "../log/log.h"
#include "archive_plan.h"

// Raw prototype files: `data_*` is the active, transferable area. After a
// committed round the transferred files are renamed into one of two rolling
// archive groups, `DA_*` or `DB_*`. Only `data_*` is ever transferred. When the
// current group reaches ARCHIVE_GROUP_SIZE the next group becomes current; if
// that group already holds a full set it is deleted first, so the device keeps
// at most two archive generations and never grows without bound. Never format
// on send or mount failure.
const size_t MAX_SYNC_FILES = 256;
const uint32_t ACK_TIMEOUT_MS = 1500;
const uint8_t MAX_RETRIES = 3;
// Files are transferred in rounds of at most this many. The wire protocol is
// unchanged: each round is a normal REQ..DONE cycle with its own token, exactly
// as before paging existed. What changes is only that after a DONE the device
// checks for leftovers and starts the *next* independent round automatically,
// so a 25-file backlog becomes three ordinary rounds of 10, 10 and 5.
const size_t ROUND_SIZE = 10;
// The file counter runs the full uint32 range and wraps back to zero after the
// maximum. Ten digits is the longest the name gets
// ("/data_ffff_4294967295.txt" = 25 bytes), still inside the SPIFFS 31-byte
// object-name limit, so no extra headroom is needed. Reusing an ordinal is safe
// because writeFile probes SPIFFS.exists and skips names still in use.
const uint32_t FILE_COUNTER_MAX = UINT32_MAX;
bool storageReady = false;
Preferences fileCounter;
Preferences archivePrefs;
bool counterReady = false;
bool archiveReady = false;
String stableDeviceId;
String syncToken;
std::vector<String> syncFiles;
size_t syncIndex = 0;
bool syncActive = false;
bool waitingStart = false;
bool waitingCommit = false;
bool helloPending = false;
bool helloReady = false;
// Device-initiated transfer request state. REQ is sent after the clock is
// calibrated (or immediately for legacy firmware), and after every button
// record while connected and subscribed. A pending flag covers a button press
// that happens while no phone is subscribed; it is flushed on the next REQ
// opportunity instead of being silently dropped.
bool syncRequestSent = false;
String syncRequestToken;
size_t syncRequestCount = 0;
bool pendingSyncRequest = false;
bool clockCalibrated = false;
String lastFrame;
String completedToken;
uint32_t lastFrameAt = 0;
uint8_t retryCount = 0;
uint32_t syncGeneration = 0;
uint32_t lastRequestAt = 0;
const uint32_t REQUEST_TIMEOUT_MS = 1500;

// Rolling archive state. `archiveGroup` is "DA" or "DB"; `archiveSeq` is how
// many files the current group already holds (0..ARCHIVE_GROUP_SIZE). Both are
// persisted so a reboot resumes the same generation instead of overwriting it.
String archiveGroup = "DA";
size_t archiveSeq = 0;

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
  // Every frame logs here, so this is the most frequent print in the firmware;
  // LOGLN drops it when no monitor is draining the UART instead of stalling.
  LOGLN("NOTIFY " + body);
  return true;
}
void resetSync() {
  syncActive = false;
  waitingStart = false;
  waitingCommit = false;
  helloPending = false;
  helloReady = false;
  // A REQ is invalidated by a disconnect/subscription change; the firmware will
  // offer it again once the link is ready. Do not clear pendingSyncRequest so a
  // button press during the outage is still delivered.
  syncRequestSent = false;
  syncRequestToken = "";
  syncRequestCount = 0;
  clockCalibrated = false;
  syncFiles.clear();
  syncIndex = 0;
  syncToken = "";
  completedToken = "";
  lastFrame = "";
}
void syncError(const String &reason) {
  sendFrame("ERROR|" + syncToken + "|" + reason);
  syncActive = false;
  waitingStart = false;
  waitingCommit = false;
  LOGLN("SYNC_ERROR " + reason + ": files retained");
}
bool writeFile() {
  if (!storageReady || !counterReady) return false;
  // The device stores UTC only. The file CONTENT holds the full 16-hex-digit
  // Unix seconds (the authoritative value the phone parses). The file NAME only
  // carries the last four hex digits plus the counter, because SPIFFS caps
  // object names at 31 bytes and the full stamp would leave room for barely
  // 10k files. The short stamp is for human readability; the content is truth.
  const uint64_t utc = static_cast<uint64_t>(time(nullptr));
  char hex[24];
  snprintf(hex, sizeof(hex), "%016llx", static_cast<unsigned long long>(utc));
  uint32_t counter = fileCounter.getUInt("next", 0);
  String fileName;
  // The counter runs the full uint32 range and wraps back to 0 after the
  // maximum, so names stay short enough for SPIFFS. Because the 4-hex stamp can
  // repeat within the same second, keep probing until a free name is found.
  do {
    counter = wrapCounter(counter, FILE_COUNTER_MAX);
    char bare[40];
    formatDataName(bare, sizeof(bare), hex, counter);
    // Advance explicitly so the wrap is visible instead of relying on the
    // unsigned overflow that ++ would perform at UINT32_MAX.
    counter = (counter == FILE_COUNTER_MAX) ? 0 : counter + 1;
    fileName = "/" + String(bare);
  } while (SPIFFS.exists(fileName));
  if (fileCounter.putUInt("next", counter) != sizeof(uint32_t)) return false;
  File file = SPIFFS.open(fileName, FILE_WRITE);
  if (!file) { LOGLN("WRITE_FAILED: storage may be full"); return false; }
  // Always write the FULL 16-hex stamp, regardless of the shortened file name.
  const String line = String(hex) + "\n";
  const size_t written = file.print(line);
  file.flush();
  file.close();
  if (written != line.length()) { LOGLN("WRITE_INCOMPLETE " + fileName); return false; }
  if (clockValid && !saveTimeToNVS()) LOGLN("CLOCK_SNAPSHOT_FAILED: file is still retained");
  if (!clockSynced) LOGLN("RECORD_TIME_UNCALIBRATED: raw text only");
  LOGLN("CREATED " + fileName);
  // The device owns sync initiation: a new file is offered to the phone at the
  // next opportunity. If nobody is subscribed it stays pending until the next
  // handshake, so the record is never stranded.
  pendingSyncRequest = true;
  return true;
}
// The raw record is exactly 16 lowercase hex digits of UTC Unix seconds.
bool validTimestamp(const String &value) {
  if (value.length() != 16) return false;
  for (size_t i = 0; i < 16; ++i) if (!isHexadecimalDigit(value[i])) return false;
  return true;
}

// Persists the rolling archive cursor. A failed write leaves the in-memory
// values in place for this boot; the next successful archive attempt retries.
void saveArchiveState() {
  if (!archiveReady) return;
  if (archivePrefs.putString("group", archiveGroup) == 0 ||
      archivePrefs.putUInt("seq", archiveSeq) != sizeof(uint32_t)) {
    LOGLN("ARCHIVE_STATE_FAILED: continuing with in-memory state");
  }
}

void loadArchiveState() {
  archiveReady = archivePrefs.begin("proto-archive", false);
  if (!archiveReady) {
    LOGLN("ARCHIVE_NVS_UNAVAILABLE: archives start empty each boot");
    archiveGroup = "DA";
    archiveSeq = 0;
    return;
  }
  const String group = archivePrefs.getString("group", "DA");
  const uint32_t seq = archivePrefs.getUInt("seq", 0);
  archiveGroup = (group == "DB") ? "DB" : "DA";
  archiveSeq = (seq <= ARCHIVE_GROUP_SIZE) ? seq : ARCHIVE_GROUP_SIZE;
  LOG("ARCHIVE_STATE group=%s seq=%u\n", archiveGroup.c_str(),
                static_cast<unsigned>(archiveSeq));
}

// True when the name is an archive entry (DA_/DB_), never transferred.
bool isArchiveName(const String &name) {
  return name.startsWith("DA_") || name.startsWith("DB_");
}

// Deletes every file in one archive group. Used when the rolling cursor wraps
// back onto a group that still holds a full generation.
bool clearArchiveGroup(const char *group) {
  const String prefix = String(group) + "_";
  File root = SPIFFS.open("/");
  if (!root || !root.isDirectory()) return false;
  std::vector<String> doomed;
  File file = root.openNextFile();
  while (file) {
    String name = file.name();
    if (name.startsWith("/")) name.remove(0, 1);
    if (!file.isDirectory() && name.startsWith(prefix) && name.endsWith(".txt")) {
      doomed.push_back(name);
    }
    file.close();
    file = root.openNextFile();
  }
  root.close();
  size_t removed = 0;
  String failedName;
  for (const String &name : doomed) {
    char path[64];
    toSpiffsPath(path, sizeof(path), name.c_str());
    if (SPIFFS.remove(path)) ++removed;
    else if (failedName.isEmpty()) failedName = name;
  }
  if (!failedName.isEmpty()) {
    LOG("ARCHIVE_CLEAR_FAILED %s (%u/%u removed)\n", failedName.c_str(),
                  static_cast<unsigned>(removed), static_cast<unsigned>(doomed.size()));
    return false;
  }
  LOG("ARCHIVE_CLEARED %s (%u file(s))\n", group,
                static_cast<unsigned>(removed));
  return true;
}

// Renames one just-transferred file into the current archive group. The 16-hex
// UTC stamp is preserved; the trailing ordinal becomes the group-local sequence
// number so DA_/DB_ entries read as DA_<hex>_<1..50>.txt.
bool archiveTransferredFile(const String &dataName, size_t ordinal) {
  // The transferable name is "data_" + 4 hex + "_" + counter + ".txt". Those
  // four digits are only a readable hint, so read the file content to recover
  // the full 16-hex stamp for the archive name; the archive has room for it
  // ("/DA_000000006ac2b917_50.txt" is 27 of the 31 bytes SPIFFS allows) and a
  // full stamp keeps archive names unique regardless of the short data_ name.
  if (dataName.length() < 5 + 4 + 1 + 1 + 4 || !dataName.startsWith("data_")) {
    return false;
  }
  char sourcePath[64];
  toSpiffsPath(sourcePath, sizeof(sourcePath), dataName.c_str());
  File file = SPIFFS.open(sourcePath, FILE_READ);
  if (!file) return false;
  String stamp = file.readStringUntil('\n');
  file.close();
  stamp.trim();
  if (!validTimestamp(stamp)) {
    LOG("ARCHIVE_BAD_CONTENT %s\n", dataName.c_str());
    return false;
  }
  char bare[48];
  formatArchiveName(bare, sizeof(bare), archiveGroup.c_str(), stamp.c_str(), ordinal);
  // SPIFFS demands a leading slash on BOTH rename paths; going through
  // toSpiffsPath keeps the rule in one tested place.
  char targetPath[64];
  toSpiffsPath(targetPath, sizeof(targetPath), bare);
  // Some Arduino-ESP32 SPIFFS builds fail the rename when the destination
  // already exists instead of replacing it. Ordinals should be unique, but a
  // stale file from a failed group clear would collide, so drop it first.
  if (SPIFFS.exists(targetPath) && !SPIFFS.remove(targetPath)) {
    LOG("ARCHIVE_TARGET_BUSY %s\n", targetPath);
    return false;
  }
  if (!SPIFFS.rename(sourcePath, targetPath)) {
    LOG("ARCHIVE_RENAME_FAILED %s -> %s\n", sourcePath, targetPath);
    return false;
  }
  return true;
}

// Rolls `syncFiles` into the archive after a committed round. Exactly the files
// that were transferred this round are archived (not "the oldest"): the phone
// confirmed them, so they are the ones being demoted out of the transfer area.
// When the group fills, the cursor moves to the other group and deletes it
// first if it still holds a generation, so at most two archive generations
// exist. Files that fail to rename stay in `data_` and are retried next round.
// Archives every file in the round just committed. Called once per DONE, so the
// wire protocol stays a plain single-token round; paging happens by starting a
// fresh round, not by splitting one. Returns how many files were archived.
size_t archiveTransferredFiles() {
  if (syncFiles.empty()) return 0;
  size_t archived = 0;
  for (const String &name : syncFiles) {
    ArchiveCursor cursor = {archiveGroup.c_str(), archiveSeq};
    const ArchiveStep step = planArchiveStep(cursor, ARCHIVE_GROUP_SIZE);
    if (step.switched) {
      // The two-slot scheme keeps only the newest two generations; the incoming
      // group is wiped before reuse even if never synced. The team accepted it.
      clearArchiveGroup(step.cursor.group);
    }
    if (!archiveTransferredFile(name, step.cursor.seq)) {
      // Leave the file in data_ so a later round can retry it.
      continue;
    }
    archiveGroup = step.cursor.group;
    archiveSeq = step.cursor.seq;
    saveArchiveState();
    ++archived;
  }
  LOG("ARCHIVED %u file(s) into %s (seq=%u)\n",
                static_cast<unsigned>(archived), archiveGroup.c_str(),
                static_cast<unsigned>(archiveSeq));
  return archived;
}

void sendNext() {
  if (!syncActive || syncGeneration != connectionGeneration) return;
  if (syncIndex >= syncFiles.size()) {
    waitingCommit = true;
    lastFrame = "END|" + syncToken + "|" + String(syncFiles.size());
  } else {
    File file = SPIFFS.open("/" + syncFiles[syncIndex], FILE_READ);
    if (!file) { syncError("READ_FAILED"); return; }
    // 16 hex digits plus a newline.
    if (file.size() < 16 || file.size() > 18) { file.close(); syncError("BAD_FILE"); return; }
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

// Scans SPIFFS for transferable `data_*` files only. `DA_*`/`DB_*` archives are
// deliberately skipped so a transferred round is never offered again. Returns
// false and fills `reason` on a storage error or the 256-file prototype
// ceiling. On success `files` is sorted so index order is deterministic.
bool collectFiles(std::vector<String> &files, const char *&reason) {
  files.clear();
  reason = nullptr;
  if (!storageReady) { reason = "STORAGE_UNAVAILABLE"; return false; }
  File root = SPIFFS.open("/");
  if (!root || !root.isDirectory()) { reason = "STORAGE_UNAVAILABLE"; return false; }
  File file = root.openNextFile();
  while (file) {
    String name = file.name();
    if (name.startsWith("/")) name.remove(0, 1);
    // `data_*` is transferable; DA_/DB_ archives are explicitly skipped so a
    // committed round is never offered a second time.
    if (!file.isDirectory() && !isArchiveName(name) &&
        name.startsWith("data_") && name.endsWith(".txt")) {
      files.push_back(name);
      if (files.size() > MAX_SYNC_FILES) {
        file.close(); root.close(); reason = "TOO_MANY_FILES"; return false;
      }
    }
    file.close();
    file = root.openNextFile();
  }
  root.close();
  std::sort(files.begin(), files.end(), [](const String &a, const String &b) { return a.compareTo(b) < 0; });
  return true;
}

// Generates a fresh per-round token from the hardware RNG. esp_random returns 0
// only if the RNG below is not ready; the system entropy source is seeded at
// boot, so fall back to a clock/RNG mix rather than sending an all-zero token.
String generateToken() {
  uint32_t value = esp_random();
  if (value == 0) value = (uint32_t)micros() ^ (uint32_t)millis() ^ (uint32_t)ESP.getEfuseMac();
  char token[9];
  snprintf(token, sizeof(token), "%08lx", static_cast<unsigned long>(value));
  return String(token);
}

// Device-initiated transfer request. Only sent when the phone is connected,
// subscribed, has completed the HELLO/READY handshake, and the clock is settled
// (calibrated, or unsupported on legacy firmware). `count` is this round's file
// count, capped at ROUND_SIZE; when more remain the device sends a fresh REQ
// after this round's DONE, so the wire protocol itself never changes.
bool sendSyncRequest() {
  std::vector<String> files;
  const char *reason = nullptr;
  if (!collectFiles(files, reason)) {
    // Storage is not usable. Report it once and keep the request pending so a
    // later button press or reconnect can retry after the fault is cleared.
    pendingSyncRequest = false;
    LOG("REQ_FAILED %s: files retained\n", reason);
    return false;
  }
  if (files.empty()) {
    LOGLN("REQ_SKIP: no files to transfer");
    pendingSyncRequest = false;
    return false;
  }
  syncRequestToken = generateToken();
  syncRequestCount = std::min(ROUND_SIZE, files.size());
  syncRequestSent = true;
  if (!sendFrame("REQ|" + syncRequestToken + "|" + String(syncRequestCount))) {
    syncRequestSent = false;
    return false;
  }
  pendingSyncRequest = false;
  lastRequestAt = millis();
  LOG("REQ_SENT %s count=%u total=%u\n", syncRequestToken.c_str(),
                static_cast<unsigned>(syncRequestCount),
                static_cast<unsigned>(files.size()));
  return true;
}

// Called from the main loop. Decides whether the device may offer a transfer
// now, so REQ is never sent mid-sync, before calibration, or without a
// listening subscriber.
bool readyForSyncRequest() {
  return deviceConnected && notifyReady() && helloReady && clockCalibrated &&
         !syncActive && !syncRequestSent;
}

void requestSyncIfNeeded() {
  if (!readyForSyncRequest()) return;
  if (!pendingSyncRequest) return;
  sendSyncRequest();
}

void beginSync(const String &token) {
  syncToken = token;
  completedToken = "";
  syncFiles.clear();
  syncActive = false;
  waitingCommit = false;
  waitingStart = false;
  const char *reason = nullptr;
  if (!collectFiles(syncFiles, reason)) {
    // The app already consented; answer with the real token so it can surface
    // the reason instead of timing out.
    syncError(reason);
    return;
  }
  // This round carries at most ROUND_SIZE files. Anything left stays in data_
  // and is offered by the next automatically started round after DONE.
  if (syncFiles.size() > ROUND_SIZE) syncFiles.resize(ROUND_SIZE);
  syncGeneration = connectionGeneration;
  syncIndex = 0;
  syncActive = true;
  waitingStart = true;
  syncRequestSent = false;
  pendingSyncRequest = false;
  lastFrame = "BEGIN|" + syncToken + "|" + String(syncFiles.size());
  retryCount = 0;
  sendFrame(lastFrame);
  lastFrameAt = millis();
}
void handleCommand(const String &command) {
  LOGLN("CONTROL " + command);
  if (command == "HELLO") {
    helloPending = true;
    if (!notifyReady()) LOGLN("HELLO_WAIT_NOTIFY: phone has not enabled notifications yet");
    return;
  }
  if (!helloReady || !notifyReady()) return;
  if (command.startsWith("TM|")) {
    PhoneClockCommand clock;
    if (!parsePhoneClock(command.c_str(), clock)) { sendFrame("TER|BAD_TIME"); return; }
    if (syncActive) { sendFrame("TER|BUSY"); return; }
    static String lastClockCommand;
    static uint32_t clockGeneration = UINT32_MAX;
    // Lost acknowledgments retry the same command without moving the clock back.
    if (clockGeneration != connectionGeneration || lastClockCommand != command) {
      if (!setPhoneTime(clock.utc)) { sendFrame("TER|CLOCK_STORAGE"); return; }
      lastClockCommand = command;
      clockGeneration = connectionGeneration;
      printTime();
    }
    clockCalibrated = true;
    sendFrame("TOK|" + command.substring(3));
    // The phone's clock is now trustworthy; offer the retained files. The app
    // replies SYNC_REQ with this same token to start the snapshot.
    pendingSyncRequest = true;
    requestSyncIfNeeded();
  } else if (command.startsWith("SYNC_REQ|")) {
    const String token = command.substring(9);
    // Only accept the app's consent for the REQ this device actually sent.
    if (syncRequestSent && validToken(token) && token == syncRequestToken) {
      beginSync(token);
    } else {
      LOGLN("SYNC_REQ_IGNORED: no matching outstanding REQ");
    }
  } else if (syncActive && waitingStart && command == "START|" + syncToken) {
    waitingStart = false;
    sendNext();
  } else if (syncActive && !waitingStart && !waitingCommit && command == "ACK|" + syncToken + "|" + String(syncIndex)) {
    ++syncIndex;
    sendNext();
  } else if (command.startsWith("COMMIT|")) {
    const String token = command.substring(7);
    if (syncActive && waitingCommit && token == syncToken) {
      // COMMIT proves this round's records are acknowledged and durable. Archive
      // them, then acknowledge with DONE exactly as before. Paging is invisible
      // on the wire: if files remain, the main loop starts a brand-new round
      // (new token, fresh REQ) rather than extending this one.
      const size_t archived = archiveTransferredFiles();
      completedToken = token;
      syncActive = false;
      waitingCommit = false;
      sendFrame("DONE|" + token);
      // Ask for another round only when this round actually freed files, so a
      // storage fault that blocks every rename cannot spin on REQ forever.
      pendingSyncRequest = archived > 0;
      LOGLN("COMPLETED: transferred files archived");
    } else if (validToken(token) && token == completedToken) {
      // A retried COMMIT after a lost DONE: the round is already archived, but
      // the phone still needs its acknowledgement. No second archive pass.
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
      // Legacy-only path: firmware without TIME1 never sets clockCalibrated, so
      // treat a completed handshake as permission to offer files immediately.
      // TIME1 firmware sets clockCalibrated from TIME_OK instead.
      if (!clockCalibrated) {
        pendingSyncRequest = true;
        requestSyncIfNeeded();
      }
    }
  }
  // Offer a pending transfer as soon as the link becomes eligible (this also
  // covers a button press made while the phone was away).
  requestSyncIfNeeded();
  // Retry an unanswered REQ once per REQUEST_TIMEOUT_MS so a lost consent frame
  // does not strand the files until the next button press or reconnect.
  if (syncRequestSent && !syncActive && deviceConnected && notifyReady() &&
      millis() - lastRequestAt >= REQUEST_TIMEOUT_MS) {
    if (!sendFrame("REQ|" + syncRequestToken + "|" + String(syncRequestCount))) {
      syncRequestSent = false;
    } else {
      lastRequestAt = millis();
    }
  }
  if (syncActive && deviceConnected && millis() - lastFrameAt >= ACK_TIMEOUT_MS) {
    if (retryCount++ >= MAX_RETRIES) { syncError("ACK_TIMEOUT"); return; }
    sendFrame(lastFrame);
    lastFrameAt = millis();
  }
}
