import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../data/can_api.dart';
import '../data/can_stream.dart';
import '../domain/can_models.dart';

enum MonitorConnectionState {
  disconnected,
  connecting,
  connected,
  degraded,
  recovering,
  error,
}

enum FilterAddResult { added, duplicate, failed }

class CanMonitorController extends ChangeNotifier {
  CanMonitorController({
    required CanApi api,
    required CanStreamConnector streamConnector,
    this.traceCapacity = 10000,
    this.refreshInterval = const Duration(milliseconds: 50),
  }) : _api = api,
       _streamConnector = streamConnector {
    _refreshTimer = Timer.periodic(refreshInterval, (_) => _publishSnapshot());
  }

  final CanApi _api;
  final CanStreamConnector _streamConnector;
  final int traceCapacity;
  final Duration refreshInterval;
  late final Timer _refreshTimer;
  final Queue<CanFrame> _trace = Queue();
  final Map<String, CanIdStats> _aggregates = {};
  StreamSubscription<CanFrameBatch>? _streamSubscription;
  CanStreamConnection? _streamConnection;
  Timer? _reconnectTimer;
  Timer? _recordingPollTimer;
  Timer? _transmissionPollTimer;
  CanSession? _session;
  bool _dirtyFrames = false;
  bool _closingStream = false;
  bool _recordingPolling = false;
  bool _transmissionPolling = false;
  int _transmissionMessageSequence = 0;
  int _reconnectAttempt = 0;
  final Set<String> _deletedSessions = {};
  int? _lastSequence;

  List<CanInterfaceInfo> interfaces = const [];
  CanInterfaceInfo? selectedInterface;
  MonitorConnectionState connectionState = MonitorConnectionState.disconnected;
  CanFilterMode filterMode = CanFilterMode.all;
  List<CanFilterId> whitelistFilterIds = const [];
  List<CanFilterId> blacklistFilterIds = const [];
  bool selectedSessionFd = false;
  bool updatingFilters = false;
  int appliedFilterRevision = 0;
  List<CanFrame> visibleTrace = const [];
  List<CanIdStats> visibleAggregates = const [];
  CanFrame? selectedFrame;
  String? lastError;
  bool loadingInterfaces = false;
  bool displayPaused = false;
  bool sending = false;
  bool recordingAction = false;
  CanRecording? recording;
  bool transmissionAction = false;
  bool physicalTxEnabled = false;
  bool physicalTxStateLoading = false;
  bool physicalTxUpdating = false;
  CanTransmissionStatus? transmissionStatus;
  List<CanTransmissionMessageConfig> transmissionMessages = const [];
  int receivedCount = 0;
  int framesWhilePaused = 0;
  int overwrittenFrames = 0;
  BigInt? traceStartTimestamp;
  int sequenceGapFrames = 0;
  int duplicateOrReorderedFrames = 0;
  int streamDroppedFrames = 0;
  int adapterDroppedFrames = 0;

  bool get isConnected =>
      connectionState == MonitorConnectionState.connected ||
      connectionState == MonitorConnectionState.degraded;
  bool get activeSessionFd => _session?.isFd ?? false;
  String? get activeInterfaceName => _session?.interfaceName;
  bool get activeInterfaceIsVirtual {
    final session = _session;
    if (session != null && session.interfaceType != 'unknown') {
      return session.interfaceType == 'vcan';
    }
    return selectedInterface?.type == 'vcan';
  }

  bool get transmissionEnabledForActiveInterface =>
      activeInterfaceIsVirtual || physicalTxEnabled;
  List<CanFilterId> filterIdsFor(CanFilterMode mode) => switch (mode) {
    CanFilterMode.all => const [],
    CanFilterMode.whitelist => whitelistFilterIds,
    CanFilterMode.blacklist => blacklistFilterIds,
  };
  List<CanFilterId> get filterIds => filterIdsFor(filterMode);
  bool get streamDegraded =>
      sequenceGapFrames > 0 ||
      duplicateOrReorderedFrames > 0 ||
      streamDroppedFrames > 0 ||
      adapterDroppedFrames > 0;
  bool get canConnect =>
      selectedInterface != null &&
      connectionState != MonitorConnectionState.connecting &&
      _session == null;

