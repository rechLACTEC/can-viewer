import 'package:can_viewer/application/can_monitor_controller.dart';
import 'package:can_viewer/domain/can_models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

void main() {
  test(
    'coalesces frames, bounds trace and freezes only presentation',
    () async {
      final api = FakeCanApi();
      final streams = FakeStreamConnector();
      final controller = CanMonitorController(
        api: api,
        streamConnector: streams,
        traceCapacity: 2,
        refreshInterval: const Duration(milliseconds: 10),
      );
      addTearDown(controller.dispose);

      await controller.loadInterfaces();
      await controller.connect();
      streams.connection.controller.add(
        testBatch([
          testFrame(sequence: 1, timestampNs: 1000000000),
          testFrame(sequence: 2, timestampNs: 1010000000),
          testFrame(id: 0x456, sequence: 3, timestampNs: 1020000000),
        ]),
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(controller.receivedCount, 3);
      expect(controller.visibleTrace, hasLength(2));
      expect(controller.overwrittenFrames, 1);
      expect(controller.visibleAggregates, hasLength(2));

      controller.togglePause();
      streams.connection.controller.add(
        testBatch([testFrame(sequence: 4, timestampNs: 1030000000)]),
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(controller.receivedCount, 4);
      expect(controller.framesWhilePaused, 1);
      expect(controller.visibleTrace.last.canId, 0x456);

      controller.togglePause();
      expect(controller.visibleTrace.last.canId, 0x123);
      expect(controller.framesWhilePaused, 0);
    },
  );

  test('detects sequence gaps and backend drops as degraded', () async {
    final streams = FakeStreamConnector();
    final controller = CanMonitorController(
      api: FakeCanApi(),
      streamConnector: streams,
      refreshInterval: const Duration(milliseconds: 5),
    );
    addTearDown(controller.dispose);
    await controller.loadInterfaces();
    await controller.connect();
    streams.connection.controller.add(
      testBatch(
        [testFrame(sequence: 1), testFrame(sequence: 4)],
        streamDropped: 2,
        adapterDropped: 1,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 15));

    expect(controller.sequenceGapFrames, 2);
    expect(controller.streamDroppedFrames, 2);
    expect(controller.adapterDroppedFrames, 1);
    expect(controller.streamDegraded, isTrue);
    expect(controller.connectionState, MonitorConnectionState.degraded);
  });

  test(
    'publishes filters only after successful PUT and blocks empty',
    () async {
      final api = FakeCanApi();
      final controller = CanMonitorController(
        api: api,
        streamConnector: FakeStreamConnector(),
      );
      addTearDown(controller.dispose);
      await controller.loadInterfaces();
      await controller.connect();
      api.failFilterUpdate = true;

      await controller.addFilter(
        const CanFilterId(canId: 0x123, isExtended: false),
      );
      expect(controller.filterMode, CanFilterMode.all);
      expect(controller.filterIds, isEmpty);
      expect(controller.lastError, 'filter rejected');

      await controller.setFilterMode(CanFilterMode.filtered);
      expect(controller.filterMode, CanFilterMode.all);
      expect(controller.lastError, contains('ao menos um'));

      api.failFilterUpdate = false;
      await controller.addFilter(
        const CanFilterId(canId: 0x123, isExtended: false),
      );
      expect(controller.filterMode, CanFilterMode.filtered);
      expect(controller.filterIds, hasLength(1));
      expect(controller.appliedFilterRevision, 2);

      await controller.removeFilter(controller.filterIds.single);
      expect(controller.filterIds, hasLength(1));
      expect(controller.lastError, contains('ao menos um'));
    },
  );

  test('separates CAN and FD aggregation and uses monotonic timing', () async {
    final streams = FakeStreamConnector();
    final controller = CanMonitorController(
      api: FakeCanApi(),
      streamConnector: streams,
      refreshInterval: const Duration(milliseconds: 5),
    );
    addTearDown(controller.dispose);
    await controller.loadInterfaces();
    await controller.connect();
    streams.connection.controller.add(
      testBatch([
        testFrame(sequence: 1, timestampNs: 1000, monotonicNs: 1000000),
        testFrame(sequence: 2, timestampNs: 999999999, monotonicNs: 11000000),
        testFrame(sequence: 3, isFd: true, monotonicNs: 2000000),
      ]),
    );
    await Future<void>.delayed(const Duration(milliseconds: 15));

    expect(controller.visibleAggregates, hasLength(2));
    final classic = controller.visibleAggregates.firstWhere(
      (stats) => !stats.lastFrame.isFd,
    );
    expect(classic.lastIntervalMs, 10);
  });

  test('selects FD session and dispose deletes once then closes API', () async {
    final api = FakeCanApi();
    final controller = CanMonitorController(
      api: api,
      streamConnector: FakeStreamConnector(),
    );
    await controller.loadInterfaces();
    controller.selectSessionFd(true);
    await controller.connect();
    expect(api.connectedFd, isTrue);
    expect(controller.activeSessionFd, isTrue);

    controller.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(api.disconnectCount, 1);
    expect(api.closed, isTrue);
  });

  test(
    'physical TX state follows backend and is retained on update error',
    () async {
      final api = FakeCanApi(physicalTxEnabled: true);
      final controller = CanMonitorController(
        api: api,
        streamConnector: FakeStreamConnector(),
      );
      addTearDown(controller.dispose);

      await controller.loadPhysicalTxEnabled();
      expect(controller.physicalTxEnabled, isTrue);
      expect(api.getPhysicalTxEnabledCount, 1);

      api.failPhysicalTxUpdate = true;
      await controller.setPhysicalTxEnabled(false);
      expect(controller.physicalTxEnabled, isTrue);
      expect(controller.lastError, 'Não foi possível alterar TX físico.');

      api.failPhysicalTxUpdate = false;
      await controller.setPhysicalTxEnabled(false);
      expect(controller.physicalTxEnabled, isFalse);
      expect(api.setPhysicalTxEnabledCount, 2);
    },
  );
}
