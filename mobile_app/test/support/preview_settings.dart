import 'package:shared_preferences/shared_preferences.dart';

/// Preview uses empty in-memory settings, never the host's saved preferences.
void initializePreviewSettings() {
  SharedPreferences.setMockInitialValues({});
}
