/// The files the user picked for the next send, and the one-call "send these
/// files to that device" used by the Home FAB and the device cards.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:libreshare_core/libreshare_core.dart';

import '../services/file_picker_service.dart';
import 'platform_providers.dart';
import 'transfers_provider.dart';

class PickedFilesNotifier extends Notifier<List<PickedFile>> {
  @override
  List<PickedFile> build() => const [];

  /// Adds [files], skipping paths already listed.
  void add(List<PickedFile> files) {
    final have = state.map((f) => f.path).toSet();
    state = [
      ...state,
      for (final f in files)
        if (have.add(f.path)) f,
    ];
  }

  void remove(PickedFile file) {
    state = [
      for (final f in state)
        if (f.path != file.path) f,
    ];
  }

  void clear() => state = const [];

  /// Opens the system picker and appends the result. True if anything was
  /// picked.
  Future<bool> pick() async {
    final picked = await ref.read(filePickerServiceProvider).pickFiles();
    if (picked.isEmpty) return false;
    add(picked);
    return true;
  }
}

final pickedFilesProvider =
    NotifierProvider<PickedFilesNotifier, List<PickedFile>>(
      PickedFilesNotifier.new,
    );

extension SendFlow on WidgetRef {
  /// Starts sending the picked files to [device]; returns the transfer key
  /// and clears the selection.
  String sendPickedFilesTo(DiscoveredDevice device) {
    final files = read(pickedFilesProvider);
    final key = read(transfersProvider.notifier).startSend(device, files);
    read(pickedFilesProvider.notifier).clear();
    return key;
  }
}
