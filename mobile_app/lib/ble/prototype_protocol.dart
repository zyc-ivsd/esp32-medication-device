import 'dart:convert';

/// Prototype 0.1 is raw device text, NOT the formal medication-event protocol.
int prototypeCrc(List<int> bytes) {
  var crc = 0xffff;
  for (final byte in bytes) {
    crc ^= byte << 8;
    for (var bit = 0; bit < 8; bit++) {
      crc = ((crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1) & 0xffff;
    }
  }
  return crc;
}

String encodePrototypeFrame(String body) =>
    '\n$body|${prototypeCrc(utf8.encode(body)).toRadixString(16).padLeft(4, '0')}\n';

List<String> decodePrototypeFrame(String line) {
  final separator = line.lastIndexOf('|');
  if (separator < 0) {
    throw const FormatException('Legacy or incomplete text frame');
  }
  final body = line.substring(0, separator);
  final checksum = line.substring(separator + 1);
  if (!RegExp(r'^[0-9a-fA-F]{4}$').hasMatch(checksum) ||
      int.parse(checksum, radix: 16) != prototypeCrc(utf8.encode(body))) {
    throw const FormatException('CRC check failed; frame not acknowledged');
  }
  return body.split('|');
}

/// Decode UTF-8 only after the newline is received. A leading newline on each
/// firmware frame lets a retry recover from a previously truncated frame.
class PrototypeLineBuffer {
  final List<int> _pending = [];
  bool _discarding = false;
  static const maxLineBytes = 256;

  List<String> add(List<int> bytes) {
    final result = <String>[];
    for (final byte in bytes) {
      if (byte == 10) {
        if (!_discarding && _pending.isNotEmpty) {
          try {
            result.add(utf8.decode(_pending).replaceFirst(RegExp(r'\r$'), ''));
          } on FormatException {
            result.add('[Invalid UTF-8; waiting for device retry]');
          }
        }
        reset();
      } else if (!_discarding) {
        _pending.add(byte);
        if (_pending.length > maxLineBytes) {
          _pending.clear();
          _discarding = true;
        }
      }
    }
    return result;
  }

  void reset() {
    _pending.clear();
    _discarding = false;
  }
}

class PrototypeRecord {
  const PrototypeRecord({
    required this.deviceId,
    required this.fileId,
    required this.rawText,
    required this.receivedAt,
  });
  final String deviceId;
  final String fileId;
  final String rawText;
  final DateTime receivedAt;
}
