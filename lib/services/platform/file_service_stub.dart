import '../../models/picked_file.dart';
import 'file_service.dart';
import 'file_service_impl.dart';

/// Throws [FileServiceNotSupportedError] for every operation. Used
/// on platforms where the native bridge is not registered (web,
/// desktop unit tests that don't fake a backend). The file tool's
/// `isSupportedOnCurrentPlatform` already gates the schema, so
/// this stub is mostly a safety net.
class FileServiceStub implements FileService {
  const FileServiceStub();

  Never _unsupported() => throw const FileServiceNotSupportedError();

  @override
  Future<PickedFile?> pick({String? mimeType, bool readOnly = false}) =>
      _unsupported();

  @override
  Future<void> release(String id) => _unsupported();

  @override
  Future<List<int>> read(String path, {int maxBytes = 2 * 1024 * 1024}) =>
      _unsupported();

  @override
  Future<void> write(
    String path,
    List<int> bytes, {
    bool append = false,
  }) => _unsupported();

  @override
  Future<void> delete(String path, {bool recursive = false}) => _unsupported();

  @override
  Future<void> rename(String from, String to) => _unsupported();

  @override
  Future<List<FileEntry>> listDir(String path, {bool recursive = false}) =>
      _unsupported();

  @override
  Future<FileAttrs> readAttr(String path) => _unsupported();
}
