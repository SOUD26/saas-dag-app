import 'package:flutter/material.dart';

import '../theme.dart';

/// Marca provisional: escudo ámbar sobre fondo azul marino.
class LogoMark extends StatelessWidget {
  const LogoMark({super.key, this.size = 48});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: AppColors.amber,
        borderRadius: BorderRadius.circular(size * 0.28),
      ),
      child: Icon(Icons.shield_rounded, color: AppColors.navy, size: size * 0.62),
    );
  }
}
