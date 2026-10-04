import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Preview uses empty in-memory settings, never the host's stored credentials.
void initializePreviewSettings() {
  FlutterSecureStorage.setMockInitialValues({});
  SharedPreferences.setMockInitialValues({});
}
