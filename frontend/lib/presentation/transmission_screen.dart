import 'dart:async';

import 'package:flutter/material.dart';

import '../application/can_monitor_controller.dart';
import '../domain/can_models.dart';

const _crcAlgorithms = [
  'CRC-8/SAE-J1850',
  'CRC-8/AUTOSAR',
  'CRC-8/HITAG',
  'CRC-8/MAXIM-DOW',
  'CRC-16/CCITT-FALSE',
  'CRC-16/ARC',
  'CRC-32/ISO-HDLC',
  'CUSTOM',
];

class TransmissionScreen extends StatefulWidget {
  const TransmissionScreen({super.key, required this.controller});

  static const routeName = '/transmission';
  final CanMonitorController controller;

  @override
  State<TransmissionScreen> createState() => _TransmissionScreenState();
}

class _TransmissionScreenState extends State<TransmissionScreen> {
  String? _selectedMessageId;

  CanMonitorController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    if (controller.transmissionMessages.isNotEmpty) {
      _selectedMessageId = controller.transmissionMessages.first.messageId;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(controller.loadPhysicalTxEnabled());
    });
  }

  CanTransmissionMessageConfig? get _selectedMessage {
    for (final message in controller.transmissionMessages) {
      if (message.messageId == _selectedMessageId) return message;
    }
    return null;
  }

  void _addMessage() {
    final message = CanTransmissionMessageConfig(
      messageId: controller.nextTransmissionMessageId(),
      enabled: true,
      canId: 0x123,
      isExtended: false,
      isFd: false,
      dataHex: '01 02 03 04',
      mode: CanTransmissionMode.single,
    );
    controller.addTransmissionMessage(message);
    setState(() => _selectedMessageId = message.messageId);
  }

  void _selectMessage(CanTransmissionMessageConfig message) {
    setState(() => _selectedMessageId = message.messageId);
  }

  void _duplicateMessage(CanTransmissionMessageConfig source) {
    final duplicate = source.copyWith(
      messageId: controller.nextTransmissionMessageId(),
    );
    controller.addTransmissionMessage(duplicate);
    setState(() => _selectedMessageId = duplicate.messageId);
  }

  void _removeMessage(CanTransmissionMessageConfig message) {
    final index = controller.transmissionMessages.indexOf(message);
    controller.removeTransmissionMessage(message.messageId);
    final remaining = controller.transmissionMessages;
    setState(() {
      if (_selectedMessageId == message.messageId) {
        _selectedMessageId = remaining.isEmpty
            ? null
            : remaining[index.clamp(0, remaining.length - 1)].messageId;
      }
    });
  }

  Future<bool> _confirm(String title, Widget content, Key key) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: content,
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              key: key,
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Confirmar'),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _sendOnce() async {
    final enabled = controller.transmissionMessages
        .where((item) => item.enabled)
        .toList(growable: false);
    if (enabled.isEmpty) return;
    final accepted = await _confirm(
      'Confirmar envio único',
      Text(
        'Enviar ${enabled.length} mensagem(ns) uma vez pela interface '
        '${controller.activeInterfaceName}?\n\n${_messageReview(enabled)}',
      ),
      const Key('confirm-send-once'),
    );
    if (accepted) await controller.sendTransmissionOnce();
  }

  Future<void> _reviewAndStart() async {
    final status = await controller.configureTransmission();
    if (!mounted || status == null) return;
    final enabled = controller.transmissionMessages
        .where((item) => item.enabled)
        .toList(growable: false);
    final load = status.estimatedBusLoadPercent;
    final accepted = await _confirm(
      'Revisar transmissão CAN',
      SingleChildScrollView(
        child: Text(
          'Interface: ${status.interfaceName}\n'
          'Mensagens habilitadas: ${enabled.length}\n'
          '${load == null ? 'Carga estimada: indisponível (bitrate desconhecido ou CAN FD)' : 'Carga estimada: ${load.toStringAsFixed(2)}%'}\n\n'
          '${_messageReview(enabled)}\n\n'
          'A transmissão CAN pode atuar sobre equipamentos reais.',
        ),
      ),
      const Key('confirm-transmission-start'),
    );
    if (accepted) await controller.startConfiguredTransmission();
  }

  Future<void> _setPhysicalTxEnabled(bool enabled) async {
    if (enabled) {
      final accepted = await _confirm(
        'Habilitar transmissão física?',
        const Text(
          'Isso permitirá enviar frames em interfaces CAN físicas enquanto '
          'esta aplicação estiver em execução.',
        ),
        const Key('confirm-enable-physical-tx'),
      );
      if (!accepted) return;
    }
    await controller.setPhysicalTxEnabled(enabled);
  }

  String _messageReview(List<CanTransmissionMessageConfig> messages) => messages
      .map(
        (item) =>
            '${item.isExtended ? 'EXT' : 'STD'} ${_formattedId(item)} · '
            '${item.isFd ? 'CAN FD' : 'CAN'} · '
            '${item.mode == CanTransmissionMode.single ? 'único' : '${item.frequencyHz!.toStringAsFixed(2)} Hz'} · '
            'CRC ${item.crc?.algorithm ?? 'desativado'}',
      )
      .join('\n');

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final active = const {
          CanTransmissionState.running,
          CanTransmissionState.paused,
        }.contains(controller.transmissionStatus?.state);
        return Scaffold(
          appBar: AppBar(
            leading: BackButton(
              key: const Key('back-to-monitor'),
              onPressed: () =>
                  Navigator.of(context).popUntil((route) => route.isFirst),
            ),
            title: const Row(
              children: [
                Icon(Icons.send_outlined),
                SizedBox(width: 10),
                Text('Transmissão CAN'),
              ],
            ),
            actions: [
              Padding(
                padding: const EdgeInsets.only(right: 16),
                child: Chip(
                  avatar: Icon(
                    controller.isConnected ? Icons.link : Icons.link_off,
                    color: controller.isConnected ? Colors.green : Colors.grey,
                  ),
                  label: Text(
                    controller.isConnected ? 'Conectado' : 'Desconectado',
                  ),
                ),
              ),
            ],
          ),
          body: SafeArea(
            child: Column(
              children: [
                if (controller.lastError case final error?)
                  MaterialBanner(
                    content: Text(error),
                    leading: const Icon(Icons.error_outline),
                    actions: [
                      TextButton(
                        onPressed: controller.clearError,
                        child: const Text('FECHAR'),
                      ),
                    ],
                  ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.all(24),
                    children: [
                      Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 1600),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _HeaderAndControls(
                                controller: controller,
                                active: active,
                                controls: _controls(active),
                                onAdd: _addMessage,
                                onPhysicalTxChanged: _setPhysicalTxEnabled,
                              ),
                              const SizedBox(height: 18),
                              LayoutBuilder(
                                builder: (context, constraints) {
                                  final selected = _selectedMessage;
                                  final list = Column(
                                    children: [
                                      _MessageList(
                                        controller: controller,
                                        selectedMessageId: _selectedMessageId,
                                        onSelected: _selectMessage,
                                        onDuplicate: _duplicateMessage,
                                        onRemove: _removeMessage,
                                        locked: active,
                                      ),
                                      const SizedBox(height: 14),
                                      _TelemetryCard(
                                        status: controller.transmissionStatus,
                                      ),
                                    ],
                                  );
                                  final editor = selected == null
                                      ? const _EmptyEditor()
                                      : _MessageEditor(
                                          key: ObjectKey(selected),
                                          controller: controller,
                                          initial: selected,
                                          locked: active,
                                          onSaved: controller
                                              .updateTransmissionMessage,
                                        );
                                  if (constraints.maxWidth >= 1250) {
                                    return Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Expanded(flex: 3, child: list),
                                        const SizedBox(width: 18),
                                        Expanded(flex: 2, child: editor),
                                      ],
                                    );
                                  }
                                  return Column(
                                    children: [
                                      list,
                                      const SizedBox(height: 18),
                                      editor,
                                    ],
                                  );
                                },
                              ),
                              const SizedBox(height: 16),
                              const _SafetyCard(),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  List<Widget> _controls(bool active) {
    final state = controller.transmissionStatus?.state;
    final canSubmit =
        controller.isConnected &&
        controller.transmissionEnabledForActiveInterface &&
        controller.transmissionMessages.any((item) => item.enabled) &&
        !controller.transmissionAction;
    return [
      OutlinedButton.icon(
        key: const Key('send-once'),
        onPressed: !active && canSubmit ? _sendOnce : null,
        icon: const Icon(Icons.send),
        label: const Text('Enviar uma vez'),
      ),
      if (!active)
        FilledButton.icon(
          key: const Key('review-start-transmission'),
          onPressed: canSubmit ? _reviewAndStart : null,
          icon: const Icon(Icons.play_arrow),
          label: const Text('Revisar e iniciar'),
        ),
      if (state == CanTransmissionState.running)
        OutlinedButton.icon(
          key: const Key('pause-transmission'),
          onPressed: controller.transmissionAction
              ? null
              : controller.pauseTransmission,
          icon: const Icon(Icons.pause),
          label: const Text('Pausar'),
        ),
      if (state == CanTransmissionState.paused)
        FilledButton.tonalIcon(
          key: const Key('resume-transmission'),
          onPressed: controller.transmissionAction
              ? null
              : controller.resumeTransmission,
          icon: const Icon(Icons.play_arrow),
          label: const Text('Retomar'),
        ),
      if (active)
        OutlinedButton.icon(
          key: const Key('stop-transmission'),
          onPressed: controller.transmissionAction
              ? null
              : controller.stopTransmission,
          icon: const Icon(Icons.stop),
          label: const Text('Parar'),
        ),
    ];
  }
}

class _HeaderAndControls extends StatelessWidget {
  const _HeaderAndControls({
    required this.controller,
    required this.active,
    required this.controls,
    required this.onAdd,
    required this.onPhysicalTxChanged,
  });

  final CanMonitorController controller;
  final bool active;
  final List<Widget> controls;
  final VoidCallback onAdd;
  final ValueChanged<bool> onPhysicalTxChanged;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        'Transmissão CAN',
        style: Theme.of(context).textTheme.headlineMedium,
      ),
      const SizedBox(height: 6),
      const Text(
        'Configure mensagens únicas ou cíclicas. O agendamento e o CRC são '
        'executados no backend.',
      ),
      const SizedBox(height: 16),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 10,
                runSpacing: 10,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  FilledButton.icon(
                    key: const Key('add-transmission-message'),
                    onPressed: active ? null : onAdd,
                    icon: const Icon(Icons.add),
                    label: const Text('Adicionar mensagem'),
                  ),
                  ...controls,
                  OutlinedButton.icon(
                    key: const Key('stop-all-transmissions'),
                    onPressed: active && !controller.transmissionAction
                        ? controller.stopAllTransmissions
                        : null,
                    icon: const Icon(Icons.stop_circle_outlined),
                    label: const Text('Parar todas'),
                  ),
                ],
              ),
              const Divider(height: 24),
              SwitchListTile(
                key: const Key('physical-tx-toggle'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Transmissão física'),
                subtitle: Text(
                  controller.physicalTxStateLoading
                      ? 'Consultando estado do backend...'
                      : controller.activeInterfaceIsVirtual
                      ? 'Interface virtual: este controle afeta apenas CAN física.'
                      : controller.physicalTxEnabled
                      ? 'Habilitada no backend.'
                      : 'Desabilitada no backend; os controles de envio estão bloqueados.',
                ),
                value: controller.physicalTxEnabled,
                onChanged:
                    controller.physicalTxStateLoading ||
                        controller.physicalTxUpdating
                    ? null
                    : onPhysicalTxChanged,
              ),
              if (!controller.isConnected) ...[
                const SizedBox(height: 10),
                const Text('Conecte uma sessão no Monitor para transmitir.'),
              ],
            ],
          ),
        ),
      ),
    ],
  );
}

