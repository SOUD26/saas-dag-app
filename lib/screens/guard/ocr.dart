// Lector de texto de fotos. En el teléfono (Android) usa el lector de Google que trae el propio
// teléfono: funciona sin internet y el lector no envía la foto a ningún lado. En la web no hay lector:
// el guarda escribe los datos.
export 'ocr_stub.dart' if (dart.library.io) 'ocr_mlkit.dart';
