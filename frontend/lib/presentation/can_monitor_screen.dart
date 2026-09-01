import 'package:flutter/material.dart';

import '../application/can_monitor_controller.dart';
import '../domain/can_models.dart';
import 'transmission_screen.dart';

class CanMonitorScreen extends StatelessWidget {
  const CanMonitorScreen({super.key, required this.controller});

  final CanMonitorController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => Scaffold(
        appBar: AppBar(
          title: const Row(
            children: [
              Icon(Icons.memory),
              SizedBox(width: 10),
              Text('CAN Monitor'),
            ],
          ),
          actions: [
            TextButton.icon(
              key: const Key('open-transmission'),
              onPressed: () =>
                  Navigator.of(context).pushNamed(TransmissionScreen.routeName),
              icon: const Icon(Icons.send_outlined),
              label: const Text('Transmissão'),
            ),
            const SizedBox(width: 8),
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: _ConnectionBadge(state: controller.connectionState),
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
              if (controller.displayPaused)
                Container(
                  key: const Key('paused-banner'),
                  width: double.infinity,
                  color: Colors.amber.shade900,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  child: Text(
                    'Tela congelada — aquisição ativa — '
                    '+${controller.framesWhilePaused} frames',
                  ),
                ),
              if (controller.streamDegraded)
                Container(
                  key: const Key('degraded-banner'),
                  width: double.infinity,
                  color: Colors.deepOrange.shade900,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  child: Text(
                    'Fluxo degradado — gaps: ${controller.sequenceGapFrames}, '
                    'duplicados/reordenados: '
                    '${controller.duplicateOrReorderedFrames}, '
                    'drops stream: ${controller.streamDroppedFrames}, '
                    'drops adapter: ${controller.adapterDroppedFrames}',
                  ),
                ),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    if (constraints.maxWidth >= 980) {
                      return Padding(
                        padding: const EdgeInsets.all(16),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            SizedBox(
                              width: 340,
                              child: SingleChildScrollView(
                                child: ConnectionPanel(controller: controller),
                              ),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: MonitorPanel(controller: controller),
                            ),
                          ],
                        ),
                      );
                    }
                    return ListView(
                      padding: const EdgeInsets.all(12),
                      children: [
                        ConnectionPanel(controller: controller),
                        const SizedBox(height: 12),
                        SizedBox(
                          height: 650,
                          child: MonitorPanel(controller: controller),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ConnectionBadge extends StatelessWidget {
  const _ConnectionBadge({required this.state});
  final MonitorConnectionState state;

  @override
  Widget build(BuildContext context) {
    final (label, color, icon) = switch (state) {
      MonitorConnectionState.disconnected => (
        'Desconectado',
        Colors.grey,
        Icons.link_off,
      ),
      MonitorConnectionState.connecting => (
        'Conectando',
        Colors.amber,
        Icons.sync,
      ),
      MonitorConnectionState.connected => (
        'Conectado',
        Colors.green,
        Icons.link,
      ),
      MonitorConnectionState.degraded => (
        'Degradado',
        Colors.deepOrange,
        Icons.warning_amber,
      ),
      MonitorConnectionState.recovering => (
        'Reconectando',
        Colors.amber,
        Icons.sync_problem,
      ),
      MonitorConnectionState.error => ('Erro', Colors.red, Icons.error_outline),
    };
    return Semantics(
      label: 'Estado da conexão: $label',
      child: Chip(
        avatar: Icon(icon, size: 18, color: color),
        label: Text(label),
        side: BorderSide(color: color),
      ),
    );
  }
}

class ConnectionPanel extends StatefulWidget {
  const ConnectionPanel({super.key, required this.controller});
  final CanMonitorController controller;

  @override
  State<ConnectionPanel> createState() => _ConnectionPanelState();
}

class _ConnectionPanelState extends State<ConnectionPanel> {
  final _filterController = TextEditingController();
  bool _extended = false;
  String? _filterError;

  @override
  void dispose() {
    _filterController.dispose();
    super.dispose();
  }

  void _addFilter() {
    try {
      final id = parseCanId(_filterController.text, extended: _extended);
      widget.controller.addFilter(
        CanFilterId(canId: id, isExtended: _extended),
      );
      setState(() {
        _filterError = null;
        _filterController.clear();
      });
    } on FormatException catch (error) {
      setState(() => _filterError = error.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Aquisição', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<CanInterfaceInfo>(
                    key: const Key('interface-selector'),
                    initialValue: controller.selectedInterface,
                    decoration: const InputDecoration(
                      labelText: 'Interface CAN',
                    ),
                    items: controller.interfaces
                        .map(
                          (item) => DropdownMenuItem(
                            value: item,
                            child: Text(
                              '${item.name} · ${item.state.toUpperCase()}',
                            ),
                          ),
                        )
                        .toList(growable: false),
                    onChanged:
                        controller.connectionState ==
                            MonitorConnectionState.disconnected
                        ? controller.selectInterface
                        : null,
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filledTonal(
                  key: const Key('reload-interfaces'),
                  tooltip: 'Atualizar interfaces',
                  onPressed: controller.loadingInterfaces
                      ? null
                      : controller.loadInterfaces,
                  icon: controller.loadingInterfaces
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh),
                ),
              ],
            ),
            if (controller.selectedInterface case final selected?) ...[
              const SizedBox(height: 8),
              Text(
                'Estado: ${selected.state.toUpperCase()} · Tipo: ${selected.type}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 12),
            SegmentedButton<bool>(
              key: const Key('session-format'),
              segments: const [
                ButtonSegment(value: false, label: Text('CAN clássico')),
                ButtonSegment(value: true, label: Text('CAN FD')),
              ],
              selected: {controller.selectedSessionFd},
              onSelectionChanged:
                  controller.connectionState ==
                          MonitorConnectionState.disconnected &&
                      controller.selectedInterface?.fdCapable != false
                  ? (selection) => controller.selectSessionFd(selection.first)
                  : null,
            ),
            const SizedBox(height: 18),
            Text(
              'Filtro de recepção',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (controller.appliedFilterRevision > 0)
              Text(
                'Aplicado · revisão ${controller.appliedFilterRevision}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            const SizedBox(height: 8),
            SegmentedButton<CanFilterMode>(
              segments: const [
                ButtonSegment(value: CanFilterMode.all, label: Text('ALL')),
                ButtonSegment(
                  value: CanFilterMode.filtered,
                  label: Text('IDs selecionados'),
                ),
              ],
              selected: {controller.filterMode},
              onSelectionChanged: controller.updatingFilters
                  ? null
                  : (selection) => controller.setFilterMode(selection.first),
            ),
            ...[
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextField(
                      key: const Key('filter-id-input'),
                      controller: _filterController,
                      decoration: InputDecoration(
                        labelText: 'CAN ID hexadecimal',
                        hintText: _extended ? '18FF50E5' : '123',
                        errorText: _filterError,
                      ),
                      onSubmitted: (_) => _addFilter(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  DropdownButton<bool>(
                    value: _extended,
                    items: const [
                      DropdownMenuItem(value: false, child: Text('STD')),
                      DropdownMenuItem(value: true, child: Text('EXT')),
                    ],
                    onChanged: (value) =>
                        setState(() => _extended = value ?? false),
                  ),
                  IconButton(
                    key: const Key('add-filter'),
                    tooltip: 'Adicionar filtro',
                    onPressed: controller.updatingFilters ? null : _addFilter,
                    icon: const Icon(Icons.add_circle_outline),
                  ),
                ],
              ),
              Wrap(
                spacing: 6,
                children: controller.filterIds
                    .map(
                      (id) => InputChip(
                        label: Text(id.label),
                        onDeleted: controller.updatingFilters
                            ? null
                            : () => controller.removeFilter(id),
                      ),
                    )
                    .toList(growable: false),
              ),
              if (controller.filterIds.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text('Adicione ao menos um ID para conectar.'),
                ),
            ],
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              child:
                  controller.connectionState ==
                          MonitorConnectionState.disconnected ||
                      controller.connectionState == MonitorConnectionState.error
                  ? FilledButton.icon(
                      key: const Key('connect-button'),
                      onPressed: controller.canConnect
                          ? controller.connect
                          : null,
                      icon: const Icon(Icons.link),
                      label: const Text('Conectar e monitorar'),
                    )
                  : OutlinedButton.icon(
                      key: const Key('disconnect-button'),
                      onPressed:
                          controller.connectionState ==
                              MonitorConnectionState.connecting
                          ? null
                          : controller.disconnect,
                      icon: const Icon(Icons.link_off),
                      label: const Text('Desconectar'),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class MonitorPanel extends StatefulWidget {
  const MonitorPanel({super.key, required this.controller});
  final CanMonitorController controller;

  @override
  State<MonitorPanel> createState() => _MonitorPanelState();
}

enum _PayloadRepresentation { none, binary, decimal }

extension on _PayloadRepresentation {
  String get label => switch (this) {
    _PayloadRepresentation.none => 'NONE',
    _PayloadRepresentation.binary => 'BIN',
    _PayloadRepresentation.decimal => 'DEC',
  };

  String? get columnLabel => switch (this) {
    _PayloadRepresentation.none => null,
    _PayloadRepresentation.binary => 'Dados BIN',
    _PayloadRepresentation.decimal => 'Dados DEC',
  };

  double get columnWidth => switch (this) {
    _PayloadRepresentation.none => 0,
    _PayloadRepresentation.binary => 620,
    _PayloadRepresentation.decimal => 385,
  };

  String format(CanFrame frame) => switch (this) {
    _PayloadRepresentation.none => '',
    _PayloadRepresentation.binary => frame.binaryText,
    _PayloadRepresentation.decimal => frame.decimalText,
  };
}

class _MonitorPanelState extends State<MonitorPanel> {
  final ScrollController _traceScrollController = ScrollController();
  bool _autoScroll = true;
  _PayloadRepresentation _payloadRepresentation = _PayloadRepresentation.none;
  bool _scrollScheduled = false;
  int? _lastVisibleSequence;

  CanMonitorController get controller => widget.controller;

  @override
  void dispose() {
    _traceScrollController.dispose();
    super.dispose();
  }

  void _scheduleScrollToLatest() {
    if (_scrollScheduled) return;
    _scrollScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollScheduled = false;
      if (!mounted || !_autoScroll || !_traceScrollController.hasClients) {
        return;
      }
      _traceScrollController.jumpTo(
        _traceScrollController.position.maxScrollExtent,
      );
    });
  }

  void _setAutoScroll(bool value) {
    setState(() => _autoScroll = value);
    final shouldPauseDisplay = !value;
    if (controller.displayPaused != shouldPauseDisplay) {
      controller.togglePause();
    }
    if (value) _scheduleScrollToLatest();
  }

  void _toggleDisplayPause() {
    final willPause = !controller.displayPaused;
    setState(() => _autoScroll = !willPause);
    controller.togglePause();
    if (!willPause) _scheduleScrollToLatest();
  }

  @override
  Widget build(BuildContext context) {
    final latestSequence = controller.visibleTrace.isEmpty
        ? null
        : controller.visibleTrace.last.sequence;
    if (_autoScroll && latestSequence != _lastVisibleSequence) {
      _scheduleScrollToLatest();
    }
    _lastVisibleSequence = latestSequence;

    return DefaultTabController(
      length: 2,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Monitor em tempo real',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        Text(
                          '${controller.receivedCount} frames recebidos · '
                          '${controller.overwrittenFrames} sobrescritos no buffer',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  OutlinedButton.icon(
                    key: const Key('pause-display'),
                    onPressed:
                        controller.isConnected || controller.displayPaused
                        ? _toggleDisplayPause
                        : null,
                    icon: Icon(
                      controller.displayPaused ? Icons.play_arrow : Icons.pause,
                    ),
                    label: Text(
                      controller.displayPaused
                          ? 'Retomar tela'
                          : 'Congelar tela',
                    ),
                  ),
                ],
              ),
              Align(
                alignment: Alignment.centerRight,
                child: Wrap(
                  spacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    _MonitorToggle(
                      label: 'Auto rolagem',
                      switchKey: const Key('auto-scroll-toggle'),
                      value: _autoScroll,
                      onChanged: _setAutoScroll,
                    ),
                    _PayloadRepresentationSelector(
                      value: _payloadRepresentation,
                      onChanged: (value) =>
                          setState(() => _payloadRepresentation = value),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              const TabBar(
                tabs: [
                  Tab(icon: Icon(Icons.list_alt), text: 'Trace'),
                  Tab(icon: Icon(Icons.view_list), text: 'Live IDs'),
                ],
              ),
              const SizedBox(height: 8),
              Expanded(
                child: TabBarView(
                  children: [
                    _TraceView(
                      controller: controller,
                      scrollController: _traceScrollController,
                      payloadRepresentation: _payloadRepresentation,
                    ),
                    _AggregatedView(
                      controller: controller,
                      payloadRepresentation: _payloadRepresentation,
                    ),
                  ],
                ),
              ),
              if (controller.selectedFrame case final frame?)
                _FrameInspector(
                  frame: frame,
                  onClose: () => controller.selectFrame(null),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MonitorToggle extends StatelessWidget {
  const _MonitorToggle({
    required this.label,
    required this.switchKey,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final Key switchKey;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(label, style: Theme.of(context).textTheme.bodyMedium),
      Switch(key: switchKey, value: value, onChanged: onChanged),
    ],
  );
}

class _PayloadRepresentationSelector extends StatelessWidget {
  const _PayloadRepresentationSelector({
    required this.value,
    required this.onChanged,
  });

  final _PayloadRepresentation value;
  final ValueChanged<_PayloadRepresentation> onChanged;

  @override
  Widget build(BuildContext context) => Padding(
    key: const Key('payload-representation-control'),
    padding: const EdgeInsets.only(right: 8),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Representação adicional',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(width: 8),
        SizedBox(
          key: const Key('payload-representation-field'),
          width: 104,
          child: DropdownButton<_PayloadRepresentation>(
            key: const Key('payload-representation-selector'),
            value: value,
            isExpanded: true,
            onChanged: (selected) {
              if (selected != null) onChanged(selected);
            },
            items: _PayloadRepresentation.values
                .map(
                  (representation) => DropdownMenuItem(
                    value: representation,
                    child: Text(representation.label),
                  ),
                )
                .toList(growable: false),
          ),
        ),
      ],
    ),
  );
}

class _TraceView extends StatelessWidget {
  const _TraceView({
    required this.controller,
    required this.scrollController,
    required this.payloadRepresentation,
  });
  final CanMonitorController controller;
  final ScrollController scrollController;
  final _PayloadRepresentation payloadRepresentation;

  @override
  Widget build(BuildContext context) {
    if (controller.visibleTrace.isEmpty) {
      return const _EmptyMonitor(
        message: 'Conecte a uma interface e aguarde frames CAN.',
      );
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SizedBox(
        width: 900 + payloadRepresentation.columnWidth,
        child: Column(
          children: [
            _TableHeader(
              columns: [
                const ('Tempo relativo', 130),
                const ('Dir.', 65),
                const ('ID', 120),
                const ('Tipo', 90),
                const ('DLC', 55),
                const ('Dados HEX', 400),
                if (payloadRepresentation.columnLabel case final label?)
                  (label, payloadRepresentation.columnWidth),
              ],
            ),
            Expanded(
              child: ListView.builder(
                key: const Key('trace-list'),
                controller: scrollController,
                itemCount: controller.visibleTrace.length,
                itemExtent: 42,
                itemBuilder: (context, index) {
                  final frame = controller.visibleTrace[index];
                  return InkWell(
                    key: Key('trace-frame-${frame.sequence}'),
                    onTap: () => controller.selectFrame(frame),
                    child: _DataRowCells(
                      error: frame.isErrorFrame,
                      columns: [
                        (
                          controller.relativeSeconds(frame).toStringAsFixed(6),
                          130,
                        ),
                        (frame.direction.name.toUpperCase(), 65),
                        (
                          '${frame.idText} ${frame.isExtended ? 'EXT' : 'STD'}',
                          120,
                        ),
                        (frame.isFd ? 'CAN FD' : 'CAN', 90),
                        ('${frame.dlc}', 55),
                        (
                          frame.isErrorFrame ? 'ERROR FRAME' : frame.hexText,
                          400,
                        ),
                        if (payloadRepresentation !=
                            _PayloadRepresentation.none)
                          (
                            frame.isErrorFrame
                                ? 'ERROR FRAME'
                                : payloadRepresentation.format(frame),
                            payloadRepresentation.columnWidth,
                          ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AggregatedView extends StatelessWidget {
  const _AggregatedView({
    required this.controller,
    required this.payloadRepresentation,
  });
  final CanMonitorController controller;
  final _PayloadRepresentation payloadRepresentation;

  @override
  Widget build(BuildContext context) {
    if (controller.visibleAggregates.isEmpty) {
      return const _EmptyMonitor(message: 'Nenhum CAN ID observado ainda.');
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SizedBox(
        width: 930 + payloadRepresentation.columnWidth,
        child: Column(
          children: [
            _TableHeader(
              columns: [
                const ('ID', 130),
                const ('Dir.', 60),
                const ('Count', 85),
                const ('Rate', 90),
                const ('Δ ID', 90),
                const ('Média', 90),
                const ('Dados HEX', 385),
                if (payloadRepresentation.columnLabel case final label?)
                  (label, payloadRepresentation.columnWidth),
              ],
            ),
            Expanded(
              child: ListView.builder(
                key: const Key('aggregate-list'),
                itemCount: controller.visibleAggregates.length,
                itemExtent: 42,
                itemBuilder: (context, index) {
                  final stats = controller.visibleAggregates[index];
                  final frame = stats.lastFrame;
                  return InkWell(
                    onTap: () => controller.selectFrame(frame),
                    child: _DataRowCells(
                      columns: [
                        (
                          '${frame.idText} ${stats.isExtended ? 'EXT' : 'STD'}',
                          130,
                        ),
                        (stats.direction.name.toUpperCase(), 60),
                        ('${stats.count}', 85),
                        (_number(stats.rateHz, 'Hz'), 90),
                        (_number(stats.lastIntervalMs, 'ms'), 90),
                        (_number(stats.meanIntervalMs, 'ms'), 90),
                        (frame.hexText, 385),
                        if (payloadRepresentation !=
                            _PayloadRepresentation.none)
                          (
                            payloadRepresentation.format(frame),
                            payloadRepresentation.columnWidth,
                          ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TableHeader extends StatelessWidget {
  const _TableHeader({required this.columns});
  final List<(String, double)> columns;

  @override
  Widget build(BuildContext context) => Container(
    height: 36,
    color: Theme.of(context).colorScheme.surfaceContainerHighest,
    child: Row(
      children: columns
          .map(
            (column) => SizedBox(
              width: column.$2,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
                child: Text(
                  column.$1,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ),
          )
          .toList(growable: false),
    ),
  );
}

class _DataRowCells extends StatelessWidget {
  const _DataRowCells({required this.columns, this.error = false});
  final List<(String, double)> columns;
  final bool error;

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: error ? Colors.red.withValues(alpha: 0.15) : null,
      border: Border(
        bottom: BorderSide(color: Colors.white.withValues(alpha: 0.06)),
      ),
    ),
    child: Row(
      children: columns
          .map(
            (column) => SizedBox(
              width: column.$2,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  column.$1,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
              ),
            ),
          )
          .toList(growable: false),
    ),
  );
}

class _FrameInspector extends StatelessWidget {
  const _FrameInspector({required this.frame, required this.onClose});
  final CanFrame frame;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(top: 8),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                '${frame.idText} · ${frame.isExtended ? 'EXT' : 'STD'} · '
                '${frame.isFd ? 'CAN FD' : 'CAN'} · '
                '${frame.direction.name.toUpperCase()}',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            IconButton(
              key: const Key('close-frame-inspector'),
              onPressed: onClose,
              tooltip: 'Fechar detalhes',
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              icon: const Icon(Icons.close, size: 18),
            ),
          ],
        ),
        const SizedBox(height: 6),
        SelectableText('HEX  ${frame.hexText}', style: _mono),
        SelectableText('BIN  ${frame.binaryText}', style: _mono),
        SelectableText(
          'timestamp_ns  ${frame.timestampNanoseconds}',
          style: _mono,
        ),
        SelectableText(
          'monotonic_ns  ${frame.ingressMonotonicNanoseconds} · '
          'seq ${frame.sequence} · filtro rev ${frame.filterRevision}',
          style: _mono,
        ),
      ],
    ),
  );
}

class _EmptyMonitor extends StatelessWidget {
  const _EmptyMonitor({required this.message});
  final String message;
  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.monitor_heart_outlined, size: 42),
        const SizedBox(height: 8),
        Text(message, textAlign: TextAlign.center),
      ],
    ),
  );
}

const _mono = TextStyle(fontFamily: 'monospace');

String _number(double? value, String unit) => value == null || !value.isFinite
    ? '—'
    : '${value.toStringAsFixed(2)} $unit';