  Future<void> loadInterfaces() async {
    loadingInterfaces = true;
    lastError = null;
    notifyListeners();
    try {
      interfaces = await _api.listInterfaces();
      if (selectedInterface == null ||
          !interfaces.any((item) => item.name == selectedInterface!.name)) {
        selectedInterface = interfaces.isEmpty ? null : interfaces.first;
      } else {
        selectedInterface = interfaces.firstWhere(
          (item) => item.name == selectedInterface!.name,
        );
      }
    } catch (error) {
      lastError = _message(error);
    } finally {
      loadingInterfaces = false;
      notifyListeners();
    }
  }

  void selectInterface(CanInterfaceInfo? value) {
    if (_session != null) return;
    selectedInterface = value;
    if (value?.fdCapable == false) selectedSessionFd = false;
    notifyListeners();
  }

  void selectSessionFd(bool value) {
    if (_session != null || (value && selectedInterface?.fdCapable == false)) {
      return;
    }
    selectedSessionFd = value;
    notifyListeners();
  }

  Future<void> setFilterMode(CanFilterMode value) async {
    await _applyActiveFilters(value, filterIdsFor(value));
  }

  Future<FilterAddResult> addFilter(
    CanFilterMode target,
    CanFilterId value,
  ) async {
    if (updatingFilters) return FilterAddResult.failed;
    if (target == CanFilterMode.all) return FilterAddResult.failed;
    final current = filterIdsFor(target);
    if (current.contains(value)) return FilterAddResult.duplicate;
    final next = [...current, value];
    if (target == filterMode) {
      final applied = await _applyActiveFilters(target, next);
      return applied ? FilterAddResult.added : FilterAddResult.failed;
    }
    _setFilterIds(target, next);
    lastError = null;
    notifyListeners();
    return FilterAddResult.added;
  }

  Future<void> removeFilter(CanFilterMode target, CanFilterId value) async {
    if (target == CanFilterMode.all) return;
    final next = filterIdsFor(
      target,
    ).where((item) => item != value).toList(growable: false);
    if (target == filterMode) {
      await _applyActiveFilters(target, next);
      return;
    }
    _setFilterIds(target, next);
    lastError = null;
    notifyListeners();
  }

  void _setFilterIds(CanFilterMode mode, List<CanFilterId> ids) {
    switch (mode) {
      case CanFilterMode.all:
        break;
      case CanFilterMode.whitelist:
        whitelistFilterIds = List.unmodifiable(ids);
        break;
      case CanFilterMode.blacklist:
        blacklistFilterIds = List.unmodifiable(ids);
        break;
    }
  }

  Future<bool> _applyActiveFilters(
    CanFilterMode nextMode,
    List<CanFilterId> nextIds,
  ) async {
    final session = _session;
    if (session == null) {
      filterMode = nextMode;
      _setFilterIds(nextMode, nextIds);
      lastError = null;
      notifyListeners();
      return true;
    }
    updatingFilters = true;
    notifyListeners();
    try {
      final updated = await _api.updateFilters(
        session.id,
        mode: nextMode,
        ids: nextMode == CanFilterMode.all ? const [] : nextIds,
      );
      filterMode = nextMode;
      _setFilterIds(nextMode, nextIds);
      appliedFilterRevision = updated.filterRevision;
      lastError = null;
      return true;
    } catch (error) {
      lastError = _message(error);
      return false;
    } finally {
      updatingFilters = false;
      notifyListeners();
    }
  }

