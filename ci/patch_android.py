"""Ajusta lo generado por `flutter create` (idempotente): permisos de internet y ubicación,
retorno de Google (deep link), reglas del lector de texto, nombre visible y título web."""
import pathlib
import re

manifest = pathlib.Path("android/app/src/main/AndroidManifest.xml")
text = manifest.read_text()

if "android.permission.INTERNET" not in text:
    text = text.replace(
        "<application",
        '<uses-permission android:name="android.permission.INTERNET"/>\n    <application',
        1,
    )

# Ubicación: el supervisor marca el sitio con "Usar mi ubicación" y el guarda inicia turno con GPS.
for perm in ("ACCESS_FINE_LOCATION", "ACCESS_COARSE_LOCATION"):
    if f"android.permission.{perm}" not in text:
        text = text.replace(
            "<application",
            f'<uses-permission android:name="android.permission.{perm}"/>\n    <application',
            1,
        )

# Llamar al supervisor con un toque (Android 11+ exige declarar la intención de marcar).
if "android.intent.action.DIAL" not in text:
    dial = (
        '        <intent>\n            <action android:name="android.intent.action.DIAL"/>\n'
        '            <data android:scheme="tel"/>\n        </intent>\n'
    )
    if "</queries>" in text:
        text = text.replace("</queries>", dial + "    </queries>", 1)
    else:
        text = text.replace("</manifest>", "    <queries>\n" + dial + "    </queries>\n</manifest>", 1)

if "login-callback" not in text:
    intent = (
        '<intent-filter>\n'
        '                <action android:name="android.intent.action.VIEW"/>\n'
        '                <category android:name="android.intent.category.DEFAULT"/>\n'
        '                <category android:name="android.intent.category.BROWSABLE"/>\n'
        '                <data android:scheme="com.saasdag.app" android:host="login-callback"/>\n'
        '            </intent-filter>\n'
        '        </activity>'
    )
    text = text.replace("</activity>", intent, 1)

text = re.sub(r'android:label="[^"]*"', 'android:label="SaaS-DAG"', text, count=1)
manifest.write_text(text)

# Lector de placas y DPI (ML Kit): solo se usa el alfabeto latino. R8 se queja de los otros
# alfabetos que el plugin menciona pero no trae; se le dice que no los busque.
rules = pathlib.Path("android/app/proguard-rules.pro")
needed = [
    "-dontwarn com.google.mlkit.vision.text.chinese.**",
    "-dontwarn com.google.mlkit.vision.text.devanagari.**",
    "-dontwarn com.google.mlkit.vision.text.japanese.**",
    "-dontwarn com.google.mlkit.vision.text.korean.**",
]
current = rules.read_text() if rules.exists() else ""
missing = [r for r in needed if r not in current]
if missing:
    rules.write_text(current + ("" if current.endswith("\n") or not current else "\n") + "\n".join(missing) + "\n")

index = pathlib.Path("web/index.html")
if index.exists():
    html = index.read_text()
    html = re.sub(r"<title>.*?</title>", "<title>SaaS-DAG</title>", html, count=1)
    index.write_text(html)

print("Android/web ajustados")
