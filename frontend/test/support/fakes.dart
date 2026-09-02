import 'dart:async';

import 'package:can_viewer/data/can_api.dart';
import 'package:can_viewer/data/can_stream.dart';
import 'package:can_viewer/domain/can_models.dart';

class FakeCanApi implements CanApi {
  FakeCanApi({
    this.interfaces = const [
      CanInterfaceInfo(name: 'vcan0', state: 'up', type: 'vcan'),
    ],
    this.physicalTxEnabled = false,
  });

  final List<CanInterfaceInfo> interfaces;
  bool physicalTxEnabled;
  bool failPhysicalTxUpdate = false;
  int getPhysicalTxEnabledCount = 0;
  int setPhysicalTxEnabledCount = 0;
  CanFilterMode? lastFilterMode;
  List<CanFilterId> lastFilterIds = const [];
  int updateFiltersCount = 0;
  int sendCount = 0;
  int disconnectCount = 0;
  bool closed = false;
  bool failFilterUpdate = false;
  bool? connectedFd;
  int startRecordingCount = 0;
  int pauseRecordingCount = 0;
  int resumeRecordingCount = 0;
  int stopRecordingCount = 0;
  CanRecording? recording;
  int configureTransmissionCount = 0;
  int sendTransmissionOnceCount = 0;
  int startTransmissionCount = 0;
  int pauseTransmissionCount = 0;
  int resumeTransmissionCount = 0;
  int stopTransmissionCount = 0;
  int stopAllTransmissionsCount = 0;
  CanTransmissionStatus? transmissionStatus;

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
      interfaceType: interfaces
          .firstWhere((item) => item.name == interfaceName)
          .type,
      isFd: isFd,
      filterRevision: 1,
    );
  }

  @override
  Future<void> disconnect(String sessionId) async {
    disconnectCount += 1;
  }

  @override
  Future<CanRecording> startRecording(String sessionId) async {
    startRecordingCount += 1;
    return recording = testRecording(state: CanRecordingState.recording);
  }

  @override
  Future<CanRecording> getRecording(
    String sessionId,
    String recordingId,
  ) async => recording ?? testRecording();

  @override
  Future<CanRecording> pauseRecording(
    String sessionId,
    String recordingId,
  ) async {
    pauseRecordingCount += 1;
    return recording = testRecording(
      state: CanRecordingState.paused,
      recordedFrames: 4,
    );
  }

  @override
  Future<CanRecording> resumeRecording(
    String sessionId,
    String recordingId,
  ) async {
    resumeRecordingCount += 1;
    return recording = testRecording(
      state: CanRecordingState.recording,
      recordedFrames: 4,
    );
  }

  @override
  Future<CanRecording> stopRecording(
    String sessionId,
    String recordingId,
  ) async {
    stopRecordingCount += 1;
    return recording = testRecording(
      state: CanRecordingState.completed,
      recordedFrames: 8,
      sizeBytes: 2048,
    );
  }

  @override
  Uri recordingDownloadUri(String recordingId) => Uri.parse(
    'http://localhost:8000/api/v1/can/recordings/$recordingId/download',
  );

  @override
  Future<CanTransmissionPreview> previewTransmission(
    String sessionId,
    CanTransmissionMessageConfig message,
  ) async => const CanTransmissionPreview(
    payloadHex: '0102030405060744',
    crcValue: 0x44,
  );

  @override
  Future<CanTransmissionStatus> configureTransmission(
    String sessionId,
    List<CanTransmissionMessageConfig> messages,
  ) async {
    configureTransmissionCount += 1;
    return transmissionStatus = testTransmissionStatus(
      messages,
      state: CanTransmissionState.stopped,
    );
  }

  @override
  Future<CanTransmissionStatus> sendTransmissionOnce(
    String sessionId,
    List<CanTransmissionMessageConfig> messages,
  ) async {
    sendTransmissionOnceCount += 1;
    return transmissionStatus = testTransmissionStatus(
      messages,
      state: CanTransmissionState.stopped,
      sentFrames: messages.where((item) => item.enabled).length,
    );
  }

  @override
  Future<CanTransmissionStatus> startTransmission(
    String sessionId,
    String planId,
  ) async {
    startTransmissionCount += 1;
    return transmissionStatus = _copyTransmissionState(
      CanTransmissionState.running,
    );
  }

  @override
  Future<CanTransmissionStatus> getTransmission(
    String sessionId,
    String planId,
  ) async => transmissionStatus!;

  @override
  Future<CanTransmissionStatus> pauseTransmission(
    String sessionId,
    String planId,
  ) async {
    pauseTransmissionCount += 1;
    return transmissionStatus = _copyTransmissionState(
      CanTransmissionState.paused,
    );
  }

  @override
  Future<CanTransmissionStatus> resumeTransmission(
    String sessionId,
    String planId,
  ) async {
    resumeTransmissionCount += 1;
    return transmissionStatus = _copyTransmissionState(
      CanTransmissionState.running,
    );
  }

  @override
  Future<CanTransmissionStatus> stopTransmission(
    String sessionId,
    String planId,
  ) async {
    stopTransmissionCount += 1;
    return transmissionStatus = _copyTransmissionState(
      CanTransmissionState.stopped,
    );
  }

  @override
  Future<void> stopAllTransmissions(String sessionId) async {
    stopAllTransmissionsCount += 1;
    transmissionStatus = _copyTransmissionState(CanTransmissionState.stopped);
  }

  CanTransmissionStatus _copyTransmissionState(CanTransmissionState state) {
    final current = transmissionStatus!;
    return CanTransmissionStatus(
      planId: current.planId,
      sessionId: current.sessionId,
      interfaceName: current.interfaceName,
      state: state,
      messages: current.messages,
      sentFrames: current.sentFrames,
      sendErrors: current.sendErrors,
      deadlineMisses: current.deadlineMisses,
      estimatedBusLoadPercent: current.estimatedBusLoadPercent,
    );
  }

  @override
  Future<CanFrame?> sendFrame(
    String sessionId, {
    required int canId,
    required bool isExtended,
    required bool isFd,
    required String dataHex,
  }) async {
    sendCount += 1;
    return null;
  }

  @override
  Future<bool> getPhysicalTxEnabled() async {
    getPhysicalTxEnabledCount += 1;
    return physicalTxEnabled;
  }

  @override
  Future<bool> setPhysicalTxEnabled(bool enabled) async {
    setPhysicalTxEnabledCount += 1;
    if (failPhysicalTxUpdate) {
      throw const CanApiException('Não foi possível alterar TX físico.');
    }
    physicalTxEnabled = enabled;
    if (!enabled && transmissionStatus != null) {
      transmissionStatus = _copyTransmissionState(CanTransmissionState.stopped);
    }
    return physicalTxEnabled;
  }

  @override
  Future<CanSession> updateFilters(
    String sessionId, {
    required CanFilterMode mode,
    required List<CanFilterId> ids,
  }) async {
    updateFiltersCount += 1;
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
  bool isExtended = false,
}) => CanFrame(
  sequence: sequence,
  filterRevision: 1,
  timestampNanoseconds: BigInt.from(timestampNs),
  ingressMonotonicNanoseconds: BigInt.from(monotonicNs ?? timestampNs),
  interfaceName: 'vcan0',
  canId: id,
  isExtended: isExtended,
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

CanRecording testRecording({
  CanRecordingState state = CanRecordingState.recording,
  int recordedFrames = 0,
  int unsupportedFrames = 0,
  int droppedFrames = 0,
  int sizeBytes = 0,
}) => CanRecording(
  state: state,
  recordingId: 'recording-1',
  sessionId: 'session-1',
  interfaceName: 'vcan0',
  startedAt: DateTime.utc(2026, 9, 1, 15, 42, 18),
  completedAt: state == CanRecordingState.completed
      ? DateTime.utc(2026, 9, 1, 15, 43)
      : null,
  recordedFrames: recordedFrames,
  unsupportedFrames: unsupportedFrames,
  unsupportedCanFd: 0,
  unsupportedRemoteFrames: 0,
  unsupportedErrorFrames: 0,
  droppedFrames: droppedFrames,
  sizeBytes: sizeBytes,
  degraded: unsupportedFrames > 0 || droppedFrames > 0,
  filename: 'vcan0_2026-09-01_15-42-18_recording-1.trc',
);

CanTransmissionStatus testTransmissionStatus(
  List<CanTransmissionMessageConfig> messages, {
  CanTransmissionState state = CanTransmissionState.stopped,
  int sentFrames = 0,
}) => CanTransmissionStatus(
  planId: 'plan-1',
  sessionId: 'session-1',
  interfaceName: 'vcan0',
  state: state,
  messages: messages
      .map(
        (item) => CanTransmissionMessageStatus(
          messageId: item.messageId,
          state: state == CanTransmissionState.running ? 'active' : state.name,
          sentFrames: sentFrames,
          sendErrors: 0,
          deadlineMisses: 0,
        ),
      )
      .toList(growable: false),
  sentFrames: sentFrames,
  sendErrors: 0,
  deadlineMisses: 0,
  estimatedBusLoadPercent: 1.2,
);
