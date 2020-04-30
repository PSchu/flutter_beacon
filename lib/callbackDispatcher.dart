import 'dart:convert';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_beacon/flutter_beacon.dart';


void callbackDispatcher() {
  const MethodChannel _backgroundChannel =
  MethodChannel('plugins.flutter.io/geofencing_plugin_background');
  WidgetsFlutterBinding.ensureInitialized();

  _backgroundChannel.setMethodCallHandler((MethodCall call) async {
    final List<dynamic> args = call.arguments;
    final Function callback = PluginUtilities.getCallbackFromHandle(
        CallbackHandle.fromRawHandle(args[0]));
    assert(callback != null);
    final String resultString = args[1] as String;
    final MonitoringResult result = MonitoringResult.from(jsonDecode(resultString));
    callback(result);
  });
  _backgroundChannel.invokeMethod('GeofencingService.initialized');
}