class _EmptyEditor extends StatelessWidget {
  const _EmptyEditor();

  @override
  Widget build(BuildContext context) => const Card(
    key: Key('inline-message-editor-empty'),
    child: Padding(
      padding: EdgeInsets.all(32),
      child: Center(
        child: Text(
          'Adicione ou selecione uma mensagem para editar seus parâmetros.',
          textAlign: TextAlign.center,
        ),
      ),
    ),
  );
}

class _MessageList extends StatelessWidget {
  const _MessageList({
    required this.controller,
    required this.selectedMessageId,
    required this.onSelected,
    required this.onDuplicate,
    required this.onRemove,
    required this.locked,
  });

  final CanMonitorController controller;
  final String? selectedMessageId;
  final ValueChanged<CanTransmissionMessageConfig> onSelected;
  final ValueChanged<CanTransmissionMessageConfig> onDuplicate;
  final ValueChanged<CanTransmissionMessageConfig> onRemove;
  final bool locked;

  @override
  Widget build(BuildContext context) {
    if (controller.transmissionMessages.isEmpty) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Center(child: Text('Nenhuma mensagem configurada.')),
        ),
      );
    }
    final statuses = {
      for (final item in controller.transmissionStatus?.messages ?? const [])
        item.messageId: item,
    };
    return Card(
      child: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: constraints.maxWidth < 1050 ? 1050 : constraints.maxWidth,
            child: Column(
              children: [
                for (final message in controller.transmissionMessages)
                  _MessageRow(
                    message: message,
                    status: statuses[message.messageId],
                    selected: selectedMessageId == message.messageId,
                    locked: locked,
                    onEnabled: (value) =>
                        controller.setTransmissionMessageEnabled(
                          message.messageId,
                          value,
                        ),
                    onSelected: () => onSelected(message),
                    onDuplicate: () => onDuplicate(message),
                    onRemove: () => onRemove(message),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MessageRow extends StatelessWidget {
  const _MessageRow({
    required this.message,
    required this.status,
    required this.selected,
    required this.locked,
    required this.onEnabled,
    required this.onSelected,
    required this.onDuplicate,
    required this.onRemove,
  });

  final CanTransmissionMessageConfig message;
  final CanTransmissionMessageStatus? status;
  final bool selected;
  final bool locked;
  final ValueChanged<bool> onEnabled;
  final VoidCallback onSelected;
  final VoidCallback onDuplicate;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) => InkWell(
    key: Key('transmission-message-${message.messageId}'),
    onTap: onSelected,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: selected
            ? Theme.of(
                context,
              ).colorScheme.primaryContainer.withValues(alpha: 0.28)
            : null,
        border: Border(
          left: BorderSide(
            color: selected
                ? Theme.of(context).colorScheme.primary
                : Colors.transparent,
            width: 3,
          ),
          bottom: const BorderSide(color: Colors.white12),
        ),
      ),
      child: Row(
        children: [
          Switch(value: message.enabled, onChanged: locked ? null : onEnabled),
          SizedBox(
            width: 105,
            child: Text(
              _formattedId(message),
              style: const TextStyle(fontFamily: 'monospace'),
            ),
          ),
          SizedBox(width: 62, child: Text(message.isExtended ? 'EXT' : 'STD')),
          Expanded(
            flex: 3,
            child: Text(
              _spacedHex(message.dataHex),
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontFamily: 'monospace'),
            ),
          ),
          Expanded(
            child: Text(
              message.mode == CanTransmissionMode.single
                  ? 'Único'
                  : '${message.frequencyHz!.toStringAsFixed(2)} Hz',
            ),
          ),
          Expanded(child: Text(message.crc?.algorithm ?? 'Sem CRC')),
          SizedBox(
            width: 90,
            child: Text(
              (status?.state ?? 'parada').toUpperCase(),
              style: TextStyle(
                color: status?.state == 'error' ? Colors.redAccent : null,
              ),
            ),
          ),
          Tooltip(
            message: [
              'Enviados ${status?.sentFrames ?? 0} · Erros ${status?.sendErrors ?? 0} · Misses ${status?.deadlineMisses ?? 0}',
              if (status?.lastTransmission case final timestamp?)
                'Último envio: ${timestamp.toLocal()}',
              if (status?.lastError case final error?) 'Último erro: $error',
            ].join('\n'),
            child: const Icon(Icons.query_stats, size: 18),
          ),
          IconButton(
            key: Key('edit-${message.messageId}'),
            tooltip: 'Selecionar para editar',
            onPressed: onSelected,
            icon: const Icon(Icons.edit_outlined),
          ),
          IconButton(
            tooltip: 'Duplicar',
            onPressed: locked ? null : onDuplicate,
            icon: const Icon(Icons.copy_outlined),
          ),
          IconButton(
            tooltip: 'Remover',
            onPressed: locked ? null : onRemove,
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
    ),
  );
}

class _TelemetryCard extends StatelessWidget {
  const _TelemetryCard({required this.status});
  final CanTransmissionStatus? status;

  @override
  Widget build(BuildContext context) {
    if (status == null) return const SizedBox.shrink();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Wrap(
          spacing: 24,
          runSpacing: 8,
          children: [
            Text('Estado: ${status!.state.name.toUpperCase()}'),
            Text('Enviados: ${status!.sentFrames}'),
            Text('Erros: ${status!.sendErrors}'),
            Text('Deadlines perdidos: ${status!.deadlineMisses}'),
            Text(
              status!.estimatedBusLoadPercent == null
                  ? 'Carga estimada: indisponível'
                  : 'Carga estimada: ${status!.estimatedBusLoadPercent!.toStringAsFixed(2)}%',
            ),
          ],
        ),
      ),
    );
  }
}

class _MessageEditor extends StatefulWidget {
  const _MessageEditor({
    required this.controller,
    required this.initial,
    required this.locked,
    required this.onSaved,
    super.key,
  });

  final CanMonitorController controller;
  final CanTransmissionMessageConfig initial;
  final bool locked;
  final ValueChanged<CanTransmissionMessageConfig> onSaved;

  @override
  State<_MessageEditor> createState() => _MessageEditorState();
}

class _MessageEditorState extends State<_MessageEditor> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _id;
  late final TextEditingController _payload;
  late final TextEditingController _rate;
  late final TextEditingController _rangeStart;
  late final TextEditingController _rangeEnd;
  late final TextEditingController _position;
  late final TextEditingController _polynomial;
  late final TextEditingController _initialValue;
  late final TextEditingController _xorOut;
  late bool _enabled;
  late bool _extended;
  late bool _fd;
  late CanTransmissionMode _mode;
  bool _rateInHz = true;
  late bool _crcEnabled;
  late String _algorithm;
  late int _width;
  late String _byteOrder;
  late bool _reflectInput;
  late bool _reflectOutput;
  CanTransmissionPreview? _preview;

  @override
  void initState() {
    super.initState();
    final value = widget.initial;
    final crc = value.crc;
    _id = TextEditingController(
      text: value.canId.toRadixString(16).toUpperCase(),
    );
    _payload = TextEditingController(text: value.dataHex);
    _rate = TextEditingController(
      text: value.frequencyHz?.toStringAsFixed(2) ?? '10',
    );
    _rangeStart = TextEditingController(text: '${crc?.rangeStart ?? 0}');
    _rangeEnd = TextEditingController(text: '${crc?.rangeEnd ?? 2}');
    _position = TextEditingController(text: '${crc?.position ?? 3}');
    _polynomial = TextEditingController(text: _hex(crc?.polynomial ?? 0x1D));
    _initialValue = TextEditingController(
      text: _hex(crc?.initialValue ?? 0xFF),
    );
    _xorOut = TextEditingController(text: _hex(crc?.xorOut ?? 0xFF));
    _enabled = value.enabled;
    _extended = value.isExtended;
    _fd = value.isFd;
    _mode = value.mode;
    _crcEnabled = crc != null;
    _algorithm = crc?.algorithm ?? _crcAlgorithms.first;
    _width = crc?.width ?? 8;
    _byteOrder = crc?.byteOrder ?? 'big';
    _reflectInput = crc?.reflectInput ?? false;
    _reflectOutput = crc?.reflectOutput ?? false;
  }

  @override
  void dispose() {
    for (final item in [
      _id,
      _payload,
      _rate,
      _rangeStart,
      _rangeEnd,
      _position,
      _polynomial,
      _initialValue,
      _xorOut,
    ]) {
      item.dispose();
    }
    super.dispose();
  }

  CanTransmissionMessageConfig? _buildValue() {
    if (!_formKey.currentState!.validate()) return null;
    final bytes = parseHexBytes(_payload.text);
    final isFd = _fd && widget.controller.activeSessionFd;
    final lengthError = validatePayloadLength(bytes.length, isFd: isFd);
    if (lengthError != null) {
      _showError(lengthError);
      return null;
    }
    double? period;
    if (_mode == CanTransmissionMode.cyclic) {
      final rate = double.parse(_rate.text.replaceAll(',', '.'));
      period = _rateInHz ? 1000 / rate : rate;
      if (period < 10 || period > 60000) {
        _showError('Use período entre 10 e 60000 ms (máximo de 100 Hz).');
        return null;
      }
    }
    CanCrcConfig? crc;
    if (_crcEnabled) {
      crc = CanCrcConfig(
        algorithm: _algorithm,
        rangeStart: int.parse(_rangeStart.text),
        rangeEnd: int.parse(_rangeEnd.text),
        position: int.parse(_position.text),
        byteOrder: _byteOrder,
        width: _algorithm == 'CUSTOM' ? _width : null,
        polynomial: _algorithm == 'CUSTOM' ? _parseHex(_polynomial.text) : null,
        initialValue: _algorithm == 'CUSTOM'
            ? _parseHex(_initialValue.text)
            : null,
        xorOut: _algorithm == 'CUSTOM' ? _parseHex(_xorOut.text) : null,
        reflectInput: _algorithm == 'CUSTOM' ? _reflectInput : null,
        reflectOutput: _algorithm == 'CUSTOM' ? _reflectOutput : null,
      );
      final crcWidth = _algorithm == 'CUSTOM'
          ? _width
          : _algorithm.startsWith('CRC-32')
          ? 32
          : _algorithm.startsWith('CRC-16')
          ? 16
          : 8;
      if (crc.rangeStart > crc.rangeEnd || crc.rangeEnd >= bytes.length) {
        _showError('Intervalo do CRC está fora do payload.');
        return null;
      }
      if (crc.position + crcWidth ~/ 8 > bytes.length) {
        _showError('Não há espaço no payload para inserir o CRC.');
        return null;
      }
    }
    return CanTransmissionMessageConfig(
      messageId: widget.initial.messageId,
      enabled: _enabled,
      canId: parseCanId(_id.text, extended: _extended),
      isExtended: _extended,
      isFd: isFd,
      dataHex: _spacedHex(_payload.text),
      mode: _mode,
      periodMs: period,
      crc: crc,
    );
  }

  Future<void> _updatePreview() async {
    final value = _buildValue();
    if (value == null) return;
    final preview = await widget.controller.previewTransmission(value);
    if (mounted && preview != null) setState(() => _preview = preview);
  }

  void _showError(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) => Card(
    key: const Key('inline-message-editor'),
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.tune),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Editar ${_formattedId(widget.initial)}',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              const Chip(label: Text('Editor na página')),
            ],
          ),
          if (widget.locked) ...[
            const SizedBox(height: 10),
            const Text(
              'Pare a transmissão para alterar esta configuração.',
              style: TextStyle(color: Colors.amber),
            ),
          ],
          const SizedBox(height: 12),
          AbsorbPointer(
            absorbing: widget.locked,
            child: Opacity(
              opacity: widget.locked ? 0.55 : 1,
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Mensagem habilitada'),
                      value: _enabled,
                      onChanged: (value) => setState(() => _enabled = value),
                    ),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: TextFormField(
                            key: const Key('tx-id-input'),
                            controller: _id,
                            decoration: const InputDecoration(
                              labelText: 'CAN ID (HEX)',
                            ),
                            validator: (value) {
                              try {
                                parseCanId(value ?? '', extended: _extended);
                                return null;
                              } on FormatException catch (error) {
                                return error.message;
                              }
                            },
                          ),
                        ),
                        const SizedBox(width: 10),
                        SizedBox(
                          width: 110,
                          child: DropdownButtonFormField<bool>(
                            initialValue: _extended,
                            decoration: const InputDecoration(
                              labelText: 'Tipo',
                            ),
                            items: const [
                              DropdownMenuItem(
                                value: false,
                                child: Text('STD'),
                              ),
                              DropdownMenuItem(value: true, child: Text('EXT')),
                            ],
                            onChanged: (value) =>
                                setState(() => _extended = value ?? false),
                          ),
                        ),
                        const SizedBox(width: 10),
                        SizedBox(
                          width: 110,
                          child: SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('CAN FD'),
                            value: _fd && widget.controller.activeSessionFd,
                            onChanged: widget.controller.activeSessionFd
                                ? (value) => setState(() => _fd = value)
                                : null,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      key: const Key('tx-payload-input'),
                      controller: _payload,
                      decoration: const InputDecoration(
                        labelText: 'Payload hexadecimal',
                        hintText: '01 02 03 04',
                      ),
                      minLines: 2,
                      maxLines: 4,
                      validator: (value) {
                        try {
                          parseHexBytes(value ?? '');
                          return null;
                        } on FormatException catch (error) {
                          return error.message;
                        }
                      },
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: DropdownButtonFormField<CanTransmissionMode>(
                            key: const Key('tx-mode-selector'),
                            initialValue: _mode,
                            decoration: const InputDecoration(
                              labelText: 'Modo',
                            ),
                            items: const [
                              DropdownMenuItem(
                                value: CanTransmissionMode.single,
                                child: Text('Único'),
                              ),
                              DropdownMenuItem(
                                value: CanTransmissionMode.cyclic,
                                child: Text('Cíclico'),
                              ),
                            ],
                            onChanged: (value) =>
                                setState(() => _mode = value ?? _mode),
                          ),
                        ),
                        if (_mode == CanTransmissionMode.cyclic) ...[
                          const SizedBox(width: 10),
                          Expanded(
                            child: TextFormField(
                              key: const Key('tx-rate-input'),
                              controller: _rate,
                              decoration: InputDecoration(
                                labelText: _rateInHz
                                    ? 'Frequência (Hz)'
                                    : 'Período (ms)',
                              ),
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                    decimal: true,
                                  ),
                              validator: _positiveNumber,
                            ),
                          ),
                          const SizedBox(width: 10),
                          SegmentedButton<bool>(
                            segments: const [
                              ButtonSegment(value: true, label: Text('Hz')),
                              ButtonSegment(value: false, label: Text('ms')),
                            ],
                            selected: {_rateInHz},
                            onSelectionChanged: (selection) {
                              final current = double.tryParse(
                                _rate.text.replaceAll(',', '.'),
                              );
                              setState(() {
                                if (current != null && current > 0) {
                                  _rate.text = (1000 / current).toStringAsFixed(
                                    3,
                                  );
                                }
                                _rateInHz = selection.first;
                              });
                            },
                          ),
                        ],
                      ],
                    ),
                    const Divider(height: 30),
                    SwitchListTile(
                      key: const Key('crc-enabled'),
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Calcular CRC automaticamente'),
                      subtitle: const Text(
                        'Recalculado no backend antes de cada envio.',
                      ),
                      value: _crcEnabled,
                      onChanged: (value) => setState(() {
                        _crcEnabled = value;
                        _preview = null;
                      }),
                    ),
                    if (_crcEnabled) ..._crcFields(),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              key: const Key('save-transmission-message'),
              onPressed: widget.locked
                  ? null
                  : () {
                      final value = _buildValue();
                      if (value != null) widget.onSaved(value);
                    },
              icon: const Icon(Icons.check),
              label: const Text('Aplicar alterações'),
            ),
          ),
        ],
      ),
    ),
  );

  List<Widget> _crcFields() => [
    DropdownButtonFormField<String>(
      key: const Key('crc-algorithm'),
      initialValue: _algorithm,
      decoration: const InputDecoration(labelText: 'Algoritmo CRC'),
      items: _crcAlgorithms
          .map((value) => DropdownMenuItem(value: value, child: Text(value)))
          .toList(growable: false),
      onChanged: (value) => setState(() {
        _algorithm = value ?? _algorithm;
        _preview = null;
      }),
    ),
    if (_algorithm == 'CUSTOM') ...[
      const SizedBox(height: 10),
      DropdownButtonFormField<int>(
        key: const Key('crc-width'),
        initialValue: _width,
        decoration: const InputDecoration(labelText: 'Largura'),
        items: const [
          DropdownMenuItem(value: 8, child: Text('8 bits')),
          DropdownMenuItem(value: 16, child: Text('16 bits')),
          DropdownMenuItem(value: 32, child: Text('32 bits')),
        ],
        onChanged: (value) => setState(() => _width = value ?? 8),
      ),
      const SizedBox(height: 10),
      Row(
        children: [
          Expanded(
            child: _hexField('Polynomial', _polynomial, mustBePositive: true),
          ),
          const SizedBox(width: 8),
          Expanded(child: _hexField('Initial value', _initialValue)),
          const SizedBox(width: 8),
          Expanded(child: _hexField('XorOut', _xorOut)),
        ],
      ),
      Row(
        children: [
          Expanded(
            child: CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('RefIn'),
              value: _reflectInput,
              onChanged: (value) =>
                  setState(() => _reflectInput = value ?? false),
            ),
          ),
          Expanded(
            child: CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('RefOut'),
              value: _reflectOutput,
              onChanged: (value) =>
                  setState(() => _reflectOutput = value ?? false),
            ),
          ),
        ],
      ),
    ],
    const SizedBox(height: 10),
    Row(
      children: [
        Expanded(child: _integerField('Byte inicial', _rangeStart)),
        const SizedBox(width: 8),
        Expanded(child: _integerField('Byte final', _rangeEnd)),
        const SizedBox(width: 8),
        Expanded(child: _integerField('Posição do CRC', _position)),
      ],
    ),
    if (_algorithm.startsWith('CRC-16') ||
        _algorithm.startsWith('CRC-32') ||
        (_algorithm == 'CUSTOM' && _width > 8)) ...[
      const SizedBox(height: 10),
      DropdownButtonFormField<String>(
        initialValue: _byteOrder,
        decoration: const InputDecoration(labelText: 'Ordem de armazenamento'),
        items: const [
          DropdownMenuItem(value: 'big', child: Text('Big Endian')),
          DropdownMenuItem(value: 'little', child: Text('Little Endian')),
        ],
        onChanged: (value) => setState(() => _byteOrder = value ?? 'big'),
      ),
    ],
    const SizedBox(height: 12),
    OutlinedButton.icon(
      key: const Key('preview-crc'),
      onPressed: widget.controller.isConnected ? _updatePreview : null,
      icon: const Icon(Icons.calculate_outlined),
      label: const Text('Atualizar prévia do CRC'),
    ),
    if (_preview case final preview?) ...[
      const SizedBox(height: 12),
      Container(
        key: const Key('crc-preview'),
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        color: Colors.black26,
        child: Text(
          'Payload original: ${_spacedHex(_payload.text)}\n'
          'CRC: $_algorithm\n'
          'Bytes utilizados: ${_rangeStart.text}..${_rangeEnd.text}\n'
          'CRC calculado: ${preview.crcValue == null ? '—' : _hex(preview.crcValue!)}\n'
          'Payload transmitido: ${_spacedHex(preview.payloadHex)}',
          style: const TextStyle(fontFamily: 'monospace'),
        ),
      ),
    ],
  ];

  Widget _integerField(String label, TextEditingController controller) =>
      TextFormField(
        controller: controller,
        decoration: InputDecoration(labelText: label),
        keyboardType: TextInputType.number,
        validator: (value) {
          final parsed = int.tryParse(value ?? '');
          return parsed == null || parsed < 0
              ? 'Informe um inteiro não negativo.'
              : null;
        },
      );

  Widget _hexField(
    String label,
    TextEditingController controller, {
    bool mustBePositive = false,
  }) => TextFormField(
    controller: controller,
    decoration: InputDecoration(labelText: label, hintText: '0x1D'),
    validator: (value) {
      try {
        final parsed = _parseHex(value ?? '');
        if (mustBePositive && parsed == 0) return 'Use valor maior que zero.';
        if (parsed >= (1 << _width)) return 'Valor excede $_width bits.';
        return null;
      } catch (_) {
        return 'Hexadecimal inválido.';
      }
    },
  );
}