  Future<void> connect() async {
    final interface = selectedInterface;
    if (interface == null || !canConnect) return;
    connectionState = MonitorConnectionState.connecting;
    _lastSequence = null;
    sequenceGapFrames = 0;
    duplicateOrReorderedFrames = 0;
    streamDroppedFrames = 0;
    adapterDroppedFrames = 0;
    lastError = null;
    notifyListeners();
    try {
      _session = await _api.connect(
        interfaceName: interface.name,
        isFd: selectedSessionFd,
        mode: filterMode,
        ids: filterIdsFor(filterMode),
      );
      appliedFilterRevision = _session!.filterRevision;
      await _openStream();
      connectionState = MonitorConnectionState.connected;
    } catch (error) {
      lastError = _message(error);
      connectionState = MonitorConnectionState.error;
      final session = _session;
      if (session != null) {
        try {
          await _deleteSessionOnce(session.id);
        } catch (_) {
          // Preserva o erro original da abertura do stream.
        }
      }
      _session = null;
    }
    notifyListeners();
  }

  Future<void> _openStream() async {
    final session = _session;
    if (session == null) return;
    _closingStream = true;
    await _closeStreamConnection();
    _closingStream = false;
    final connection = await _streamConnector.connect(session.id);
    _streamConnection = connection;
    _streamSubscription = connection.batches.listen(
      _ingestBatch,
      onError: (Object error) {
        lastError = _message(error);
        _scheduleReconnect();
      },
      onDone: _scheduleReconnect,
    );
    _reconnectAttempt = 0;
  }

  void _scheduleReconnect() {
    if (_closingStream || _session == null || _reconnectTimer != null) return;
    connectionState = MonitorConnectionState.recovering;
    notifyListeners();
    final seconds = 1 << _reconnectAttempt.clamp(0, 3);
    _reconnectAttempt += 1;
    _reconnectTimer = Timer(Duration(seconds: seconds), () async {
      _reconnectTimer = null;
      try {
        await _openStream();
        connectionState = streamDegraded
            ? MonitorConnectionState.degraded
            : MonitorConnectionState.connected;
        lastError = null;
        notifyListeners();
      } catch (error) {
        lastError = _message(error);
        _scheduleReconnect();
      }
    });
  }

  void _ingestBatch(CanFrameBatch batch) {
    streamDroppedFrames = batch.streamDroppedFrames;
    adapterDroppedFrames = batch.adapterDroppedFrames;
    for (final frame in batch.frames) {
      final previous = _lastSequence;
      if (previous != null) {
        if (frame.sequence > previous + 1) {
          sequenceGapFrames += frame.sequence - previous - 1;
        } else if (frame.sequence <= previous) {
          duplicateOrReorderedFrames += 1;
        }
      }
      if (previous == null || frame.sequence > previous) {
        _lastSequence = frame.sequence;
      }
      traceStartTimestamp ??= frame.timestampNanoseconds;
      receivedCount += 1;
      if (_trace.length == traceCapacity) {
        _trace.removeFirst();
        overwrittenFrames += 1;
      }
      _trace.addLast(frame);
      final key =
          '${frame.canId}:${frame.isExtended}:${frame.isFd}:${frame.direction.name}';
      final stats = _aggregates[key];
      if (stats == null) {
        _aggregates[key] = CanIdStats.fromFrame(frame);
      } else {
        stats.add(frame);
      }
    }
    if (streamDegraded && _session != null) {
      connectionState = MonitorConnectionState.degraded;
    }
    if (displayPaused) framesWhilePaused += batch.frames.length;
    _dirtyFrames = true;
  }

  void _publishSnapshot() {
    if (!_dirtyFrames || displayPaused) return;
    visibleTrace = List.unmodifiable(_trace);
    visibleAggregates =
        _aggregates.values
            .map((value) => value.snapshot())
            .toList(growable: false)
          ..sort((a, b) => a.canId.compareTo(b.canId));
    _dirtyFrames = false;
    notifyListeners();
  }

  void togglePause() {
    displayPaused = !displayPaused;
    if (!displayPaused) {
      framesWhilePaused = 0;
      _dirtyFrames = true;
      _publishSnapshot();
    } else {
      notifyListeners();
    }
  }

