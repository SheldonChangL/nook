import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';

/// 這台機器的同步設定：同步資料夾在哪。不是機密，存成明文；放在保險庫資料夾外面，
/// 因為它屬於「這台」—— 把 vault/ 複製到別台當備份時不該跟著過去。
class SyncConfig {
  const SyncConfig({required this.folder, this.bookmark});

  /// 使用者選的資料夾（同步區本身，或放同步區的上一層）。
  final String folder;

  /// macOS 沙盒的 security-scoped bookmark（base64）。沙盒裡的 app 只能碰使用者
  /// 親手選過的資料夾，重開之後要靠它重新取得存取權。其他平台沒有。
  final String? bookmark;

  static File fileIn(Directory supportDir) =>
      File('${supportDir.path}${Platform.pathSeparator}sync.json');

  static SyncConfig? load(Directory supportDir) {
    final file = fileIn(supportDir);
    if (!file.existsSync()) return null;
    try {
      final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      return SyncConfig(
        folder: json['folder'] as String,
        bookmark: json['bookmark'] as String?,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> save(Directory supportDir) async {
    final file = fileIn(supportDir);
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode({
      'folder': folder,
      if (bookmark != null) 'bookmark': bookmark,
    }));
  }

  static Future<void> clear(Directory supportDir) async {
    final file = fileIn(supportDir);
    if (file.existsSync()) await file.delete();
  }
}

/// 使用者選好的資料夾。
class PickedFolder {
  const PickedFolder(this.path, {this.bookmark});
  final String path;
  final String? bookmark;
}

/// 選資料夾、以及重開之後重新取得存取權。macOS 走原生的 NSOpenPanel 與
/// security-scoped bookmark（見 MainFlutterWindow.swift）；其他平台用 file_selector，
/// 沒有沙盒，記住路徑就夠了。測試可以換掉整個實作。
abstract class FolderAccess {
  Future<PickedFolder?> pick({required String prompt});

  /// 重開後恢復存取。回傳實際路徑（資料夾被搬走時 bookmark 會跟著找到新位置），
  /// 以及需要更新時的新 bookmark。拿不到存取權就丟 [FolderAccessException]。
  Future<PickedFolder> restore(SyncConfig config);
}

class FolderAccessException implements Exception {
  const FolderAccessException(this.message);
  final String message;
  @override
  String toString() => message;
}

class PlatformFolderAccess implements FolderAccess {
  static const _channel = MethodChannel('nook/folder');

  @override
  Future<PickedFolder?> pick({required String prompt}) async {
    if (Platform.isMacOS) {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'pick',
        prompt,
      );
      if (result == null) return null;
      return PickedFolder(
        result['path'] as String,
        bookmark: result['bookmark'] as String?,
      );
    }
    final path = await getDirectoryPath(confirmButtonText: '選擇');
    return path == null ? null : PickedFolder(path);
  }

  @override
  Future<PickedFolder> restore(SyncConfig config) async {
    if (!Platform.isMacOS) return PickedFolder(config.folder);
    final bookmark = config.bookmark;
    if (bookmark == null) {
      throw const FolderAccessException('沒有同步資料夾的存取權，請重新選一次。');
    }
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'restore',
        bookmark,
      );
      if (result == null) {
        throw const FolderAccessException('同步資料夾找不到了，請重新選一次。');
      }
      return PickedFolder(
        result['path'] as String,
        bookmark: result['bookmark'] as String? ?? bookmark,
      );
    } on PlatformException catch (e) {
      throw FolderAccessException('沒辦法重新取得同步資料夾的存取權（${e.message}），請重新選一次。');
    }
  }
}
