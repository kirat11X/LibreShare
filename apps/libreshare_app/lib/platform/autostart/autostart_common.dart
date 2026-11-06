/// Pieces shared by the per-OS [AutostartService] implementations.
library;

/// Command-line flag the autostart entry passes: start without showing the
/// window (design 01 sections 2 and 3).
const String kHiddenFlag = '--hidden';

/// Command-line flag the Windows uninstaller runs (`[UninstallRun]`, design
/// 01 section 3): remove the autostart entry and exit.
const String kRemoveAutostartFlag = '--remove-autostart';

/// Writing or removing the OS autostart entry failed.
///
/// [AutostartService.setEnabled] throws this so that a Settings toggle can
/// show the real outcome instead of pretending. Reading ([AutostartService
/// .isEnabled]) never throws; it reports `false` and logs.
class AutostartException implements Exception {
  const AutostartException(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() => cause == null
      ? 'AutostartException: $message'
      : 'AutostartException: $message ($cause)';
}

/// An autostart entry that repairs itself when the executable moved (AppImage
/// moved by the user, portable Windows zip relocated). Call [selfHeal] once at
/// start-up; it only touches an entry that already exists and that the user
/// has not disabled.
abstract interface class SelfHealingAutostart {
  /// Returns `true` if the entry was rewritten.
  Future<bool> selfHeal();
}