  void selectFrame(CanFrame? frame) {
    selectedFrame = frame;
    notifyListeners();
  }

  double relativeSeconds(CanFrame frame) {
    final start = traceStartTimestamp;
    if (start == null) return 0;
    return (frame.timestampNanoseconds - start).toDouble() / 1000000000;
  }

  Future<void> sendFrame({
    required int canId,
    required bool isExtended,
    required bool isFd,
    required String dataHex,
  }) async {
    final session = _session;
    if (session == null || sending) return;
    if (isFd && !session.isFd) {
      throw const FormatException(
        'Conecte uma sessão CAN FD antes de transmitir um frame FD.',
      );
    }
    sending = true;
    lastError = null;
    notifyListeners();
    try {
      await _api.sendFrame(
        session.id,
        canId: canId,
        isExtended: isExtended,
        isFd: isFd,
        dataHex: dataHex,
      );
    } catch (error) {
      lastError = _message(error);
      rethrow;
    } finally {
      sending = false;
      notifyListeners();
    }
  }

  Future<void> startRecording() async {
    final session = _session;
    if (session == null || recordingAction) return;
    recordingAction = true;
    lastError = null;
    notifyListeners();
    try {
      recording = await _api.startRecording(session.id);
      _startRecordingPolling();
    } catch (error) {
      lastError = _message(error);
    } finally {
      recordingAction = false;
      notifyListeners();
    }
  }

  Future<void> pauseRecording() async {
    final current = recording;
    if (current == null || recordingAction) return;
    await _performRecordingAction(
      () => _api.pauseRecording(current.sessionId, current.recordingId),
    );
  }

  Future<void> resumeRecording() async {
    final current = recording;
    if (current == null || recordingAction) return;
    await _performRecordingAction(
      () => _api.resumeRecording(current.sessionId, current.recordingId),
    );
  }

  Future<CanRecording?> stopRecording() async {
    final current = recording;
    if (current == null || recordingAction) return null;
    recordingAction = true;
    lastError = null;
    notifyListeners();
    try {
      recording = await _api.stopRecording(
        current.sessionId,
        current.recordingId,
      );
      _recordingPollTimer?.cancel();
      _recordingPollTimer = null;
      return recording;
    } catch (error) {
      lastError = _message(error);
      return null;
    } finally {
      recordingAction = false;
      notifyListeners();
    }
  }

  Uri recordingDownloadUri(CanRecording value) =>
      _api.recordingDownloadUri(value.recordingId);

  String nextTransmissionMessageId() =>
      'message-${++_transmissionMessageSequence}';

  void addTransmissionMessage(CanTransmissionMessageConfig message) {
    transmissionMessages = [...transmissionMessages, message];
    notifyListeners();
  }

  void updateTransmissionMessage(CanTransmissionMessageConfig message) {
    transmissionMessages = [
      for (final item in transmissionMessages)
        if (item.messageId == message.messageId) message else item,
    ];
    notifyListeners();
  }

  void duplicateTransmissionMessage(CanTransmissionMessageConfig message) {
    addTransmissionMessage(
      message.copyWith(messageId: nextTransmissionMessageId()),
    );
  }

  void removeTransmissionMessage(String messageId) {
    transmissionMessages = transmissionMessages
        .where((item) => item.messageId != messageId)
        .toList(growable: false);
    notifyListeners();
  }

  void setTransmissionMessageEnabled(String messageId, bool enabled) {
    transmissionMessages = [
      for (final item in transmissionMessages)
        if (item.messageId == messageId)
          item.copyWith(enabled: enabled)
        else
          item,
    ];
    notifyListeners();
  }

  Future<CanTransmissionPreview?> previewTransmission(
    CanTransmissionMessageConfig message,
  ) async {
    final session = _session;
    if (session == null) return null;
    try {
      return await _api.previewTransmission(session.id, message);
    } catch (error) {
      lastError = _message(error);
      notifyListeners();
      return null;
    }
  }