class _SafetyCard extends StatelessWidget {
  const _SafetyCard();

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.warning_amber_rounded,
            color: Theme.of(context).colorScheme.error,
          ),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              'A transmissão pode afetar equipamentos reais. Confira IDs, '
              'payloads, períodos e CRC. O backend mantém autorização e rate limit.',
            ),
          ),
        ],
      ),
    ),
  );
}

String? _positiveNumber(String? value) {
  final parsed = double.tryParse((value ?? '').replaceAll(',', '.'));
  return parsed == null || !parsed.isFinite || parsed <= 0
      ? 'Informe um valor positivo.'
      : null;
}

String _formattedId(CanTransmissionMessageConfig value) =>
    '0x${value.canId.toRadixString(16).toUpperCase().padLeft(value.isExtended ? 8 : 3, '0')}';

String _spacedHex(String value) {
  final compact = value.replaceAll(RegExp(r'[\s:_-]'), '').toUpperCase();
  return [
    for (var index = 0; index + 1 < compact.length; index += 2)
      compact.substring(index, index + 2),
  ].join(' ');
}

int _parseHex(String value) {
  final normalized = value.trim().toLowerCase();
  final digits = normalized.startsWith('0x')
      ? normalized.substring(2)
      : normalized;
  if (digits.isEmpty || !RegExp(r'^[0-9a-f]+$').hasMatch(digits)) {
    throw const FormatException('Hexadecimal inválido.');
  }
  return int.parse(digits, radix: 16);
}

String _hex(int value) => '0x${value.toRadixString(16).toUpperCase()}';
