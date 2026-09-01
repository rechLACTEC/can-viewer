import 'package:flutter/material.dart';

import '../application/can_monitor_controller.dart';
import '../domain/can_models.dart';

class TransmissionScreen extends StatelessWidget {
  const TransmissionScreen({super.key, required this.controller});

  static const routeName = '/transmission';

  final CanMonitorController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => Scaffold(
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
                  size: 18,
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
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 1080),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Transmissão CAN',
                            style: Theme.of(context).textTheme.headlineMedium,
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Configure, revise e envie um frame pela sessão '
                            'CAN ativa.',
                            style: Theme.of(context).textTheme.bodyLarge,
                          ),
                          const SizedBox(height: 24),
                          LayoutBuilder(
                            builder: (context, constraints) {
                              final form = TransmissionForm(
                                controller: controller,
                              );
                              const safety = _TransmissionSafetyCard();
                              if (constraints.maxWidth >= 820) {
                                return Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Expanded(child: form),
                                    const SizedBox(width: 16),
                                    const SizedBox(width: 280, child: safety),
                                  ],
                                );
                              }
                              return Column(
                                children: [
                                  form,
                                  const SizedBox(height: 16),
                                  safety,
                                ],
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class TransmissionForm extends StatefulWidget {
  const TransmissionForm({super.key, required this.controller});

  final CanMonitorController controller;

  @override
  State<TransmissionForm> createState() => _TransmissionFormState();
}

class _TransmissionFormState extends State<TransmissionForm> {
  final _formKey = GlobalKey<FormState>();
  final _idController = TextEditingController();
  final _payloadController = TextEditingController();
  final _tokenController = TextEditingController();
  bool _extended = false;
  bool _fd = false;

  @override
  void dispose() {
    _idController.dispose();
    _payloadController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  Future<void> _confirmAndSend() async {
    if (!_formKey.currentState!.validate()) return;
    final isFd = _fd && widget.controller.activeSessionFd;
    final canId = parseCanId(_idController.text, extended: _extended);
    final bytes = parseHexBytes(_payloadController.text);
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Confirmar transmissão CAN'),
        content: Text(
          'Enviar ${bytes.length} byte(s) para '
          '${CanFilterId(canId: canId, isExtended: _extended).label} '
          'como ${isFd ? 'CAN FD' : 'CAN clássico'}?\n\n'
          '${_payloadController.text.toUpperCase()}',
        ),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton.icon(
            key: const Key('confirm-send'),
            onPressed: () => Navigator.pop(context, true),
            icon: const Icon(Icons.send),
            label: const Text('Enviar uma vez'),
          ),
        ],
      ),
    );
    if (accepted != true || !mounted) return;
    try {
      await widget.controller.sendFrame(
        canId: canId,
        isExtended: _extended,
        isFd: isFd,
        dataHex: _payloadController.text,
        authorizationToken: _tokenController.text.trim().isEmpty
            ? null
            : _tokenController.text.trim(),
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Frame entregue ao backend para envio.'),
          ),
        );
      }
    } catch (_) {
      // O banner persistente do controller apresenta o detalhe seguro.
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Configuração do frame',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 18),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextFormField(
                      key: const Key('tx-id-input'),
                      controller: _idController,
                      decoration: const InputDecoration(
                        labelText: 'CAN ID (HEX)',
                        hintText: '123',
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
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 112,
                    child: DropdownButtonFormField<bool>(
                      key: const Key('tx-id-type-selector'),
                      initialValue: _extended,
                      decoration: const InputDecoration(labelText: 'Tipo'),
                      items: const [
                        DropdownMenuItem(value: false, child: Text('STD')),
                        DropdownMenuItem(value: true, child: Text('EXT')),
                      ],
                      onChanged: (value) =>
                          setState(() => _extended = value ?? false),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              TextFormField(
                key: const Key('tx-payload-input'),
                controller: _payloadController,
                decoration: const InputDecoration(
                  labelText: 'Payload hexadecimal',
                  hintText: '01 0A FF 20',
                  helperText: 'Separe cada byte com espaço.',
                ),
                minLines: 3,
                maxLines: 5,
                validator: (value) {
                  try {
                    final bytes = parseHexBytes(value ?? '');
                    final isFd = _fd && controller.activeSessionFd;
                    return validatePayloadLength(bytes.length, isFd: isFd);
                  } on FormatException catch (error) {
                    return error.message;
                  }
                },
              ),
              const SizedBox(height: 14),
              TextFormField(
                key: const Key('tx-token-input'),
                controller: _tokenController,
                obscureText: true,
                enableSuggestions: false,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'Token TX para interface física (opcional)',
                ),
              ),
              const SizedBox(height: 6),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('CAN FD'),
                subtitle: const Text(
                  'Até 64 bytes; depende da interface/sessão.',
                ),
                value: _fd && controller.activeSessionFd,
                onChanged: controller.activeSessionFd
                    ? (value) => setState(() => _fd = value)
                    : null,
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  key: const Key('send-button'),
                  onPressed: controller.isConnected && !controller.sending
                      ? _confirmAndSend
                      : null,
                  icon: controller.sending
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.send),
                  label: const Text('Revisar e enviar'),
                ),
              ),
              if (!controller.isConnected) ...[
                const SizedBox(height: 10),
                const Text(
                  'Conecte uma sessão no Monitor para habilitar o envio.',
                  textAlign: TextAlign.center,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _TransmissionSafetyCard extends StatelessWidget {
  const _TransmissionSafetyCard();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.warning_amber_rounded, color: colors.error),
                const SizedBox(width: 8),
                Text(
                  'Segurança',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
            const SizedBox(height: 12),
            const Text('A transmissão pode afetar equipamentos reais.'),
            const SizedBox(height: 10),
            const Text(
              'Confira o ID, o formato e o payload. O envio exige uma revisão '
              'e confirmação explícita antes de chegar ao backend.',
            ),
          ],
        ),
      ),
    );
  }
}
