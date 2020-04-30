import 'dart:convert';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_beacon/flutter_beacon.dart';


void callbackDispatcher() {
  const MethodChannel _backgroundChannel =
  MethodChannel('flutter_beacon_event_monitoring_background');
  WidgetsFlutterBinding.ensureInitialized();

  _backgroundChannel.setMethodCallHandler((MethodCall call) async {
    final List<dynamic> args = call.arguments;
    final Function callback = PluginUtilities.getCallbackFromHandle(
        CallbackHandle.fromRawHandle(args[0]));
    assert(callback != null);
    final MonitoringResult result = MonitoringResult.from(args[1]);
    callback(result);
  });
  _backgroundChannel.invokeMethod('initializeDispatch');
}
