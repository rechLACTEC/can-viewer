import 'package:can_viewer/app/can_monitor_app.dart';
import 'package:can_viewer/application/can_monitor_controller.dart';
import 'package:can_viewer/domain/can_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

void main() {
  testWidgets('selects interface and manages a filtered standard ID', (
    tester,
  ) async {
    final api = FakeCanApi();
    final streams = FakeStreamConnector();
    final controller = CanMonitorController(api: api, streamConnector: streams);
    await controller.loadInterfaces();

    await tester.pumpWidget(
      CanMonitorApp(controller: controller, autoLoad: false),
    );
    expect(find.byKey(const Key('interface-selector')), findsOneWidget);
    expect(find.textContaining('vcan0'), findsWidgets);

    await tester.tap(find.text('IDs selecionados'));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('filter-id-input')), '123');
    await tester.tap(find.byKey(const Key('add-filter')));
    await tester.pump();

    expect(find.text('0x123 STD'), findsOneWidget);
    expect(controller.filterMode, CanFilterMode.filtered);
    expect(controller.filterIds.single.canId, 0x123);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('validates transmission and asks for explicit confirmation', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = FakeCanApi();
    final streams = FakeStreamConnector();
    final controller = CanMonitorController(api: api, streamConnector: streams);
    await controller.loadInterfaces();
    await controller.connect();

    await tester.pumpWidget(
      CanMonitorApp(controller: controller, autoLoad: false),
    );
    await tester.enterText(find.byKey(const Key('tx-id-input')), '123');
    await tester.enterText(
      find.byKey(const Key('tx-payload-input')),
      '01 0A FF',
    );
    await tester.ensureVisible(find.byKey(const Key('send-button')));
    await tester.tap(find.byKey(const Key('send-button')));
    await tester.pumpAndSettle();

    expect(find.text('Confirmar transmissão CAN'), findsOneWidget);
    expect(find.text('Cancelar'), findsOneWidget);
    expect(api.sendCount, 0);
    await tester.tap(find.byKey(const Key('confirm-send')));
    await tester.pumpAndSettle();
    expect(api.sendCount, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('shows degraded banner when stream continuity is lost', (
    tester,
  ) async {
    final streams = FakeStreamConnector();
    final controller = CanMonitorController(
      api: FakeCanApi(),
      streamConnector: streams,
      refreshInterval: const Duration(milliseconds: 5),
    );
    await controller.loadInterfaces();
    await controller.connect();
    await tester.pumpWidget(
      CanMonitorApp(controller: controller, autoLoad: false),
    );

    streams.connection.controller.add(
      testBatch([testFrame(sequence: 1), testFrame(sequence: 3)]),
    );
    await tester.pump(const Duration(milliseconds: 10));

    expect(find.byKey(const Key('degraded-banner')), findsOneWidget);
    expect(find.textContaining('gaps: 1'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
}
