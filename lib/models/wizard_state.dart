import 'package:flutter/foundation.dart';

import '../core/pairing.dart';
import '../core/scanner.dart';
import '../core/transfer.dart';
import 'selection.dart';

enum DeviceRole { oldDevice, newDevice }

enum Transport { network, cable, usbDrive }

enum TransferMode { safe, recommended, wholeDisk, custom }

extension TransferModeInfo on TransferMode {
  String get title => switch (this) {
        TransferMode.safe => 'Safe Transfer',
        TransferMode.recommended => 'Recommended',
        TransferMode.wholeDisk => 'Whole Disk Clone',
        TransferMode.custom => 'Custom',
      };

  String get blurb => switch (this) {
        TransferMode.safe =>
          'Apps and your personal files. Nothing else. Safest choice.',
        TransferMode.recommended =>
          'Apps, files and your settings — accounts stay signed in, Wi-Fi just works.',
        TransferMode.wholeDisk =>
          'Everything, including the operating system. The new machine becomes this machine.',
        TransferMode.custom =>
          'Hand-pick exactly what moves over, file by file.',
      };
}

/// Everything the wizard collects along the way, plus the live engine
/// controllers once a flow is underway.
class WizardState extends ChangeNotifier {
  DeviceRole? role;
  Transport? transport;
  TransferMode? mode;

  Session? session;
  SenderController? sender; // old computer, network
  ReceiverController? receiver; // new computer, network or bundle
  SenderController? exporter; // old computer, USB drive

  ScanResult? scan; // OLD device: the local scan
  SelectionModel? selection; // the active selection tree (source or review)
  String? drivePath;

  void setRole(DeviceRole r) {
    role = r;
    notifyListeners();
  }

  void setTransport(Transport t) {
    transport = t;
    notifyListeners();
  }

  /// OLD device: build the browsable selection tree from the local scan.
  void buildSelectionFromScan(ScanResult s) {
    scan = s;
    selection = SelectionModel(
      s.categories,
      [
        for (final e in s.leaves)
          Leaf(e.relative, e.size, e.kind, e.categoryId),
      ],
    );
    notifyListeners();
  }

  /// NEW device: build the review tree from what the source offered.
  void buildSelectionFromOffer(List<ScanCategory> cats, List<Leaf> leaves) {
    selection = SelectionModel(cats, leaves)..selectAll(true);
    notifyListeners();
  }

  void applyMode(TransferMode m) {
    mode = m;
    selection?.applyMode((cat) => switch (m) {
          TransferMode.safe => !cat.settings,
          _ => true,
        });
    notifyListeners();
  }

  int get selectedBytes => selection?.selectedBytes ?? 0;
  int get selectedFiles => selection?.selectedFiles ?? 0;
  Set<String> includedRels() => selection?.includedRels() ?? {};

  /// Estimated size of a preset, straight from the category totals — used on
  /// the mode cards before the tree is touched.
  int bytesForMode(TransferMode m) {
    final cats = scan?.categories ?? const <ScanCategory>[];
    return switch (m) {
      TransferMode.safe => cats
          .where((c) => c.available && !c.settings)
          .fold(0, (s, c) => s + c.sizeBytes),
      _ => cats.where((c) => c.available).fold(0, (s, c) => s + c.sizeBytes),
    };
  }

  /// Back to the first screen; closes any live connection.
  void reset() {
    session?.close();
    session = null;
    sender = null;
    receiver = null;
    exporter = null;
    scan = null;
    selection = null;
    drivePath = null;
    mode = null;
    transport = null;
    role = null;
    notifyListeners();
  }
}

String prettyBytes(int bytes) {
  const gb = 1024 * 1024 * 1024;
  const mb = 1024 * 1024;
  if (bytes >= gb) {
    return '${(bytes / gb).toStringAsFixed(bytes % gb == 0 ? 0 : 1)} GB';
  }
  if (bytes >= mb) return '${(bytes / mb).round()} MB';
  if (bytes >= 1024) return '${(bytes / 1024).round()} KB';
  return '$bytes B';
}
