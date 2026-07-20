import 'dart:convert';

import '../../models/edited_image.dart';
import '../../services/image_edit_service.dart';
import '../tool_service.dart';
import 'tool_base.dart';

/// Image-editing tool backed by `lib/services/image_edit_service.dart`.
///
/// Exposes four pixel-precise ops (compress / crop / resize /
/// rotate) and lets the model chain them by calling the tool
/// repeatedly with the same source path. Each call copies the
/// source into the temp directory, processes the copy, and
/// returns a JSON envelope describing the result. The chat
/// provider extracts the [EditedImage] from the envelope and
/// appends it to the in-place [ToolCall.editedImages] so the
/// bubble can render a preview with a Save affordance.
///
/// The source file is **never** modified — the tool only reads
/// from it and writes a new file under
/// `getTemporaryDirectory()/edit_image/`.
class EditImageTool extends ToolBase {
  EditImageTool({ImageEditService? imageEditService})
    : _service = imageEditService ?? ImageEditService();

  final ImageEditService _service;

  @override
  String get id => 'edit_image';

  @override
  String get name => '编辑图片';

  @override
  String get description =>
      '编辑用户上传的图片:压缩体积、裁剪区域、调整分辨率(可选保持宽高比)、旋转 90/180/270 度、转换图片格式。'
      '每次调用处理一次,在临时目录生成新文件,不会影响原图。处理结果会展示在气泡里供用户预览和保存。'
      '`image_path` 必须是当前对话中已上传的图片文件路径。';

  @override
  String get shortDescription => '编辑图片(压缩/裁剪/旋转/转格式)';
  @override
  bool get isSupportedOnCurrentPlatform => notWeb();

  @override
  Map<String, dynamic> buildSchema() {
    if (!isSupportedOnCurrentPlatform) return {};
    return {
      'type': 'function',
      'function': {
        'name': 'edit_image',
        'description': description,
        'parameters': {
          'type': 'object',
          'properties': {
            'action': {
              'type': 'string',
              'enum': ['compress', 'crop', 'resize', 'rotate', 'convert'],
              'description':
                  '要执行的操作。compress = 重编码到指定 quality 以压缩体积;'
                  'crop = 按 x/y/width/height 裁剪;'
                  'resize = 调整分辨率(keep_aspect_ratio 默认 true);'
                  'rotate = 顺时针旋转(degrees 必须是 90/180/270 的倍数);'
                  'convert = 转换图片格式(通过 target_format 指定目标格式)。',
            },
            'image_path': {
              'type': 'string',
              'description':
                  '要处理的图片文件绝对路径,必须是当前对话中已上传的图片路径,'
                  '不要传给临时文件路径。',
            },
            'quality': {
              'type': 'integer',
              'minimum': 1,
              'maximum': 100,
              'description':
                  'compress / convert 专用。JPEG 编码质量(1-100,默认 85)。'
                  '对 PNG/GIF/BMP/TIFF 等无损格式无效,WebP 走 lossless。',
            },
            'target_format': {
              'type': 'string',
              'enum': ['jpg', 'jpeg', 'png', 'webp', 'gif', 'bmp', 'tiff'],
              'description':
                  'convert 专用。目标图片格式,支持 jpg/png/webp/gif/bmp/tiff。'
                  '不传就保持原格式(等于一次无损 re-encode)。',
            },
            'x': {
              'type': 'integer',
              'minimum': 0,
              'description': 'crop 专用。裁剪起点 x 坐标(像素)。',
            },
            'y': {
              'type': 'integer',
              'minimum': 0,
              'description': 'crop 专用。裁剪起点 y 坐标(像素)。',
            },
            'width': {
              'type': 'integer',
              'minimum': 1,
              'description': 'crop 专用:裁剪宽度;resize 专用:目标宽度。',
            },
            'height': {
              'type': 'integer',
              'minimum': 1,
              'description': 'crop 专用:裁剪高度;resize 专用:目标高度。',
            },
            'keep_aspect_ratio': {
              'type': 'boolean',
              'description':
                  'resize 专用。true 时按宽高比缩放,只用一个维度也可以(另一个会按比例推导);'
                  'false 时强制使用给定的 width/height。默认 true。',
            },
            'degrees': {
              'type': 'integer',
              'enum': [90, 180, 270],
              'description': 'rotate 专用。顺时针旋转的度数,必须是 90/180/270 之一。',
            },
          },
          'required': ['action', 'image_path'],
        },
      },
    };
  }

  @override
  Future<String> execute(
    Map<String, dynamic> args,
    ToolService services,
  ) async {
    return wrapPlatformExceptions(() => _run(args), 'edit_image');
  }

  Future<String> _run(Map<String, dynamic> args) async {
    final actionStr = (args['action'] as String? ?? '').trim();
    final imagePath = (args['image_path'] as String? ?? '').trim();
    if (imagePath.isEmpty) {
      throw ToolException('image_path is required');
    }
    final action = _parseAction(actionStr);

    final result = await _service.edit(
      sourcePath: imagePath,
      action: action,
      params: args,
    );

    // Return a model-readable JSON envelope. We deliberately
    // surface the absolute temp path here so the model can
    // decide whether to chain further edits by referencing
    // `path` (it will round-trip back through
    // `ImageService.toBase64DataUrl` if it wants to re-attach
    // the image to a multimodal request) — but we ALSO mark
    // it as a `tool_internal_path` so a model that wants to be
    // strict about filesystem access can simply ignore it.
    final envelope = <String, dynamic>{
      'action': result.action,
      'ok': true,
      'path': result.path,
      'tool_internal_path': true,
      'filename': result.filename,
      'width': result.width,
      'height': result.height,
      'size': result.size,
      'format': result.format,
      'source_width': result.sourceWidth,
      'source_height': result.sourceHeight,
      'source_size': result.sourceSize,
      'hint':
          'Processing succeeded. The processed image is shown in the chat bubble above. '
          'The user can tap the Save button under the image to save it to a folder of their choice.',
    };
    // Sanity-check the result envelope is something the JSON
    // parser can swallow. Defensive against accidentally adding
    // a non-encodable value above (e.g. a Dart `Object` that
    // slipped past the type system).
    try {
      return jsonEncode(envelope);
    } catch (e) {
      throw ToolException('failed to encode edit_image result: $e');
    }
  }

  EditImageAction _parseAction(String raw) {
    switch (raw) {
      case 'compress':
        return EditImageAction.compress;
      case 'crop':
        return EditImageAction.crop;
      case 'resize':
        return EditImageAction.resize;
      case 'rotate':
        return EditImageAction.rotate;
      case 'convert':
        return EditImageAction.convert;
      default:
        throw ToolException(
          'unknown edit_image action: "$raw" '
          '(expected: compress | crop | resize | rotate | convert)',
        );
    }
  }
}
