import 'dart:typed_data';

enum CanDirection { rx, tx }

enum CanFilterMode { all, filtered }

enum CanRecordingState { idle, recording, paused, finalizing, completed, error }

enum CanTransmissionMode { single, cyclic }

enum CanTransmissionState { stopped, running, paused, error }

class CanInterfaceInfo {
  const CanInterfaceInfo({
    required this.name,
    required this.state,
    required this.type,
    this.bitrate,
    this.fdCapable,
  });

  factory CanInterfaceInfo.fromJson(Map<String, Object?> json) =>
      CanInterfaceInfo(
        name: _requiredString(json, 'name'),
        state:
            json['state'] as String? ??
            json['operational_state'] as String? ??
            ((json['administratively_up'] as bool?) == true ? 'up' : 'unknown'),
        type: json['type'] as String? ?? json['kind'] as String? ?? 'unknown',
        bitrate: (json['bitrate'] as num?)?.toInt(),
        fdCapable: json['fd_capable'] as bool? ?? json['fd_enabled'] as bool?,
      );

  final String name;
  final String state;
  final String type;
  final int? bitrate;
  final bool? fdCapable;

  bool get isUp => state.toLowerCase() == 'up';
}

class CanFilterId {
  const CanFilterId({required this.canId, required this.isExtended});

  final int canId;
  final bool isExtended;

  String get displayId => isExtended
      ? '0x${canId.toRadixString(16).toUpperCase().padLeft(8, '0')}'
      : '0x${canId.toRadixString(16).toUpperCase().padLeft(3, '0')}';
  String get label => '$displayId ${isExtended ? 'EXT' : 'STD'}';
  Map<String, Object> toJson() => {
    'can_id': canId,
    'is_extended_id': isExtended,
  };

  @override
  bool operator ==(Object other) =>
      other is CanFilterId &&
      other.canId == canId &&
      other.isExtended == isExtended;

  @override
  int get hashCode => Object.hash(canId, isExtended);
}

class CanFrame {
  const CanFrame({
    required this.sequence,
    required this.filterRevision,
    required this.timestampNanoseconds,
    required this.ingressMonotonicNanoseconds,
    required this.interfaceName,
    required this.canId,
    required this.isExtended,
    required this.isFd,
    required this.dlc,
    required this.data,
    required this.direction,
    this.isErrorFrame = false,
    this.isRemoteFrame = false,
    this.bitrateSwitch = false,
    this.errorStateIndicator = false,
  });

  factory CanFrame.fromJson(Map<String, Object?> json) {
    final rawTimestamp = json['timestamp_ns'] ?? json['timestamp_nanoseconds'];
    final timestamp = switch (rawTimestamp) {
      String value => BigInt.parse(value),
      int value => BigInt.from(value),
      _ => throw const FormatException('timestamp_ns ausente ou inválido.'),
    };
    final direction = _requiredString(json, 'direction').toLowerCase();
    return CanFrame(
      sequence: _requiredInt(json, 'sequence'),
      filterRevision: _requiredInt(json, 'filter_revision'),
      timestampNanoseconds: timestamp,
      ingressMonotonicNanoseconds: _requiredBigInt(
        json,
        'ingress_monotonic_ns',
      ),
      interfaceName: _requiredString(json, 'interface'),
      canId: _requiredInt(json, 'can_id'),
      isExtended: json['is_extended_id'] as bool? ?? false,
      isFd: json['is_fd'] as bool? ?? false,
      dlc: _requiredInt(json, 'dlc'),
      data: parseHexBytes(_requiredString(json, 'data_hex', allowEmpty: true)),
      direction: direction == 'tx' ? CanDirection.tx : CanDirection.rx,
      isErrorFrame: json['is_error_frame'] as bool? ?? false,
      isRemoteFrame: json['is_remote_frame'] as bool? ?? false,
      bitrateSwitch: json['bitrate_switch'] as bool? ?? false,
      errorStateIndicator: json['error_state_indicator'] as bool? ?? false,
    );
  }

  final int sequence;
  final int filterRevision;
  final BigInt timestampNanoseconds;
  final BigInt ingressMonotonicNanoseconds;
  final String interfaceName;
  final int canId;
  final bool isExtended;
  final bool isFd;
  final int dlc;
  final Uint8List data;
  final CanDirection direction;
  final bool isErrorFrame;
  final bool isRemoteFrame;
  final bool bitrateSwitch;
  final bool errorStateIndicator;

