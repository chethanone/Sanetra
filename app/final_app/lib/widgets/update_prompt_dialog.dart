import 'package:flutter/material.dart';
import 'package:vision_assistant/services/app_update_service.dart';

/// Accessible, high-contrast minimalist black/off-white update dialog
/// matching Sanetra's branding.
class UpdatePromptDialog extends StatefulWidget {
  const UpdatePromptDialog({
    super.key,
    required this.manifest,
    required this.updateService,
    required this.onLater,
  });

  final UpdateManifest manifest;
  final AppUpdateService updateService;
  final VoidCallback onLater;

  @override
  State<UpdatePromptDialog> createState() => _UpdatePromptDialogState();
}

class _UpdatePromptDialogState extends State<UpdatePromptDialog> {
  bool _isUpdating = false;
  double _progress = 0.0;
  String? _statusMessage;
  bool _needsInstallPermission = false;

  Future<void> _handleUpdateNow() async {
    setState(() {
      _isUpdating = true;
      _progress = 0.0;
      _statusMessage = 'Downloading update...';
      _needsInstallPermission = false;
    });

    final result = await widget.updateService.downloadAndInstall(
      widget.manifest,
      onProgress: (p) {
        if (mounted) {
          setState(() => _progress = p);
        }
      },
    );

    if (!mounted) return;
    if (result.success) {
      Navigator.of(context).pop();
      return;
    }

    setState(() {
      _isUpdating = false;
      _needsInstallPermission = result.needsInstallPermission;
      _statusMessage = result.needsInstallPermission
          ? 'Please allow "Install unknown apps" for Sanetra in Settings, then tap Update now again.'
          : (result.error ?? 'Update could not be completed.');
    });
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      namesRoute: true,
      label: 'A new Sanetra update is available',
      child: AlertDialog(
        backgroundColor: const Color(0xFF0E0E0E),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: const BorderSide(color: Color(0xFFF5F5F5), width: 1.5),
        ),
        title: const Text(
          'A new Sanetra update is available',
          style: TextStyle(
            color: Color(0xFFF5F5F5),
            fontSize: 20,
            fontWeight: FontWeight.w700,
          ),
        ),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Version: ${widget.manifest.version}',
                style: const TextStyle(
                  color: Color(0xFFF5F5F5),
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                "What's new:",
                style: TextStyle(
                  color: Color(0xFFBDBDBD),
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                widget.manifest.releaseNotes.isEmpty
                    ? 'Bug fixes and improvements.'
                    : widget.manifest.releaseNotes,
                style: const TextStyle(
                  color: Color(0xFFE0E0E0),
                  fontSize: 15,
                  height: 1.4,
                ),
              ),
              if (_isUpdating) ...[
                const SizedBox(height: 16),
                LinearProgressIndicator(
                  value: _progress > 0 ? _progress : null,
                  color: const Color(0xFFF5F5F5),
                  backgroundColor: const Color(0xFF333333),
                ),
                const SizedBox(height: 8),
                Text(
                  _progress > 0
                      ? 'Downloading ${(100 * _progress).toStringAsFixed(0)}%'
                      : 'Preparing download...',
                  style: const TextStyle(
                    color: Color(0xFFBDBDBD),
                    fontSize: 13,
                  ),
                ),
              ],
              if (_statusMessage != null && !_isUpdating) ...[
                const SizedBox(height: 12),
                Text(
                  _statusMessage!,
                  style: const TextStyle(
                    color: Color(0xFFFFB74D),
                    fontSize: 14,
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          if (_needsInstallPermission)
            TextButton(
              onPressed: () =>
                  widget.updateService.openUnknownSourcesSettings(),
              child: const Text(
                'Open Settings',
                style: TextStyle(color: Color(0xFFF5F5F5), fontSize: 15),
              ),
            ),
          TextButton(
            onPressed: _isUpdating
                ? null
                : () {
                    widget.onLater();
                    Navigator.of(context).pop();
                  },
            child: const Text(
              'Later',
              style: TextStyle(color: Color(0xFFBDBDBD), fontSize: 16),
            ),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFF5F5F5),
              foregroundColor: const Color(0xFF0E0E0E),
              minimumSize: const Size(120, 48),
            ),
            onPressed: _isUpdating ? null : _handleUpdateNow,
            child: const Text(
              'Update now',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}
