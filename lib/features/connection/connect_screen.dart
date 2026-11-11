import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_runtime.dart';
import '../../app/app_theme.dart';
import '../../data/sony/sony_discovery.dart';
import '../gallery/gallery_screen.dart';
import '../import_queue/import_queue_screen.dart';

/// User-initiated camera discovery and manual LAN connection.
///
/// Connecting always goes through [AppRuntime.connectProfile], which performs
/// the platform Wi-Fi/network preparation and PTP/IP handshake. This widget only
/// validates the manual address and renders the session state; it never talks to
/// the camera or opens sockets itself.
class ConnectScreen extends StatefulWidget {
  const ConnectScreen({required this.runtime, super.key});

  final AppRuntime runtime;

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  final _hostController = TextEditingController();
  final _portController = TextEditingController(text: '15740');
  String? _hostError;
  String? _portError;
  String? _sessionError;
  bool _submitting = false;

  AppRuntime get runtime => widget.runtime;

  @override
  void dispose() {
    _hostController.dispose();
    _portController.dispose();
    super.dispose();
  }

  bool _validate() {
    final host = _hostController.text.trim();
    final port = int.tryParse(_portController.text.trim());
    final hostError = isCameraLanAddress(host) ? null : '请输入相机的局域网 IPv4 地址';
    final portError = port != null && port >= 1 && port <= 65535
        ? null
        : '端口需在 1–65535 之间';
    setState(() {
      _hostError = hostError;
      _portError = portError;
      _sessionError = null;
    });
    return hostError == null && portError == null;
  }

