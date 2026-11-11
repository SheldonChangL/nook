import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// 同一個使用者同時只能有一個 Nook 在動保險庫。
///
/// 為什麼需要：`vault.json` 的寫入是「讀出 → 改 → 整份寫回」。兩個程序真的重疊時，
/// 一邊換主密碼（新 salt＋新 wrappedDek）、另一邊存設定，後寫的那份可能拿舊的
/// KDF／wrappedDek 蓋掉新的，保險庫就用哪個密碼都打不開。Windows／Linux 沒有
/// 系統層的單一執行個體保護，所以在應用層自己擋（macOS 也一併套用）。
///
/// 怎麼擋：在「應用程式支援目錄」（不是安裝目錄）放一個 `nook.lock`，開啟時向
/// 作業系統獨占它，整個程序存活期間都不放。
/// - 鎖檔的位置跟保險庫一樣由應用程式 ID 決定（Windows 看 exe 版本資訊、Linux 看
///   APPLICATION_ID），所以從不同安裝位置啟動同一個 App，搶的是同一把鎖。
/// - 程序結束或被強制終止時，核心會自動釋放，不會留下要人工刪除的殘鎖。
///   檔案本身留著沒關係，有沒有被鎖才算數。
/// - 鎖檔放在 `vault/` 外面：Windows 上被獨占的檔案別人開不了，放在裡面會讓
///   「整個 vault/ 複製走」的備份在 app 開著時失敗。
///
/// 為什麼不用 dart:io 的 `RandomAccessFile.lockSync`：Linux release 版實測，
/// 即使 Dart 端一直握著參照，GC 的 finalizer 仍在一次 scavenge 裡把那個 fd 關掉
/// （gdb 堆疊：dart::bin::File::~File ← FinalizablePersistentHandle::Finalize ←
/// Scavenger::MournWeakHandles），fcntl 鎖跟著消失，第二個執行個體照樣開得起來。
/// 所以這裡直接用 dart:ffi 呼叫系統 API，拿到的是 GC 管不到的原始 fd／HANDLE：
/// - POSIX（Linux、macOS）：`open` ＋ `flock(LOCK_EX | LOCK_NB)`。flock 綁在開啟的
///   檔案描述上，同一個程序開兩次也會互斥，測試在同程序內就驗得到。
/// - Windows：`CreateFileW` 開檔＋`LockFileEx(EXCLUSIVE | FAIL_IMMEDIATELY)`。
///   成敗看 LockFileEx 的回傳值，不靠 GetLastError（理由見 [_Win32]）。
///
/// 限制：網路磁碟上的家目錄是否尊重檔案鎖，依檔案系統而定，未驗證。
/// Windows 這一支尚未在 Windows 上建置或執行過。
class InstanceLock {
  InstanceLock._(this.file, this._handle);

  final File file;

  /// POSIX 是 fd，Windows 是 HANDLE 的數值；-1 代表已釋放。
  int _handle;

  bool get isHeld => _handle != -1;

  /// 嘗試取得鎖。別的程序（或同一程序另一次取得）已經握著時回 null；鎖檔本身
  /// 開不了（權限、磁碟、路徑不存在）時丟出 [FileSystemException] —— 呼叫端要
  /// 當成「不能安全開啟」，不能假裝沒事。
  static InstanceLock? tryAcquire(File file) {
    try {
      file.parent.createSync(recursive: true);
    } on FileSystemException catch (e) {
      throw FileSystemException('無法建立鎖檔所在的資料夾', file.path, e.osError);
    }
    final handle = Platform.isWindows
        ? _Win32.tryAcquire(file.path)
        : _Posix.tryAcquire(file.path);
    return handle == null ? null : InstanceLock._(file, handle);
  }

  /// 正式程式不需要呼叫（程序結束就會釋放），給測試與工具用。
  void release() {
    final handle = _handle;
    if (handle == -1) return;
    _handle = -1;
    if (Platform.isWindows) {
      _Win32.release(handle);
    } else {
      _Posix.release(handle);
    }
  }
}

/// open／flock／close。常數取自各平台的 `fcntl.h`、`sys/file.h`。
class _Posix {
  static final _libc = DynamicLibrary.process();

  static final _open = _libc
      .lookupFunction<
        // open 是可變參數函式（mode 是 ...）；Apple arm64 的 ABI 把可變參數放在堆疊上，
        // 宣告成一般參數的話 macOS 上會開檔失敗（實測）。
        Int32 Function(Pointer<Utf8>, Int32, VarArgs<(Uint32,)>),
        int Function(Pointer<Utf8>, int, int)
      >('open');
  static final _flock = _libc
      .lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>(
        'flock',
      );
  static final _close = _libc
      .lookupFunction<Int32 Function(Int32), int Function(int)>('close');

  static const _oRdwr = 0x2;
  // Linux（x64／arm64 相同）與 macOS 的值不一樣。
  static final _oCreat = Platform.isMacOS ? 0x200 : 0x40;
  static final _oCloexec = Platform.isMacOS ? 0x1000000 : 0x80000;
  static const _lockEx = 2;
  static const _lockNb = 4;
  static const _mode0600 = 0x180;

