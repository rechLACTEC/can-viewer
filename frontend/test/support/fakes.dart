import 'dart:async';

import 'package:can_viewer/data/can_api.dart';
import 'package:can_viewer/data/can_stream.dart';
import 'package:can_viewer/domain/can_models.dart';

class FakeCanApi implements CanApi {
  final interfaces = const [
    CanInterfaceInfo(name: 'vcan0', state: 'up', type: 'vcan'),
  ];
  CanFilterMode? lastFilterMode;
  List<CanFilterId> lastFilterIds = const [];
  int sendCount = 0;
  int disconnectCount = 0;
  bool closed = false;
  bool failFilterUpdate = false;
  bool? connectedFd;

  @override
  Future<List<CanInterfaceInfo>> listInterfaces() async => interfaces;

  @override
  Future<CanSession> connect({
    required String interfaceName,
    required bool isFd,
    required CanFilterMode mode,
    required List<CanFilterId> ids,
  }) async {
    lastFilterMode = mode;
    lastFilterIds = ids;
    connectedFd = isFd;
    return CanSession(
      id: 'session-1',
      interfaceName: interfaceName,
      isFd: isFd,
      filterRevision: 1,
    );
  }

  @override
  Future<void> disconnect(String sessionId) async {
    disconnectCount += 1;
  }

  @override
  Future<CanFrame?> sendFrame(
    String sessionId, {
    required int canId,
    required bool isExtended,
    required bool isFd,
    required String dataHex,
    String? authorizationToken,
  }) async {
    sendCount += 1;
    return null;
  }

  @override
  Future<CanSession> updateFilters(
    String sessionId, {
    required CanFilterMode mode,
    required List<CanFilterId> ids,
  }) async {
    if (failFilterUpdate) throw const CanApiException('filter rejected');
    lastFilterMode = mode;
    lastFilterIds = ids;
    return CanSession(
      id: sessionId,
      interfaceName: 'vcan0',
      isFd: connectedFd ?? false,
      filterRevision: 2,
    );
  }

  @override
  void close() => closed = true;
}

class FakeStreamConnector implements CanStreamConnector {
  final connection = FakeStreamConnection();

  @override
  Future<CanStreamConnection> connect(String sessionId) async => connection;
}

class FakeStreamConnection implements CanStreamConnection {
  final controller = StreamController<CanFrameBatch>.broadcast();

  @override
  Stream<CanFrameBatch> get batches => controller.stream;

  @override
  Future<void> close() async {
    if (!controller.isClosed) await controller.close();
  }
}

CanFrame testFrame({
  int id = 0x123,
  int sequence = 1,
  int timestampNs = 1000000000,
  int? monotonicNs,
  bool isFd = false,
}) => CanFrame(
  sequence: sequence,
  filterRevision: 1,
  timestampNanoseconds: BigInt.from(timestampNs),
  ingressMonotonicNanoseconds: BigInt.from(monotonicNs ?? timestampNs),
  interfaceName: 'vcan0',
  canId: id,
  isExtended: false,
  isFd: isFd,
  dlc: 3,
  data: parseHexBytes('01 0A FF'),
  direction: CanDirection.rx,
);

CanFrameBatch testBatch(
  List<CanFrame> frames, {
  int streamDropped = 0,
  int adapterDropped = 0,
}) => CanFrameBatch(
  version: 1,
  frames: frames,
  streamDroppedFrames: streamDropped,
  adapterDroppedFrames: adapterDropped,
);