  String get idText =>
      CanFilterId(canId: canId, isExtended: isExtended).displayId;
  String get hexText => data
      .map((byte) => byte.toRadixString(16).toUpperCase().padLeft(2, '0'))
      .join(' ');
  String get binaryText =>
      data.map((byte) => byte.toRadixString(2).padLeft(8, '0')).join(' ');
  String get decimalText => data.join(' ');
  double get seconds => timestampNanoseconds.toDouble() / 1000000000;
  BigInt get timingNanoseconds => ingressMonotonicNanoseconds;
}

class CanSession {
  const CanSession({
    required this.id,
    required this.interfaceName,
    required this.isFd,
    required this.filterRevision,
  });

  factory CanSession.fromJson(Map<String, Object?> json) {
    final nested = json['session'];
    final source = nested is Map<String, Object?> ? nested : json;
    final interfaceName = source['interface'] ?? source['interface_name'];
    if (interfaceName is! String) {
      throw const FormatException('interface da sessão ausente.');
    }
    return CanSession(
      id: source['id'] is String
          ? source['id']! as String
          : _requiredString(source, 'session_id'),
      interfaceName: interfaceName,
      isFd: source['fd'] as bool? ?? false,
      filterRevision: (source['filter_revision'] as num?)?.toInt() ?? 1,
    );
  }

  final String id;
  final String interfaceName;
  final bool isFd;
  final int filterRevision;
}

class CanRecording {
  const CanRecording({
    required this.state,
    required this.recordingId,
    required this.sessionId,
    required this.interfaceName,
    required this.startedAt,
    required this.recordedFrames,
    required this.unsupportedFrames,
    required this.unsupportedCanFd,
    required this.unsupportedRemoteFrames,
    required this.unsupportedErrorFrames,
    required this.droppedFrames,
    required this.sizeBytes,
    required this.degraded,
    required this.filename,
    this.completedAt,
    this.error,
  });

  factory CanRecording.fromJson(Map<String, Object?> json) => CanRecording(
    state: CanRecordingState.values.byName(_requiredString(json, 'state')),
    recordingId: _requiredString(json, 'recording_id'),
    sessionId: _requiredString(json, 'session_id'),
    interfaceName: _requiredString(json, 'interface'),
    startedAt: DateTime.parse(_requiredString(json, 'started_at')),
    completedAt: _optionalDateTime(json['completed_at']),
    recordedFrames: _requiredInt(json, 'recorded_frames'),
    unsupportedFrames: _requiredInt(json, 'unsupported_frames'),
    unsupportedCanFd: _requiredInt(json, 'unsupported_can_fd'),
    unsupportedRemoteFrames: _requiredInt(json, 'unsupported_remote_frames'),
    unsupportedErrorFrames: _requiredInt(json, 'unsupported_error_frames'),
    droppedFrames: _requiredInt(json, 'dropped_frames'),
    sizeBytes: _requiredInt(json, 'size_bytes'),
    degraded: json['degraded'] as bool? ?? false,
    filename: _requiredString(json, 'filename'),
    error: json['error'] as String?,
  );

  final CanRecordingState state;
  final String recordingId;
  final String sessionId;
  final String interfaceName;
  final DateTime startedAt;
  final DateTime? completedAt;
  final int recordedFrames;
  final int unsupportedFrames;
  final int unsupportedCanFd;
  final int unsupportedRemoteFrames;
  final int unsupportedErrorFrames;
  final int droppedFrames;
  final int sizeBytes;
  final bool degraded;
  final String filename;
  final String? error;

  bool get isActive => const {
    CanRecordingState.recording,
    CanRecordingState.paused,
    CanRecordingState.finalizing,
  }.contains(state);
}

class CanCrcConfig {
  const CanCrcConfig({
    required this.algorithm,
    required this.rangeStart,
    required this.rangeEnd,
    required this.position,
    this.byteOrder = 'big',
    this.width,
    this.polynomial,
    this.initialValue,
    this.xorOut,
    this.reflectInput,
    this.reflectOutput,
  });

  final String algorithm;
  final int rangeStart;
  final int rangeEnd;
  final int position;
  final String byteOrder;
  final int? width;
  final int? polynomial;
  final int? initialValue;
  final int? xorOut;
  final bool? reflectInput;
  final bool? reflectOutput;

  Map<String, Object?> toJson() => {
    'algorithm': algorithm,
    'range_start': rangeStart,
    'range_end': rangeEnd,
    'position': position,
    'byte_order': byteOrder,
    if (algorithm == 'CUSTOM') ...{
      'width': width,
      'polynomial': polynomial,
      'initial_value': initialValue,
      'xor_out': xorOut,
      'reflect_input': reflectInput,
      'reflect_output': reflectOutput,
    },
  };
}

