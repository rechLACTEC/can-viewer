import 'package:flutter/material.dart';

import '../application/can_monitor_controller.dart';
import '../config/app_config.dart';
import '../data/can_api.dart';
import '../data/can_stream.dart';
import '../presentation/can_monitor_screen.dart';
import '../presentation/transmission_screen.dart';

class CanMonitorApp extends StatefulWidget {
  const CanMonitorApp({super.key, this.controller, this.autoLoad = true});

  final CanMonitorController? controller;
  final bool autoLoad;

  @override
  State<CanMonitorApp> createState() => _CanMonitorAppState();
}

class _CanMonitorAppState extends State<CanMonitorApp> {
  late final CanMonitorController _controller;
  late final bool _ownsController;

  @override
  void initState() {
    super.initState();
    _ownsController = widget.controller == null;
    if (widget.controller case final controller?) {
      _controller = controller;
    } else {
      final config = AppConfig.fromEnvironment();
      _controller = CanMonitorController(
        api: HttpCanApi(config: config),
        streamConnector: WebSocketCanStreamConnector(config),
      );
    }
    if (widget.autoLoad) _controller.loadInterfaces();
  }

  @override
  void dispose() {
    if (_ownsController) _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF00A7A0);
    return MaterialApp(
      title: 'CAN Monitor',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: seed,
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF0C1117),
        cardTheme: const CardThemeData(
          color: Color(0xFF151C24),
          margin: EdgeInsets.zero,
        ),
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
          isDense: true,
        ),
        useMaterial3: true,
      ),
      home: CanMonitorScreen(controller: _controller),
      routes: {
        TransmissionScreen.routeName: (context) =>
            TransmissionScreen(controller: _controller),
      },
    );
  }
}