  Future<void> loadPhysicalTxEnabled() async {
    if (physicalTxStateLoading || physicalTxUpdating) return;
    physicalTxStateLoading = true;
    lastError = null;
    notifyListeners();
    try {
      physicalTxEnabled = await _api.getPhysicalTxEnabled();
    } catch (error) {
      lastError = _message(error);
    } finally {
      physicalTxStateLoading = false;
      notifyListeners();
    }
  }

  Future<void> setPhysicalTxEnabled(bool enabled) async {
    if (physicalTxUpdating || enabled == physicalTxEnabled) return;
    physicalTxUpdating = true;
    lastError = null;
    notifyListeners();
    try {
      final confirmed = await _api.setPhysicalTxEnabled(enabled);
      physicalTxEnabled = confirmed;
      if (!confirmed) {
        final status = transmissionStatus;
        if (status != null &&
            status.state != CanTransmissionState.stopped &&
            !activeInterfaceIsVirtual) {
          transmissionStatus = await _api.getTransmission(
            status.sessionId,
            status.planId,
          );
        }
        _transmissionPollTimer?.cancel();
        _transmissionPollTimer = null;
      }
    } catch (error) {
      lastError = _message(error);
    } finally {
      physicalTxUpdating = false;
      notifyListeners();
    }
  }

  Future<CanTransmissionStatus?> configureTransmission() async {
    final session = _session;
    if (session == null || transmissionAction || transmissionMessages.isEmpty) {
      return null;
    }
    return _runTransmissionAction(() async {
      transmissionStatus = await _api.configureTransmission(
        session.id,
        transmissionMessages,
      );
      return transmissionStatus;
    });
  }

  Future<void> startConfiguredTransmission() async {
    final status = transmissionStatus;
    if (status == null) return;
    await _runTransmissionAction(() async {
      transmissionStatus = await _api.startTransmission(
        status.sessionId,
        status.planId,
      );
      _startTransmissionPolling();
      return transmissionStatus;
    });
  }

  Future<void> sendTransmissionOnce() async {
    final session = _session;
    if (session == null || transmissionMessages.isEmpty) return;
    await _runTransmissionAction(() async {
      transmissionStatus = await _api.sendTransmissionOnce(
        session.id,
        transmissionMessages,
      );
      return transmissionStatus;
    });
  }

  Future<void> pauseTransmission() => _controlTransmission(
    (status) => _api.pauseTransmission(status.sessionId, status.planId),
  );

  Future<void> resumeTransmission() => _controlTransmission(
    (status) => _api.resumeTransmission(status.sessionId, status.planId),
  );

  Future<void> stopTransmission() => _controlTransmission(
    (status) => _api.stopTransmission(status.sessionId, status.planId),
    stopPolling: true,
  );

  Future<void> stopAllTransmissions() async {
    final session = _session;
    if (session == null || transmissionAction) return;
    await _runTransmissionAction(() async {
      await _api.stopAllTransmissions(session.id);
      final status = transmissionStatus;
      if (status != null) {
        transmissionStatus = await _api.getTransmission(
          status.sessionId,
          status.planId,
        );
      }
      _transmissionPollTimer?.cancel();
      _transmissionPollTimer = null;
      return transmissionStatus;
    });
  }

  Future<void> _controlTransmission(
    Future<CanTransmissionStatus> Function(CanTransmissionStatus) action, {
    bool stopPolling = false,
  }) async {
    final status = transmissionStatus;
    if (status == null || transmissionAction) return;
    await _runTransmissionAction(() async {
      transmissionStatus = await action(status);
      if (stopPolling) {
        _transmissionPollTimer?.cancel();
        _transmissionPollTimer = null;
      }
      return transmissionStatus;
    });
  }

  Future<T?> _runTransmissionAction<T>(Future<T?> Function() action) async {
    transmissionAction = true;
    lastError = null;
    notifyListeners();
    try {
      return await action();
    } catch (error) {
      lastError = _message(error);
      return null;
    } finally {
      transmissionAction = false;
      notifyListeners();
    }
  }