  Future<void> _submit() async {
    if (_submitting || runtime.connecting || !_validate()) return;
    final host = _hostController.text.trim();
    final port = int.parse(_portController.text.trim());
    setState(() {
      _submitting = true;
      _sessionError = null;
    });
    try {
      final endpoint = SonyCameraEndpoint.manual(host, port: port);
      await runtime.connectProfile(endpoint.toProfile());
      if (mounted) _openGallery();
    } catch (error) {
      if (mounted) setState(() => _sessionError = error.toString());
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _search() async {
    if (runtime.discovering || runtime.connecting) return;
    setState(() => _sessionError = null);
    try {
      await runtime.search();
      if (mounted && runtime.error != null) {
        setState(() => _sessionError = runtime.error.toString());
      }
    } catch (error) {
      if (mounted) setState(() => _sessionError = error.toString());
    }
  }

  Future<void> _connectEndpoint(SonyCameraEndpoint endpoint) async {
    if (_submitting || runtime.connecting) return;
    setState(() {
      _submitting = true;
      _sessionError = null;
    });
    try {
      await runtime.connectProfile(endpoint.toProfile());
      if (mounted) _openGallery();
    } catch (error) {
      if (mounted) setState(() => _sessionError = error.toString());
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _disconnect() async {
    try {
      await runtime.disconnect();
    } catch (error) {
      if (mounted) setState(() => _sessionError = error.toString());
    }
  }

  void _openQueue() {
    unawaited(
      Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => ImportQueueScreen(runtime: runtime),
        ),
      ),
    );
  }

  void _openGallery() {
    final profile = runtime.profile;
    if (profile == null) return;
    unawaited(
      Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => GalleryScreen(
            adapter: runtime.galleryAdapter(profile.id),
            cameraName: profile.displayName,
            diskCache: runtime.thumbnailNamespace == null
                ? null
                : runtime.cache,
            cacheNamespace: runtime.thumbnailNamespace,
            onImport: (files) => runtime.importFiles(profile.id, files),
            onOpenQueue: _openQueue,
            activity: runtime,
            isTransferring: () => runtime.queue.isRunning,
            isConnected: () =>
                runtime.connected && runtime.profile?.id == profile.id,
            connectionEpoch: () => runtime.connectionEpoch,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: runtime,
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: const Text('连接相机')),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _StatusCard(
                      runtime: runtime,
                      onDisconnect: _disconnect,
                      onOpenGallery: _openGallery,
                      onOpenQueue: _openQueue,
                    ),
                    const SizedBox(height: 20),
                    _DiscoverySection(
                      runtime: runtime,
                      onSearch: _search,
                      onConnect: _connectEndpoint,
                    ),
                    const SizedBox(height: 20),
                    _ManualSection(
                      hostController: _hostController,
                      portController: _portController,
                      hostError: _hostError,
                      portError: _portError,
                      submitting: _submitting || runtime.connecting,
                      onSubmit: _submit,
                      onOpenWifiSettings: runtime.background.openWifiSettings,
                    ),
                    if (_sessionError != null) ...[
                      const SizedBox(height: 16),
                      _ErrorBanner(message: _sessionError!),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.runtime,
    required this.onDisconnect,
    required this.onOpenGallery,
    required this.onOpenQueue,
  });

  final AppRuntime runtime;
  final VoidCallback onDisconnect;
  final VoidCallback onOpenGallery;
  final VoidCallback onOpenQueue;

  @override
  Widget build(BuildContext context) {
    final profile = runtime.profile;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.photo_camera_outlined, color: AppTheme.accent),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    profile == null ? '尚未连接' : profile.displayName,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                if (runtime.connected)
                  const _ConnectedBadge()
                else if (runtime.connecting)
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            if (profile != null) ...[
              const SizedBox(height: 8),
              Text(
                '${profile.model ?? 'Sony 相机'} · Wi-Fi 相机热点',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
            if (runtime.connected) ...[
              const SizedBox(height: 16),
              Row(
                children: [
                  FilledButton(
                    onPressed: onOpenGallery,
                    child: const Text('浏览图库'),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: onOpenQueue,
                    child: const Text('导入队列'),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: onDisconnect,
                    child: const Text('断开连接'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ConnectedBadge extends StatelessWidget {
  const _ConnectedBadge();

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '相机已连接',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: AppTheme.raisedSurface,
          borderRadius: BorderRadius.circular(100),
          border: Border.all(color: AppTheme.line),
        ),
        child: Text('已连接', style: Theme.of(context).textTheme.labelSmall),
      ),
    );
  }
}

class _DiscoverySection extends StatelessWidget {
  const _DiscoverySection({
    required this.runtime,
    required this.onSearch,
    required this.onConnect,
  });

  final AppRuntime runtime;
  final VoidCallback onSearch;
  final ValueChanged<SonyCameraEndpoint> onConnect;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('自动发现', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          height: 52,
          child: OutlinedButton.icon(
            onPressed: runtime.discovering || runtime.connecting
                ? null
                : onSearch,
            icon: const Icon(Icons.radar, size: 19),
            label: Text(runtime.discovering ? '正在搜索…' : '搜索相机'),
          ),
        ),
        if (runtime.endpoints.isNotEmpty) ...[
          const SizedBox(height: 8),
          for (final endpoint in runtime.endpoints)
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 8),
              leading: const Icon(Icons.wifi),
              title: Text(endpoint.name ?? endpoint.model ?? 'Sony 相机'),
              subtitle: Text('${endpoint.host}:${endpoint.ptpPort}'),
              trailing: const Icon(Icons.chevron_right),
              onTap: runtime.connecting ? null : () => onConnect(endpoint),
            ),
        ],
      ],
    );
  }
}

class _ManualSection extends StatelessWidget {
  const _ManualSection({
    required this.hostController,
    required this.portController,
    required this.hostError,
    required this.portError,
    required this.submitting,
    required this.onSubmit,
    required this.onOpenWifiSettings,
  });

  final TextEditingController hostController;
  final TextEditingController portController;
  final String? hostError;
  final String? portError;
  final bool submitting;
  final VoidCallback onSubmit;
  final VoidCallback onOpenWifiSettings;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('手动连接', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          '在相机菜单中选择「发送到智能手机」，加入相机 Wi-Fi 后输入地址。',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 12),
        TextField(
          key: const Key('camera-host'),
          controller: hostController,
          keyboardType: TextInputType.url,
          autocorrect: false,
          decoration: InputDecoration(
            labelText: '相机 IP 地址',
            hintText: '192.168.122.1',
            errorText: hostError,
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const Key('camera-port'),
          controller: portController,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(labelText: '端口', errorText: portError),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          height: 52,
          child: FilledButton(
            key: const Key('manual-connect'),
            onPressed: submitting ? null : onSubmit,
            child: Text(submitting ? '正在连接…' : '连接相机'),
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          height: 52,
          child: OutlinedButton.icon(
            onPressed: onOpenWifiSettings,
            icon: const Icon(Icons.settings, size: 19),
            label: const Text('打开 Wi-Fi 设置'),
          ),
        ),
      ],
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.raisedSurface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.line),
      ),
      child: Text(message, style: Theme.of(context).textTheme.bodyMedium),
    );
  }
}
