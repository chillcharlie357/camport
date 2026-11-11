import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_runtime.dart';
import '../../app/app_theme.dart';
import '../../domain/models/transfer_job.dart';

String _stateLabel(TransferState state) => switch (state) {
  TransferState.queued => '待导入',
  TransferState.connecting => '连接中',
  TransferState.copying => '传输中',
  TransferState.interrupted => '已暂停',
  TransferState.completed => '已完成',
  TransferState.cancelled => '已取消',
  TransferState.failed => '失败',
};

/// Durable import queue viewer. Continue/pause drive [AppRuntime.resumeTransfers]
/// and [AppRuntime.pauseTransfers]; retry and cancel mutate the durable queue
/// directly. Original bytes and completed files are never removed from here.
class ImportQueueScreen extends StatefulWidget {
  const ImportQueueScreen({required this.runtime, super.key});

  final AppRuntime runtime;

  @override
  State<ImportQueueScreen> createState() => _ImportQueueScreenState();
}

class _ImportQueueScreenState extends State<ImportQueueScreen> {
  AppRuntime get runtime => widget.runtime;

  bool get _hasEligible => runtime.queue.jobs.any(
    (job) =>
        job.state == TransferState.queued ||
        job.state == TransferState.interrupted,
  );

  Future<void> _resume() async {
    try {
      await runtime.resumeTransfers();
    } catch (_) {
      // The queue runner surfaces the error through runtime.error.
    }
  }

  Future<void> _pause() async {
    try {
      await runtime.pauseTransfers();
    } catch (_) {
      // Pausing is best-effort; partial files are retained for resume.
    }
  }

  Future<void> _retry(TransferJob job) async {
    await runtime.queue.retry(job.id);
    await _resume();
  }

  Future<void> _cancel(TransferJob job) async {
    await runtime.queue.cancel(job.id);
  }

  void _openDetail(TransferJob job) {
    unawaited(
      Navigator.of(context).push<void>(
        MaterialPageRoute<void>(builder: (_) => _JobDetailScreen(job: job)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([runtime, runtime.queue]),
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: const Text('导入队列')),
        body: SafeArea(
          child: runtime.queue.jobs.isEmpty
              ? const _EmptyState()
              : Column(
                  children: [
                    _ControlBar(
                      running: runtime.queue.isRunning,
                      hasEligible: _hasEligible,
                      onResume: _resume,
                      onPause: _pause,
                    ),
                    if (runtime.queue.recoveryWarning != null)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                        child: Text(
                          runtime.queue.recoveryWarning!,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    Expanded(
                      child: ListView.builder(
                        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                        itemCount: runtime.queue.jobs.length,
                        itemBuilder: (context, index) {
                          final job = runtime.queue.jobs[index];
                          return _JobCard(
                            job: job,
                            onRetry: _retry,
                            onCancel: _cancel,
                            onOpen: _openDetail,
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

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.download_done_outlined,
              size: 40,
              color: AppTheme.mutedText,
            ),
            const SizedBox(height: 14),
            Text('暂无导入任务', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            Text('在图库选择文件后，导入任务会出现在这里。', textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

class _ControlBar extends StatelessWidget {
  const _ControlBar({
    required this.running,
    required this.hasEligible,
    required this.onResume,
    required this.onPause,
  });

  final bool running;
  final bool hasEligible;
  final VoidCallback onResume;
  final VoidCallback onPause;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
      decoration: const BoxDecoration(
        color: AppTheme.surface,
        border: Border(bottom: BorderSide(color: AppTheme.line)),
      ),
      child: Row(
        children: [
          Text('导入任务', style: Theme.of(context).textTheme.titleMedium),
          const Spacer(),
          if (running)
            FilledButton(onPressed: onPause, child: const Text('暂停'))
          else if (hasEligible)
            FilledButton(onPressed: onResume, child: const Text('继续')),
        ],
      ),
    );
  }
}

class _JobCard extends StatelessWidget {
  const _JobCard({
    required this.job,
    required this.onRetry,
    required this.onCancel,
    required this.onOpen,
  });

  final TransferJob job;
  final ValueChanged<TransferJob> onRetry;
  final ValueChanged<TransferJob> onCancel;
  final ValueChanged<TransferJob> onOpen;

  bool get _retryable =>
      job.state == TransferState.failed ||
      job.state == TransferState.cancelled ||
      job.state == TransferState.interrupted;

  bool get _cancellable =>
      job.state == TransferState.queued ||
      job.state == TransferState.connecting ||
      job.state == TransferState.copying ||
      job.state == TransferState.interrupted;

  @override
  Widget build(BuildContext context) {
    final progress = job.totalBytes > 0
        ? job.bytesTransferred / job.totalBytes
        : 0.0;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InkWell(
              onTap: () => onOpen(job),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      job.fileName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _stateLabel(job.state),
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: _stateColor(job.state),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            if (job.totalBytes > 0) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: progress.clamp(0.0, 1.0),
                  minHeight: 6,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '${_formatBytes(job.bytesTransferred)} / ${_formatBytes(job.totalBytes)}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            if (job.lastError != null && job.lastError!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                job.lastError!,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: Theme.of(context).colorScheme.error),
              ),
            ],
            if (_retryable || _cancellable) ...[
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (_retryable)
                    TextButton(
                      key: Key('retry-${job.id}'),
                      onPressed: () => onRetry(job),
                      child: const Text('重试'),
                    ),
                  if (_cancellable) ...[
                    if (_retryable) const SizedBox(width: 4),
                    TextButton(
                      key: Key('cancel-${job.id}'),
                      onPressed: () => onCancel(job),
                      child: const Text('取消'),
                    ),
                  ],
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _JobDetailScreen extends StatelessWidget {
  const _JobDetailScreen({required this.job});

  final TransferJob job;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('导入详情')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    job.fileName,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${_stateLabel(job.state)} · ${_formatBytes(job.totalBytes)}',
                  ),
                  const SizedBox(height: 20),
                  const Divider(height: 1),
                  const SizedBox(height: 16),
                  _DetailRow(
                    label: '本机 SHA-256',
                    value: job.checksum ?? '尚未计算',
                  ),
                  const SizedBox(height: 12),
                  _DetailRow(label: '保存位置', value: job.destinationPath),
                  const SizedBox(height: 12),
                  _DetailRow(label: '重试次数', value: '${job.attemptCount}'),
                  if (job.lastError != null && job.lastError!.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    _DetailRow(label: '最近错误', value: job.lastError!),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 2),
        Text(
          value,
          style: Theme.of(context).textTheme.bodyMedium
              ?.copyWith(color: AppTheme.text),
        ),
      ],
    );
  }
}

Color _stateColor(TransferState state) => switch (state) {
  TransferState.completed => const Color(0xFF2E7D32),
  TransferState.failed => const Color(0xFFB3261E),
  TransferState.cancelled => AppTheme.mutedText,
  TransferState.copying => AppTheme.accent,
  _ => AppTheme.text,
};

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}
