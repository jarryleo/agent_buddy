import 'dart:io' show Platform;

import 'file_service.dart';
import 'file_service_impl.dart';
import 'file_service_stub.dart';

/// Production factory: returns a [FileServiceImpl] on Android / iOS
/// (talks to the native bridge for picker ops, uses `path_provider`
/// + `dart:io` for sandbox ops) and a [FileServiceStub] on
/// desktop / web (where the bridge isn't registered).
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
FileService createFileService({String? Function()? workingDirectoryLookup}) {
  if (Platform.isAndroid || Platform.isIOS) {
    return FileServiceImpl(workingDirectoryLookup: workingDirectoryLookup);
  }
  return const FileServiceStub();
}
