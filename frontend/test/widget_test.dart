import 'package:can_viewer/app/can_monitor_app.dart';
import 'package:can_viewer/application/can_monitor_controller.dart';
import 'package:can_viewer/domain/can_models.dart';
import 'package:can_viewer/presentation/can_monitor_screen.dart';
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
    expect(find.text('Transmissão manual'), findsNothing);
    expect(find.byKey(const Key('tx-id-input')), findsNothing);

    await tester.tap(find.byKey(const Key('open-transmission')));
    await tester.pumpAndSettle();

    expect(find.text('Transmissão CAN'), findsWidgets);
    expect(find.text('Configuração do frame'), findsOneWidget);
    expect(
      find.text('A transmissão pode afetar equipamentos reais.'),
      findsOneWidget,
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

    await tester.tap(find.byKey(const Key('back-to-monitor')));
    await tester.pumpAndSettle();
    expect(find.text('CAN Monitor'), findsOneWidget);
    expect(find.byKey(const Key('tx-id-input')), findsNothing);
    expect(controller.isConnected, isTrue);
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

  testWidgets('records, pauses, resumes and completes with download modal', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = FakeCanApi();
    final controller = CanMonitorController(
      api: api,
      streamConnector: FakeStreamConnector(),
    );
    await controller.loadInterfaces();
    await controller.connect();
    controller.togglePause();
    await tester.pumpWidget(
      CanMonitorApp(controller: controller, autoLoad: false),
    );

    await tester.ensureVisible(find.byKey(const Key('start-recording')));
    await tester.tap(find.byKey(const Key('start-recording')));
    await tester.pump();
    expect(api.startRecordingCount, 1);
    expect(controller.displayPaused, isTrue);
    expect(find.text('Gravando'), findsOneWidget);

    await tester.tap(find.byKey(const Key('pause-recording')));
    await tester.pump();
    expect(api.pauseRecordingCount, 1);
    expect(find.text('Gravação pausada'), findsOneWidget);

    await tester.tap(find.byKey(const Key('resume-recording')));
    await tester.pump();
    expect(api.resumeRecordingCount, 1);
    expect(find.text('Gravando'), findsOneWidget);

    await tester.tap(find.byKey(const Key('stop-recording')));
    await tester.pumpAndSettle();
    expect(api.stopRecordingCount, 1);
    expect(find.text('Gravação concluída'), findsOneWidget);
    expect(find.text('Frames gravados: 8'), findsWidgets);
    expect(find.byKey(const Key('download-recording-dialog')), findsOneWidget);

    await tester.tap(find.text('Fechar'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('download-recording')), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('auto scroll freezes only the visual snapshot and resumes live', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final streams = FakeStreamConnector();
    final controller = CanMonitorController(
      api: FakeCanApi(),
      streamConnector: streams,
      refreshInterval: const Duration(milliseconds: 5),
    );
    await controller.loadInterfaces();
    await controller.connect();
    await tester.pumpWidget(
      MaterialApp(home: CanMonitorScreen(controller: controller)),
    );

    expect(
      tester.widget<Switch>(find.byKey(const Key('auto-scroll-toggle'))).value,
      isTrue,
    );
    expect(find.byKey(const Key('show-binary-toggle')), findsNothing);
    expect(
      tester
          .widget<SizedBox>(
            find.byKey(const Key('payload-representation-field')),
          )
          .width,
      104,
    );
    expect(
      tester
          .widget<Padding>(
            find.byKey(const Key('payload-representation-control')),
          )
          .padding,
      const EdgeInsets.only(right: 8),
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('payload-representation-selector')),
        matching: find.text('NONE'),
      ),
      findsOneWidget,
    );
    expect(find.text('Dados BIN'), findsNothing);
    expect(find.text('Dados DEC'), findsNothing);

    streams.connection.controller.add(
      testBatch([
        for (var sequence = 1; sequence <= 30; sequence++)
          testFrame(sequence: sequence, timestampNs: sequence * 1000000),
      ]),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
    await tester.pump();

    final traceList = tester.widget<ListView>(
      find.byKey(const Key('trace-list')),
    );
    final scrollController = traceList.controller!;
    expect(scrollController.offset, scrollController.position.maxScrollExtent);

    await tester.tap(find.byKey(const Key('payload-representation-selector')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('BIN').last);
    await tester.pumpAndSettle();
    expect(find.text('Dados HEX'), findsWidgets);
    expect(find.text('Dados BIN'), findsOneWidget);
    expect(find.text('00000001 00001010 11111111'), findsWidgets);

    await tester.tap(find.byKey(const Key('auto-scroll-toggle')));
    await tester.pump();
    expect(controller.displayPaused, isTrue);
    final frozenSequences = controller.visibleTrace
        .map((frame) => frame.sequence)
        .toList(growable: false);
    scrollController.jumpTo(0);
    await tester.pump();
    streams.connection.controller.add(
      testBatch([
        for (var sequence = 31; sequence <= 40; sequence++)
          testFrame(sequence: sequence, timestampNs: sequence * 1000000),
      ]),
    );
    await tester.pump(const Duration(milliseconds: 10));
    await tester.pump();
    expect(controller.receivedCount, 40);
    expect(controller.framesWhilePaused, 10);
    expect(
      controller.visibleTrace.map((frame) => frame.sequence),
      frozenSequences,
    );
    expect(controller.visibleTrace.last.sequence, 30);
    expect(scrollController.offset, 0);

    await tester.tap(find.byKey(const Key('payload-representation-selector')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('DEC').last);
    await tester.pumpAndSettle();
    expect(find.text('Dados BIN'), findsNothing);
    expect(find.text('Dados DEC'), findsOneWidget);
    expect(find.text('1 10 255'), findsWidgets);
    expect(
      controller.visibleTrace.map((frame) => frame.sequence),
      frozenSequences,
    );

    await tester.tap(find.byKey(const Key('payload-representation-selector')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('NONE').last);
    await tester.pumpAndSettle();
    expect(find.text('Dados BIN'), findsNothing);
    expect(find.text('Dados DEC'), findsNothing);
    expect(find.text('Dados HEX'), findsWidgets);
    expect(
      controller.visibleTrace.map((frame) => frame.sequence),
      frozenSequences,
    );

    await tester.tap(find.byKey(const Key('auto-scroll-toggle')));
    await tester.pump();
    expect(controller.displayPaused, isFalse);
    expect(controller.framesWhilePaused, 0);
    expect(controller.visibleTrace, hasLength(40));
    expect(controller.visibleTrace.last.sequence, 40);
    expect(scrollController.offset, scrollController.position.maxScrollExtent);

    await tester.tap(find.byKey(const Key('pause-display')));
    await tester.pump();
    expect(controller.displayPaused, isTrue);
    expect(
      tester.widget<Switch>(find.byKey(const Key('auto-scroll-toggle'))).value,
      isFalse,
    );
    await tester.tap(find.byKey(const Key('pause-display')));
    await tester.pump();
    expect(controller.displayPaused, isFalse);
    expect(
      tester.widget<Switch>(find.byKey(const Key('auto-scroll-toggle'))).value,
      isTrue,
    );

    await tester.tap(find.byKey(const Key('trace-frame-40')));
    await tester.pump();
    expect(find.byKey(const Key('close-frame-inspector')), findsOneWidget);
    expect(find.textContaining('seq 40'), findsOneWidget);

    await tester.tap(find.byKey(const Key('close-frame-inspector')));
    await tester.pump();
    expect(controller.selectedFrame, isNull);
    expect(find.byKey(const Key('close-frame-inspector')), findsNothing);

    await tester.ensureVisible(find.byKey(const Key('trace-frame-39')));
    await tester.tap(find.byKey(const Key('trace-frame-39')));
    await tester.pump();
    expect(find.byKey(const Key('close-frame-inspector')), findsOneWidget);
    expect(find.textContaining('seq 39'), findsOneWidget);

    expect(controller.isConnected, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
}
