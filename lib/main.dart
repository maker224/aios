import 'package:aios/app.dart';
import 'package:aios/core/storage/app_store.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timezone/data/latest.dart' as tzdata;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppStore.init();
  tzdata.initializeTimeZones();
  await _ensureDeviceName();
  runApp(const ProviderScope(child: AIoSApp()));
}

Future<void> _ensureDeviceName() async {
  if (AppStore.settings.get('deviceName') != null) return;
  var base = 'AIoS Device';
  try {
    final info = await DeviceInfoPlugin().deviceInfo;
    if (info is IosDeviceInfo) {
      base = info.name;
    } else if (info is MacOsDeviceInfo) {
      base = info.computerName;
    } else if (info is WindowsDeviceInfo) {
      base = info.computerName;
    } else if (info is AndroidDeviceInfo) {
      base = info.model;
    }
  } catch (_) {}
  final id = AppStore.settings.get('deviceId') as String? ?? '';
  final suffix = id.length >= 4 ? id.substring(0, 4).toUpperCase() : '';
  await AppStore.settings
      .put('deviceName', suffix.isEmpty ? base : '$base-$suffix');
}
