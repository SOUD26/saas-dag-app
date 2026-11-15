import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

/// Copia la foto a la carpeta privada de la app (la temporal la puede borrar el sistema).
Future<String?> keepPhoto(String tempPath, String id) async {
  try {
    final dir = Directory('${(await getApplicationDocumentsDirectory()).path}/fotos_pendientes');
    if (!await dir.exists()) await dir.create(recursive: true);
    final kept = await File(tempPath).copy('${dir.path}/$id.jpg');
    try {
      await File(tempPath).delete();
    } catch (_) {
      // La temporal la limpia el sistema.
    }
    return kept.path;
  } catch (_) {
    return null;
  }
}

Future<Uint8List?> readPhoto(String path) async {
  try {
    final f = File(path);
    if (!await f.exists()) return null;
    return await f.readAsBytes();
  } catch (_) {
    return null;
  }
}

Future<void> deletePhoto(String path) async {
  try {
    final f = File(path);
    if (await f.exists()) await f.delete();
  } catch (_) {
    // Nada más que hacer.
  }
}