class CanTransmissionMessageConfig {
  const CanTransmissionMessageConfig({
    required this.messageId,
    required this.enabled,
    required this.canId,
    required this.isExtended,
    required this.isFd,
    required this.dataHex,
    required this.mode,
    this.periodMs,
    this.crc,
  });

  final String messageId;
  final bool enabled;
  final int canId;
  final bool isExtended;
  final bool isFd;
  final String dataHex;
  final CanTransmissionMode mode;
  final double? periodMs;
  final CanCrcConfig? crc;

  double? get frequencyHz => periodMs == null ? null : 1000 / periodMs!;

  CanTransmissionMessageConfig copyWith({String? messageId, bool? enabled}) =>
      CanTransmissionMessageConfig(
        messageId: messageId ?? this.messageId,
        enabled: enabled ?? this.enabled,
        canId: canId,
        isExtended: isExtended,
        isFd: isFd,
        dataHex: dataHex,
        mode: mode,
        periodMs: periodMs,
        crc: crc,
      );

  Map<String, Object?> toJson() => {
    'message_id': messageId,
    'enabled': enabled,
    'can_id': canId,
    'is_extended_id': isExtended,
    'is_fd': isFd,
    'data_hex': dataHex.replaceAll(RegExp(r'\s+'), '').toUpperCase(),
    'mode': mode.name,
    if (periodMs != null) 'period_ms': periodMs,
    if (crc != null) 'crc': crc!.toJson(),
  };
}

class CanTransmissionMessageStatus {
  const CanTransmissionMessageStatus({
    required this.messageId,
    required this.state,
    required this.sentFrames,
    required this.sendErrors,
    required this.deadlineMisses,
    this.lastTransmission,
    this.lastError,
  });

  factory CanTransmissionMessageStatus.fromJson(Map<String, Object?> json) =>
      CanTransmissionMessageStatus(
        messageId: _requiredString(json, 'message_id'),
        state: _requiredString(json, 'state'),
        sentFrames: _requiredInt(json, 'sent_frames'),
        sendErrors: _requiredInt(json, 'send_errors'),
        deadlineMisses: _requiredInt(json, 'deadline_misses'),
        lastTransmission: _optionalDateTime(json['last_transmission']),
        lastError: json['last_error'] as String?,
      );

  final String messageId;
  final String state;
  final int sentFrames;
  final int sendErrors;
  final int deadlineMisses;
  final DateTime? lastTransmission;
  final String? lastError;
}

class CanTransmissionStatus {
  const CanTransmissionStatus({
    required this.planId,
    required this.sessionId,
    required this.interfaceName,
    required this.state,
    required this.messages,
    required this.sentFrames,
    required this.sendErrors,
    required this.deadlineMisses,
    this.estimatedBusLoadPercent,
  });

  factory CanTransmissionStatus.fromJson(Map<String, Object?> json) {
    final rawMessages = json['messages'];
    if (rawMessages is! List) {
      throw const FormatException('Telemetria de transmissão inválida.');
    }
    return CanTransmissionStatus(
      planId: _requiredString(json, 'plan_id'),
      sessionId: _requiredString(json, 'session_id'),
      interfaceName: _requiredString(json, 'interface'),
      state: CanTransmissionState.values.byName(_requiredString(json, 'state')),
      messages: rawMessages
          .map(
            (item) => CanTransmissionMessageStatus.fromJson(
              Map<String, Object?>.from(item as Map),
            ),
          )
          .toList(growable: false),
      sentFrames: _requiredInt(json, 'sent_frames'),
      sendErrors: _requiredInt(json, 'send_errors'),
      deadlineMisses: _requiredInt(json, 'deadline_misses'),
      estimatedBusLoadPercent: (json['estimated_bus_load_percent'] as num?)
          ?.toDouble(),
    );
  }

  final String planId;
  final String sessionId;
  final String interfaceName;
  final CanTransmissionState state;
  final List<CanTransmissionMessageStatus> messages;
  final int sentFrames;
  final int sendErrors;
  final int deadlineMisses;
  final double? estimatedBusLoadPercent;
}

class CanTransmissionPreview {
  const CanTransmissionPreview({required this.payloadHex, this.crcValue});

