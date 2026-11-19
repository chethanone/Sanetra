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
    this.isMigration = false,
  });

  final UpdateManifest manifest;
  final AppUpdateService updateService;
  final VoidCallback onLater;
  final bool isMigration;

  @override
  State<UpdatePromptDialog> createState() => _UpdatePromptDialogState();
}

class _UpdatePromptDialogState extends State<UpdatePromptDialog>
    with WidgetsBindingObserver {
  bool _isUpdating = false;
  double _progress = 0.0;
  String? _statusMessage;
  bool _needsInstallPermission = false;
  UpdateProgressStage? _currentStage;
  bool _isResuming = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkInitialPendingState();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _checkInitialPendingState() async {
    final pending = await widget.updateService.getPendingInstall();
    if (pending != null &&
        pending.versionCode == widget.manifest.versionCode &&
        pending.permissionRequired) {
      if (mounted) {
        setState(() {
          _needsInstallPermission = true;
          _currentStage = UpdateProgressStage.waitingForPermission;
          _statusMessage =
              'Please allow "Install unknown apps" for Sanetra in Settings, then return to resume installation.';
        });
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        _needsInstallPermission &&
        !_isUpdating &&
        !_isResuming) {
      _checkAndResumeIfPermissionGranted();
    }
  }

  Future<void> _checkAndResumeIfPermissionGranted({bool manual = false}) async {
    if (_isResuming || _isUpdating) return;
    _isResuming = true;
    try {
      final permitted = await widget.updateService.canRequestPackageInstalls();
      if (!mounted) return;
      if (permitted) {
        setState(() {
          _isUpdating = true;
          _needsInstallPermission = false;
          _currentStage = UpdateProgressStage.openingInstaller;
          _statusMessage = 'Permission granted — opening installer...';
        });

        final result = await widget.updateService.resumePendingInstallIfPermitted(
          onStageChanged: (stage) {
            if (mounted) setState(() => _currentStage = stage);
          },
        );

        if (!mounted) return;
        if (result.success) {
          setState(() {
            _isUpdating = false;
            _currentStage = UpdateProgressStage.installerOpened;
            _statusMessage = 'Android installer opened.';
          });
          if (Navigator.of(context).canPop()) {
            Navigator.of(context).pop();
          }
        } else {
          setState(() {
            _isUpdating = false;
            _needsInstallPermission = result.needsInstallPermission;
            _currentStage = result.needsInstallPermission
                ? UpdateProgressStage.waitingForPermission
                : UpdateProgressStage.failed;
            _statusMessage =
                result.error ?? 'Installation could not be started.';
          });
        }
      } else if (manual) {
        setState(() {
          _statusMessage =
              'Permission is still disabled in Settings. Please allow "Install unknown apps" to continue.';
        });
      }
    } finally {
      _isResuming = false;
    }
  }

  Future<void> _handleUpdateNow() async {
    setState(() {
      _isUpdating = true;
      _progress = 0.0;
      _currentStage = UpdateProgressStage.preparing;
      _statusMessage = 'Preparing download...';
      _needsInstallPermission = false;
    });

    final result = await widget.updateService.downloadAndInstall(
      widget.manifest,
      onProgress: (p) {
        if (mounted) {
          setState(() {
            _progress = p;
            _currentStage = UpdateProgressStage.downloading;
            _statusMessage = p >= 0
                ? 'Downloading ${(100 * p).toStringAsFixed(0)}%'
                : 'Downloading update...';
          });
        }
      },
      onStageChanged: (stage) {
        if (mounted) {
          setState(() {
            _currentStage = stage;
            switch (stage) {
              case UpdateProgressStage.preparing:
                _statusMessage = 'Preparing download...';
                break;
              case UpdateProgressStage.downloading:
                break;
              case UpdateProgressStage.verifying:
                _statusMessage = 'Verifying APK...';
                break;
              case UpdateProgressStage.downloadComplete:
                _statusMessage = 'Download complete.';
                break;
              case UpdateProgressStage.waitingForPermission:
                _statusMessage =
                    'Please allow "Install unknown apps" for Sanetra in Settings, then return to resume installation.';
                break;
              case UpdateProgressStage.openingInstaller:
                _statusMessage = 'Permission granted — opening installer...';
                break;
              case UpdateProgressStage.installerOpened:
                _statusMessage = 'Android installer opened.';
                break;
              case UpdateProgressStage.failed:
                break;
            }
          });
        }
      },
    );

    if (!mounted) return;
    if (result.success) {
      setState(() {
        _isUpdating = false;
        _currentStage = UpdateProgressStage.installerOpened;
        _statusMessage = 'Android installer opened.';
      });
      if (Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
      return;
    }

    setState(() {
      _isUpdating = false;
      _needsInstallPermission = result.needsInstallPermission;
      _currentStage = result.needsInstallPermission
          ? UpdateProgressStage.waitingForPermission
          : UpdateProgressStage.failed;
      _statusMessage = result.needsInstallPermission
          ? 'Please allow "Install unknown apps" for Sanetra in Settings, then return to resume installation.'
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
              if (widget.isMigration) ...[
                const SizedBox(height: 12),
                const Text(
                  "This version uses Sanetra's new application identity. It installs separately from v1.0.0. Your existing v1 installation and its local data remain untouched.",
                  style: TextStyle(
                    color: Color(0xFF90CAF9),
                    fontSize: 14,
                    height: 1.4,
                  ),
                ),
              ],
              if (_isUpdating) ...[
                const SizedBox(height: 16),
                LinearProgressIndicator(
                  value: (_currentStage == UpdateProgressStage.verifying ||
                          _currentStage == UpdateProgressStage.openingInstaller)
                      ? null
                      : (_progress >= 0 ? _progress : null),
                  color: const Color(0xFFF5F5F5),
                  backgroundColor: const Color(0xFF333333),
                ),
                const SizedBox(height: 8),
                Text(
                  _statusMessage ?? 'Processing update...',
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
                  style: TextStyle(
                    color: _needsInstallPermission
                        ? const Color(0xFF90CAF9)
                        : const Color(0xFFFFB74D),
                    fontSize: 14,
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          if (_needsInstallPermission) ...[
            TextButton(
              onPressed: () =>
                  widget.updateService.openUnknownSourcesSettings(),
              child: const Text(
                'Open Settings',
                style: TextStyle(color: Color(0xFFF5F5F5), fontSize: 15),
              ),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFF5F5F5),
                foregroundColor: const Color(0xFF0E0E0E),
                minimumSize: const Size(120, 48),
              ),
              onPressed: _isUpdating
                  ? null
                  : () => _checkAndResumeIfPermissionGranted(manual: true),
              child: const Text(
                'Continue installation',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
              ),
            ),
          ] else ...[
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFF5F5F5),
                foregroundColor: const Color(0xFF0E0E0E),
                minimumSize: const Size(120, 48),
              ),
              onPressed: _isUpdating ? null : _handleUpdateNow,
              child: Text(
                widget.isMigration ? 'Install separately' : 'Update now',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
            ),
          ],
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
        ],
      ),
    );
  }
}
