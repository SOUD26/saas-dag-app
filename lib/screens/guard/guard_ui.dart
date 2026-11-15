import 'dart:math' as math;

import 'package:flutter/material.dart';

// Pantallas del guarda: letra grande, botones enormes con ícono y palabra, mucho contraste y una
// sola cosa por pantalla. Pensado para guardas mayores o con poca vista.

const gNavy = Color(0xFF0B2545);
const gGreen = Color(0xFF1B7F3B);
const gRed = Color(0xFFB3261E);
const gOrange = Color(0xFFC25100);
const gBlue = Color(0xFF1555A8);
const gAmber = Color(0xFF8A5A00);
const gInk = Color(0xFF1A1A1A);
const gSoft = Color(0xFF444444); // gris oscuro: nunca gris claro para el texto
const gBg = Color(0xFFF3F5F8);

/// Envuelve cada pantalla del guarda: letra al menos 20 % más grande y tema de alto contraste.
Widget guardFrame(BuildContext context, Widget child) {
  final mq = MediaQuery.of(context);
  final base = Theme.of(context);
  final scale = math.max(mq.textScaler.scale(1), 1.2);
  return MediaQuery(
    data: mq.copyWith(textScaler: TextScaler.linear(scale)),
    child: Theme(
      data: base.copyWith(
        scaffoldBackgroundColor: gBg,
        colorScheme: base.colorScheme.copyWith(primary: gNavy),
        textTheme: base.textTheme.apply(bodyColor: gInk, displayColor: gInk),
        inputDecorationTheme: const InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(14))),
          contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 18),
        ),
      ),
      child: child,
    ),
  );
}

/// Estructura de cada pantalla del guarda.
class GuardPage extends StatelessWidget {
  const GuardPage({super.key, required this.title, required this.children, this.bottom, this.actions});
  final String title;
  final List<Widget> children;
  final Widget? bottom;
  final List<Widget>? actions;

  @override
  Widget build(BuildContext context) {
    return guardFrame(
      context,
      Scaffold(
        appBar: AppBar(
          backgroundColor: gNavy,
          foregroundColor: Colors.white,
          toolbarHeight: 68,
          titleTextStyle: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: Colors.white),
          title: Text(title),
          actions: actions,
        ),
        body: LayoutBuilder(
          builder: (context, c) {
            final side = ((c.maxWidth - 640) / 2).clamp(14.0, double.infinity);
            return ListView(
              padding: EdgeInsets.fromLTRB(side, 16, side, 28),
              children: children,
            );
          },
        ),
        bottomNavigationBar: bottom == null
            ? null
            : SafeArea(
                child: Padding(padding: const EdgeInsets.fromLTRB(14, 8, 14, 12), child: bottom),
              ),
      ),
    );
  }
}

/// Botón enorme con ícono, palabra y, opcional, una línea de ayuda.
class GuardButton extends StatelessWidget {
  const GuardButton({
    super.key,
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
    this.sub,
    this.height = 92,
  });

  final IconData icon;
  final String label;
  final String? sub;
  final Color color;
  final VoidCallback? onTap;
  final double height;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: enabled ? color : const Color(0xFF9E9E9E),
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: height),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
              child: Row(
                children: [
                  Icon(icon, size: 42, color: Colors.white),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(label,
                            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: Colors.white)),
                        if (sub != null)
                          Text(sub!, style: const TextStyle(fontSize: 15, color: Colors.white, height: 1.25)),
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right_rounded, size: 34, color: Colors.white),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Botón principal de abajo (Guardar, Siguiente…).
class GuardMainButton extends StatelessWidget {
  const GuardMainButton({super.key, required this.label, required this.onTap, this.color = gGreen, this.busy = false});
  final String label;
  final VoidCallback? onTap;
  final Color color;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return FilledButton(
      style: FilledButton.styleFrom(
        backgroundColor: color,
        minimumSize: const Size(double.infinity, 64),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        textStyle: const TextStyle(fontSize: 21, fontWeight: FontWeight.w900),
      ),
      onPressed: busy ? null : onTap,
      child: busy
          ? const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 3))
          : Text(label),
    );
  }
}

class GuardCard extends StatelessWidget {
  const GuardCard({super.key, required this.child, this.color = Colors.white, this.border});
  final Widget child;
  final Color color;
  final Color? border;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: border ?? const Color(0xFFD0D5DD), width: border == null ? 1 : 2),
      ),
      child: child,
    );
  }
}

/// Texto grande de título dentro de una pantalla.
class GuardTitle extends StatelessWidget {
  const GuardTitle(this.text, {super.key, this.sub});
  final String text;
  final String? sub;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(text, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w900, color: gInk)),
          if (sub != null) ...[
            const SizedBox(height: 4),
            Text(sub!, style: const TextStyle(fontSize: 17, color: gSoft, height: 1.3)),
          ],
        ],
      ),
    );
  }
}

/// Pantalla grande de confirmación (verde = listo; otro color = guardado con aviso).
Future<void> showDone(BuildContext context, {required String title, String? sub, Color color = gGreen, IconData icon = Icons.check_circle_rounded}) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => guardFrame(
      ctx,
      Dialog(
        insetPadding: const EdgeInsets.all(20),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 26, 22, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 84, color: color),
              const SizedBox(height: 10),
              Text(title,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900, color: color)),
              if (sub != null) ...[
                const SizedBox(height: 8),
                Text(sub, textAlign: TextAlign.center, style: const TextStyle(fontSize: 17, color: gInk, height: 1.3)),
              ],
              const SizedBox(height: 18),
              GuardMainButton(label: 'Aceptar', color: color, onTap: () => Navigator.of(ctx).pop()),
            ],
          ),
        ),
      ),
    ),
  );
}

/// Pregunta de sí o no con botones grandes.
Future<bool> askYesNo(BuildContext context, String title, {String? sub, String yes = 'Sí', String no = 'No', Color color = gGreen}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => guardFrame(
      ctx,
      Dialog(
        insetPadding: const EdgeInsets.all(20),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 24, 22, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(title, style: const TextStyle(fontSize: 23, fontWeight: FontWeight.w900, color: gInk)),
              if (sub != null) ...[
                const SizedBox(height: 8),
                Text(sub, style: const TextStyle(fontSize: 17, color: gSoft, height: 1.3)),
              ],
              const SizedBox(height: 18),
              GuardMainButton(label: yes, color: color, onTap: () => Navigator.of(ctx).pop(true)),
              const SizedBox(height: 10),
              OutlinedButton(
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(double.infinity, 58),
                  textStyle: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                ),
                onPressed: () => Navigator.of(ctx).pop(false),
                child: Text(no),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  return r ?? false;
}

String hhmm(DateTime d) {
  final l = d.toLocal();
  return '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
}

String dayHhmm(DateTime d) {
  final l = d.toLocal();
  final now = DateTime.now();
  final today = l.year == now.year && l.month == now.month && l.day == now.day;
  return today ? 'hoy ${hhmm(l)}' : '${l.day.toString().padLeft(2, '0')}/${l.month.toString().padLeft(2, '0')} ${hhmm(l)}';
}

String sinceText(DateTime d) {
  final m = DateTime.now().difference(d).inMinutes;
  if (m < 1) return 'recién';
  if (m < 60) return 'hace $m min';
  final h = m ~/ 60;
  return h == 1 ? 'hace 1 hora' : 'hace $h horas';
}
