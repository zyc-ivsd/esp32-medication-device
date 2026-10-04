#pragma once
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

// Pure planning logic for the two-slot rolling archive. Kept free of SPIFFS,
// Preferences and Arduino types so the host test can compile it directly and
// verify the sequencing without a real board.
//
// Layout: `data_*` is the transferable area; `DA_*` and `DB_*` are archives
// that are never transferred. After each committed round the transferred files
// are demoted into the current group. When a group reaches `groupSize` the
// cursor switches to the other group and that group is cleared first, so at
// most two archive generations are kept. The older generation is discarded
// even if it was never synced; the team accepted that trade-off.
const size_t ARCHIVE_GROUP_SIZE = 50;

struct ArchiveCursor {
  const char *group;  // "DA" or "DB"
  size_t seq;         // 0..groupSize files already archived in this group
};

// True when the caller must clear the group it is about to switch into.
inline bool archiveNeedsClear(const ArchiveCursor &cursor, size_t groupSize) {
  return cursor.seq >= groupSize;
}

inline const char *nextArchiveGroup(const char *group) {
  return (group != nullptr && strcmp(group, "DB") == 0) ? "DA" : "DB";
}

// Advances the cursor for one archived file, emitting at most one group switch.
// `cleared` reports whether the target group must be wiped before the first
// write into it. Returns false when the cursor is already positioned and the
// caller should simply take `seq + 1`.
struct ArchiveStep {
  bool switched;
  bool needsClear;
  ArchiveCursor cursor;
};

inline ArchiveStep planArchiveStep(ArchiveCursor cursor, size_t groupSize) {
  ArchiveStep step = {false, false, cursor};
  if (cursor.seq >= groupSize) {
    step.switched = true;
    step.cursor.group = nextArchiveGroup(cursor.group);
    step.cursor.seq = 0;
    step.needsClear = true;
  }
  step.cursor.seq += 1;
  return step;
}

// The archive file name for one entry, e.g. "DA_<stamp>_<ordinal>.txt".
// `stamp` is the 16-hex UTC value taken from the original data_ name.
inline void formatArchiveName(char *out, size_t outSize, const char *group,
                              const char *stamp, size_t ordinal) {
  if (outSize == 0) return;
  snprintf(out, outSize, "%s_%s_%u.txt", group ? group : "DA",
           stamp ? stamp : "", static_cast<unsigned>(ordinal));
}

// Applies the root prefix SPIFFS requires on every absolute path. Firmware must
// pass BOTH rename arguments through this: a bare target like
// "DA_x_1.txt" makes SPIFFS::rename fail outright, which is exactly the bug
// that produced ARCHIVE_RENAME_FAILED for every file.
inline void toSpiffsPath(char *out, size_t outSize, const char *name) {
  if (outSize == 0) return;
  if (name != nullptr && name[0] == '/') {
    snprintf(out, outSize, "%s", name);
  } else {
    snprintf(out, outSize, "/%s", name ? name : "");
  }
}

// Round sizing. A backlog of `total` files is drained as a series of ordinary
// rounds of at most `roundSize` files each, so 24 files take 3 rounds (10/10/4)
// and 20 files take 2 (10/10). Each round is a normal REQ..DONE cycle with its
// own token, so this changes nothing on the wire. Pure so it can be asserted.
inline size_t roundCountFor(size_t total, size_t roundSize) {
  if (total == 0 || roundSize == 0) return 0;
  return (total + roundSize - 1) / roundSize;
}

// Files carried by the round starting at `start` of a `total`-file backlog.
inline size_t roundSizeAt(size_t start, size_t total, size_t roundSize) {
  if (start >= total) return 0;
  const size_t remaining = total - start;
  return remaining < roundSize ? remaining : roundSize;
}

// Active-record name: "data_" + the LAST FOUR hex digits of the UTC stamp + "_"
// + counter + ".txt". The full stamp would push names past the SPIFFS 31-byte
// limit after only ~10k files; four digits keep the longest name at 25 bytes
// even with a full uint32 counter. The full stamp stays in the file CONTENT,
// which is what the phone parses.
inline void formatDataName(char *out, size_t outSize, const char *fullHex16,
                           uint32_t counter) {
  if (outSize == 0) return;
  const char *tail = (fullHex16 != nullptr && strlen(fullHex16) >= 16)
                         ? fullHex16 + 12
                         : "0000";
  snprintf(out, outSize, "data_%s_%lu.txt", tail,
           static_cast<unsigned long>(counter));
}

// The counter runs the full uint32 range and wraps back to 0 after `max`, so a
// device in service for years keeps recording instead of failing. Reuse is safe
// because the writer probes SPIFFS for collisions and steps to the next value.
inline uint32_t wrapCounter(uint32_t counter, uint32_t max) {
  if (max == 0) return 0;
  if (counter > max) return 0;
  return counter;
}