  factory CanTransmissionPreview.fromJson(Map<String, Object?> json) =>
      CanTransmissionPreview(
        payloadHex: _requiredString(json, 'payload_hex', allowEmpty: true),
        crcValue: (json['crc_value'] as num?)?.toInt(),
      );

  final String payloadHex;
  final int? crcValue;
}

class CanFrameBatch {
  const CanFrameBatch({
    required this.version,
    required this.frames,
    required this.streamDroppedFrames,
    required this.adapterDroppedFrames,
  });

  final int version;
  final List<CanFrame> frames;
  final int streamDroppedFrames;
  final int adapterDroppedFrames;
}

class CanIdStats {
  CanIdStats.fromFrame(CanFrame frame)
    : canId = frame.canId,
      isExtended = frame.isExtended,
      direction = frame.direction,
      lastFrame = frame,
      count = 1;

  final int canId;
  final bool isExtended;
  final CanDirection direction;
  CanFrame lastFrame;
  int count;
  double? lastIntervalMs;
  double meanIntervalMs = 0;
  double minIntervalMs = double.infinity;
  double maxIntervalMs = 0;

  void add(CanFrame frame) {
    final interval =
        (frame.timingNanoseconds - lastFrame.timingNanoseconds).toDouble() /
        1000000;
    lastFrame = frame;
    count += 1;
    lastIntervalMs = interval;
    meanIntervalMs += (interval - meanIntervalMs) / (count - 1);
    if (interval < minIntervalMs) minIntervalMs = interval;
    if (interval > maxIntervalMs) maxIntervalMs = interval;
  }

  double? get rateHz => meanIntervalMs > 0 ? 1000 / meanIntervalMs : null;

  CanIdStats snapshot() {
    final copy = CanIdStats.fromFrame(lastFrame);
    copy.count = count;
    copy.lastIntervalMs = lastIntervalMs;
    copy.meanIntervalMs = meanIntervalMs;
    copy.minIntervalMs = minIntervalMs;
    copy.maxIntervalMs = maxIntervalMs;
    return copy;
  }
}

Uint8List parseHexBytes(String input) {
  final compact = input.replaceAll(RegExp(r'[\s:_-]'), '');
  if (compact.isEmpty) return Uint8List(0);
  if (compact.length.isOdd || !RegExp(r'^[0-9a-fA-F]+$').hasMatch(compact)) {
    throw const FormatException('Payload deve conter pares hexadecimais.');
  }
  return Uint8List.fromList([
    for (var index = 0; index < compact.length; index += 2)
      int.parse(compact.substring(index, index + 2), radix: 16),
  ]);
}

int parseCanId(String input, {required bool extended}) {
  final value = input.trim().toLowerCase();
  final normalized = value.startsWith('0x') ? value.substring(2) : value;
  if (normalized.isEmpty || !RegExp(r'^[0-9a-f]+$').hasMatch(normalized)) {
    throw const FormatException('Informe um ID hexadecimal válido.');
  }
  final result = int.parse(normalized, radix: 16);
  final maximum = extended ? 0x1FFFFFFF : 0x7FF;
  if (result > maximum) {
    throw FormatException(
      extended
          ? 'ID estendido deve ser <= 0x1FFFFFFF.'
          : 'ID standard deve ser <= 0x7FF.',
    );
  }
  return result;
}

String? validatePayloadLength(int length, {required bool isFd}) {
  const fdLengths = {0, 1, 2, 3, 4, 5, 6, 7, 8, 12, 16, 20, 24, 32, 48, 64};
  if (isFd && !fdLengths.contains(length)) {
    return 'CAN FD aceita 0..8, 12, 16, 20, 24, 32, 48 ou 64 bytes.';
  }
  if (!isFd && length > 8) {
    return 'CAN clássico aceita no máximo 8 bytes.';
  }
  return null;
}

String _requiredString(
  Map<String, Object?> json,
  String key, {
  bool allowEmpty = false,
}) {
  final value = json[key];
  if (value is! String || (!allowEmpty && value.isEmpty)) {
    throw FormatException('$key ausente ou inválido.');
  }
  return value;
}

int _requiredInt(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! num) throw FormatException('$key ausente ou inválido.');
  return value.toInt();
}

BigInt _requiredBigInt(Map<String, Object?> json, String key) {
  final value = json[key];
  return switch (value) {
    String raw => BigInt.parse(raw),
    int raw => BigInt.from(raw),
    _ => throw FormatException('$key ausente ou inválido.'),
  };
}

DateTime? _optionalDateTime(Object? value) => switch (value) {
  String raw => DateTime.parse(raw),
  _ => null,
};
