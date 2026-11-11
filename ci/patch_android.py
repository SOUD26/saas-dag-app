"""Ajusta lo generado por `flutter create` (idempotente): permiso de internet,
retorno de Google (deep link), nombre visible y título web."""
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

index = pathlib.Path("web/index.html")
if index.exists():
    html = index.read_text()
    html = re.sub(r"<title>.*?</title>", "<title>SaaS-DAG</title>", html, count=1)
    index.write_text(html)

print("Android/web ajustados")