  void _startTransmissionPolling() {
    _transmissionPollTimer?.cancel();
    _transmissionPollTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => unawaited(_refreshTransmission()),
    );
  }

  Future<void> _refreshTransmission() async {
    final status = transmissionStatus;
    if (status == null ||
        status.state == CanTransmissionState.stopped ||
        _transmissionPolling ||
        transmissionAction) {
      return;
    }
    _transmissionPolling = true;
    try {
      transmissionStatus = await _api.getTransmission(
        status.sessionId,
        status.planId,
      );
      if (transmissionStatus?.state == CanTransmissionState.stopped) {
        _transmissionPollTimer?.cancel();
        _transmissionPollTimer = null;
      }
      notifyListeners();
    } catch (error) {
      lastError = _message(error);
      notifyListeners();
    } finally {
      _transmissionPolling = false;
    }
  }

  Future<void> _performRecordingAction(
    Future<CanRecording> Function() action,
  ) async {
    recordingAction = true;
    lastError = null;
    notifyListeners();
    try {
      recording = await action();
    } catch (error) {
      lastError = _message(error);
    } finally {
      recordingAction = false;
      notifyListeners();
    }
  }

  void _startRecordingPolling() {
    _recordingPollTimer?.cancel();
    _recordingPollTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => unawaited(_refreshRecording()),
    );
  }

  Future<void> _refreshRecording() async {
    final current = recording;
    if (current == null ||
        !current.isActive ||
        _recordingPolling ||
        recordingAction) {
      return;
    }
    _recordingPolling = true;
    try {
      recording = await _api.getRecording(
        current.sessionId,
        current.recordingId,
      );
      if (recording?.isActive != true) {
        _recordingPollTimer?.cancel();
        _recordingPollTimer = null;
      }
      notifyListeners();
    } catch (error) {
      lastError = _message(error);
      notifyListeners();
    } finally {
      _recordingPolling = false;
    }
  }

  Future<void> disconnect() async {
    final session = _session;
    _session = null;
    _closingStream = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _recordingPollTimer?.cancel();
    _recordingPollTimer = null;
    _transmissionPollTimer?.cancel();
    _transmissionPollTimer = null;
    await _closeStreamConnection();
    if (session != null) {
      try {
        await _deleteSessionOnce(session.id);
        final current = recording;
        if (current != null && current.isActive) {
          recording = await _api.getRecording(
            current.sessionId,
            current.recordingId,
          );
        }
      } catch (error) {
        lastError = _message(error);
      }
    }
    connectionState = MonitorConnectionState.disconnected;
    notifyListeners();
  }

  void clearError() {
    lastError = null;
    if (_session == null && connectionState == MonitorConnectionState.error) {
      connectionState = MonitorConnectionState.disconnected;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    final session = _session;
    _session = null;
    _closingStream = true;
    _refreshTimer.cancel();
    _reconnectTimer?.cancel();
    _recordingPollTimer?.cancel();
    _transmissionPollTimer?.cancel();
    unawaited(_disposeResources(session));
    super.dispose();
  }

  Future<void> _closeStreamConnection() async {
    final subscription = _streamSubscription;
    final connection = _streamConnection;
    _streamSubscription = null;
    _streamConnection = null;
    await subscription?.cancel();
    await connection?.close();
  }

  Future<void> _deleteSessionOnce(String sessionId) async {
    if (!_deletedSessions.add(sessionId)) return;
    await _api.disconnect(sessionId);
  }

  Future<void> _disposeResources(CanSession? session) async {
    try {
      await _closeStreamConnection();
      if (session != null) await _deleteSessionOnce(session.id);
    } catch (_) {
      // Dispose é best-effort e não pode iniciar retries ou TX.
    } finally {
      _api.close();
    }
  }
}

String _message(Object error) => switch (error) {
  CanApiException exception => exception.message,
  FormatException exception => exception.message,
  TimeoutException _ => 'O backend não respondeu dentro do limite.',
  _ => 'Falha de comunicação com o backend.',
};
