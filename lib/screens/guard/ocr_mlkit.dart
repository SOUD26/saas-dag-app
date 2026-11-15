import 'dart:io';

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

/// Lector de Google en el teléfono: sin internet y sin enviar la foto a ningún lado.
bool get ocrAvailable => Platform.isAndroid || Platform.isIOS;

Future<String?> readTextFromImage(String path) async {
  final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
  try {
    final result = await recognizer.processImage(InputImage.fromFilePath(path));
    return result.text;
  } catch (_) {
    return null;
  } finally {
    await recognizer.close();
  }
}

/// La foto de la placa no se guarda: se borra apenas se lee.
Future<void> discardImage(String path) async {
  try {
    final f = File(path);
    if (await f.exists()) await f.delete();
  } catch (_) {
    // Si no se puede borrar, queda en la carpeta temporal de la app, que el sistema limpia.
  }
}
