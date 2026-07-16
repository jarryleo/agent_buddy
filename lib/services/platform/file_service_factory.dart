import 'dart:io' show Platform;

import 'file_service.dart';
import 'file_service_impl.dart';
import 'file_service_stub.dart';
import 'working_dir_backend.dart';

/// Production factory: returns a [FileServiceImpl] on Android / iOS
/// (talks to the native bridge for picker ops + working-dir ops)
/// and a [FileServiceStub] on desktop / web (where the bridge
/// isn't registered).
///
/// On Android the working-directory branch is routed through a
/// SAF-backed [WorkingDirBackend] so the model can write into
/// public volumes (e.g. `/storage/emulated/0/Download/...`)
/// without needing `MANAGE_EXTERNAL_STORAGE`. The native side
/// owns the tree URI + re-authorization flow. On iOS the
/// working directory lives inside the app sandbox, so `dart:io`
/// is enough.
///
/// [workingDirectoryLookup] is plumbed into [FileServiceImpl] so
/// the service can resolve `working://<rel>` and bare-relative
/// paths against the user-selected folder without a manual sync.
/// `ToolService` passes a closure that reads
/// `StorageService.modelWorkingDirectory` on every call.
///
/// Tests can pass their own builder to [ToolService] to inject an
/// in-memory fake; this factory is only consulted when no
/// override is supplied.
FileService createFileService({
  String? Function()? workingDirectoryLookup,
  WorkingDirBackend? workingDirBackend,
}) {
  if (Platform.isAndroid) {
    return FileServiceImpl(
      workingDirectoryLookup: workingDirectoryLookup,
      workingDirBackend: workingDirBackend ?? MethodChannelWorkingDirBackend(),
      isAndroid: true,
    );
  }
  if (Platform.isIOS) {
    return FileServiceImpl(workingDirectoryLookup: workingDirectoryLookup);
  }
  return const FileServiceStub();
}