  static int? tryAcquire(String path) {
    final cPath = path.toNativeUtf8();
    final int fd;
    try {
      fd = _open(cPath, _oRdwr | _oCreat | _oCloexec, _mode0600);
    } finally {
      malloc.free(cPath);
    }
    if (fd < 0) {
      throw FileSystemException('無法開啟鎖檔', path);
    }
    // LOCK_NB：拿不到就立刻回 -1，不等。flock 幾乎只有「別人握著」會失敗。
    if (_flock(fd, _lockEx | _lockNb) != 0) {
      _close(fd);
      return null;
    }
    return fd;
  }

  static void release(int fd) => _close(fd);
}

/// CreateFileW／LockFileEx／CloseHandle（kernel32）。
///
/// 為什麼不靠 CreateFileW 的共用違規判斷「別人握著」：要區分「被占用」跟「真的
/// 開不了」得看 GetLastError，但 Dart VM 在兩次 FFI 呼叫之間會跑自己的 Win32
/// 呼叫（例如 TlsGetValue 成功時會把 last error 設回 0），事後再用 FFI 取
/// GetLastError 讀到的常常是 0。Windows CI 實測就是這樣：別的程序握著鎖時，
/// 拿到的是「Win32 錯誤碼 0」的例外，而不是 null。
///
/// 所以改成跟 POSIX 一樣的兩段式：
/// 1. CreateFileW 允許讀寫共用（不允許刪除共用，免得鎖檔被刪掉重建後兩邊各鎖
///    一份）。這一步不會因為別人握著而失敗，失敗就是真的開不了 → 丟例外。
/// 2. LockFileEx（獨占、FAIL_IMMEDIATELY）鎖整個範圍。成敗只看回傳值，不用
///    GetLastError；失敗就是有別的 handle 握著 → 回 null。
/// 鎖綁在 handle 上：同一程序開第二個 handle 也鎖不到；handle 關閉或程序結束時
/// 由系統釋放。
class _Win32 {
  static final _kernel32 = DynamicLibrary.open('kernel32.dll');

  static final _createFile = _kernel32
      .lookupFunction<
        IntPtr Function(
          Pointer<Utf16>,
          Uint32,
          Uint32,
          Pointer<Void>,
          Uint32,
          Uint32,
          IntPtr,
        ),
        int Function(Pointer<Utf16>, int, int, Pointer<Void>, int, int, int)
      >('CreateFileW');
  static final _lockFileEx = _kernel32
      .lookupFunction<
        Int32 Function(IntPtr, Uint32, Uint32, Uint32, Uint32, Pointer<Void>),
        int Function(int, int, int, int, int, Pointer<Void>)
      >('LockFileEx');
  static final _closeHandle = _kernel32
      .lookupFunction<Int32 Function(IntPtr), int Function(int)>('CloseHandle');
  static final _getLastError = _kernel32
      .lookupFunction<Uint32 Function(), int Function()>('GetLastError');

  static const _genericRead = 0x80000000;
  static const _genericWrite = 0x40000000;
  static const _fileShareRead = 0x1;
  static const _fileShareWrite = 0x2;
  static const _openAlways = 4;
  static const _fileAttributeNormal = 0x80;
  static const _invalidHandle = -1;
  static const _errorSharingViolation = 32;
  static const _lockfileFailImmediately = 0x1;
  static const _lockfileExclusiveLock = 0x2;

  /// OVERLAPPED 在 32／64 位元下是 20／32 bytes；配 32 bytes 全零 = 從位移 0 鎖起。
  static const _overlappedSize = 32;

  static int? tryAcquire(String path) {
    final wPath = path.toNativeUtf16();
    final int handle;
    final int error;
    try {
      handle = _createFile(
        wPath,
        _genericRead | _genericWrite,
        _fileShareRead | _fileShareWrite,
        nullptr,
        _openAlways,
        _fileAttributeNormal,
        0,
      );
      // 只拿來寫進錯誤訊息（理由見類別說明，這個值不可靠）。
      error = handle == _invalidHandle ? _getLastError() : 0;
    } finally {
      malloc.free(wPath);
    }
    if (handle == _invalidHandle) {
      // 舊版（dwShareMode = 0）的 Nook 還開著時會撞到共用違規；剛好讀得到就照實
      // 回報「被占用」，其餘一律當成開不了，不能當成拿到鎖。
      if (error == _errorSharingViolation) return null;
      throw FileSystemException(
        '無法開啟鎖檔',
        path,
        OSError('Win32 錯誤碼 $error（可能不準確）', error),
      );
    }

    final overlapped = calloc<Uint8>(_overlappedSize);
    final int locked;
    try {
      locked = _lockFileEx(
        handle,
        _lockfileExclusiveLock | _lockfileFailImmediately,
        0,
        0xFFFFFFFF,
        0xFFFFFFFF,
        overlapped.cast(),
      );
    } finally {
      calloc.free(overlapped);
    }
    if (locked == 0) {
      _closeHandle(handle);
      return null;
    }
    return handle;
  }

  /// 關掉 handle 時，系統會一併解除這個 handle 上的鎖。
  static void release(int handle) => _closeHandle(handle);
}
