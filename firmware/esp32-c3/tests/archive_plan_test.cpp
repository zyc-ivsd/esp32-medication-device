#include "../components/flash/archive_plan.h"
#include <assert.h>
#include <stdio.h>

// Simulates the firmware's rolling cursor across many archived files and
// asserts the DA/DB generation sequence the team specified:
//   1-50   -> DA_1..DA_50
//   51-100 -> DB_1..DB_50 (DA kept)
//   101    -> DA cleared, DA_1
//   151    -> DB cleared, DB_1
int main() {
  ArchiveCursor cursor = {"DA", 0};
  int clears = 0;
  char clearedGroups[8][4] = {};
  size_t clearedCount = 0;

  struct Entry { size_t ordinal; const char *group; };
  Entry first = {0, nullptr}, last = {0, nullptr};
  Entry at101 = {0, nullptr}, at151 = {0, nullptr};

  for (size_t i = 1; i <= 200; ++i) {
    const ArchiveStep step = planArchiveStep(cursor, ARCHIVE_GROUP_SIZE);
    if (step.switched) {
      ++clears;
      if (clearedCount < 8) {
        snprintf(clearedGroups[clearedCount], sizeof(clearedGroups[0]), "%s",
                 step.cursor.group);
        ++clearedCount;
      }
    }
    cursor = step.cursor;
    if (i == 1) first = {cursor.seq, cursor.group};
    if (i == 50) last = {cursor.seq, cursor.group};
    if (i == 101) at101 = {cursor.seq, cursor.group};
    if (i == 151) at151 = {cursor.seq, cursor.group};
    assert(cursor.seq >= 1 && cursor.seq <= ARCHIVE_GROUP_SIZE);
  }

  assert(first.ordinal == 1 && strcmp(first.group, "DA") == 0);
  assert(last.ordinal == 50 && strcmp(last.group, "DA") == 0);
  // 101 is the first file of the second DA generation after DA was reclaimed.
  assert(at101.ordinal == 1 && strcmp(at101.group, "DA") == 0);
  // 151 rotates back to DB after DB was reclaimed.
  assert(at151.ordinal == 1 && strcmp(at151.group, "DB") == 0);
  // Groups cleared are always the one being switched into.
  assert(clearedCount >= 3);
  assert(strcmp(clearedGroups[0], "DB") == 0);
  assert(strcmp(clearedGroups[1], "DA") == 0);
  assert(strcmp(clearedGroups[2], "DB") == 0);

  // 200 files = 4 full generations, so three switches have happened.
  assert(clears == 3);

  // Archive name format keeps the 16-hex UTC stamp and group-local ordinal.
  char name[48];
  formatArchiveName(name, sizeof(name), "DA", "0000000068b075c0", 7);
  assert(strcmp(name, "DA_0000000068b075c0_7.txt") == 0);
  formatArchiveName(name, sizeof(name), "DB", "ffffffffffffffff", 50);
  assert(strcmp(name, "DB_ffffffffffffffff_50.txt") == 0);

  // Regression: SPIFFS::rename fails when the target lacks a leading slash,
  // which made every ARCHIVE_RENAME_FAILED. Both paths must be rooted.
  char path[64];
  toSpiffsPath(path, sizeof(path), name); // "DB_ffffffffffffffff_50.txt"
  assert(strcmp(path, "/DB_ffffffffffffffff_50.txt") == 0);
  toSpiffsPath(path, sizeof(path), "data_000000006ac2b10a_1.txt");
  assert(strcmp(path, "/data_000000006ac2b10a_1.txt") == 0);
  // An already-rooted name is not double-prefixed.
  toSpiffsPath(path, sizeof(path), "/DA_x_1.txt");
  assert(strcmp(path, "/DA_x_1.txt") == 0);

  // needsClear mirrors the switch condition.
  ArchiveCursor full = {"DA", ARCHIVE_GROUP_SIZE};
  assert(archiveNeedsClear(full, ARCHIVE_GROUP_SIZE));
  ArchiveCursor notFull = {"DA", ARCHIVE_GROUP_SIZE - 1};
  assert(!archiveNeedsClear(notFull, ARCHIVE_GROUP_SIZE));

  // Paging: a 24-file backlog drains as rounds of 10, 10 and 4.
  assert(roundCountFor(24, 10) == 3);
  assert(roundCountFor(25, 10) == 3);
  assert(roundCountFor(7, 10) == 1);
  assert(roundCountFor(20, 10) == 2);
  assert(roundCountFor(0, 10) == 0);
  {
    size_t start = 0;
    const size_t expected[] = {10, 10, 5};
    int index = 0;
    while (start < 25) {
      const size_t size = roundSizeAt(start, 25, 10);
      assert(size == expected[index]);
      start += size;
      ++index;
    }
    assert(index == 3);
    assert(start == 25);
  }
  assert(roundSizeAt(20, 24, 10) == 4);
  assert(roundSizeAt(24, 24, 10) == 0);

  // Active file name uses only the last four hex digits, keeping the full
  // stamp out of the name so a full uint32 counter still fits SPIFFS.
  char dataName[40];
  formatDataName(dataName, sizeof(dataName), "000000006ac2b917", 130);
  assert(strcmp(dataName, "data_b917_130.txt") == 0);
  assert(strlen(dataName) + 1 <= 31); // plus the leading slash SPIFFS adds
  formatDataName(dataName, sizeof(dataName), "000000006ac2b917", 0);
  assert(strcmp(dataName, "data_b917_0.txt") == 0);
  // The longest possible name still fits: 25 bytes with the leading slash.
  formatDataName(dataName, sizeof(dataName), "000000006ac2b917", 4294967295u);
  assert(strcmp(dataName, "data_b917_4294967295.txt") == 0);
  assert(strlen(dataName) + 1 == 25);
  assert(strlen(dataName) + 1 <= 31);

  // The counter spans the full uint32 range and wraps to 0, never failing.
  assert(wrapCounter(0, UINT32_MAX) == 0);
  assert(wrapCounter(1, UINT32_MAX) == 1);
  assert(wrapCounter(4294967294u, UINT32_MAX) == 4294967294u);
  assert(wrapCounter(4294967295u, UINT32_MAX) == 4294967295u);

  puts("Rolling archive plan: DA/DB generations, clears and names passed");
}
