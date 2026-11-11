import 'package:flutter/material.dart';

import 'profile.dart';

/// Texto, icono y color de la pantalla de cada rol, y los módulos que vendrán.
class RoleInfo {
  const RoleInfo({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.color,
    required this.modules,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final Color color;
  final List<String> modules;
}

RoleInfo infoFor(AppRole role) {
  switch (role) {
    case AppRole.superAdmin:
      return const RoleInfo(
        title: 'Panel general',
        subtitle: 'Todas las empresas de seguridad',
        icon: Icons.admin_panel_settings_rounded,
        color: Color(0xFF0B2545),
        modules: ['Empresas', 'Módulos por empresa', 'Facturación', 'Bitácora global'],
      );
    case AppRole.companyAdmin:
      return const RoleInfo(
        title: 'Administración',
        subtitle: 'Tu empresa de seguridad',
        icon: Icons.business_rounded,
        color: Color(0xFF1B6CA8),
        modules: [
          'Clientes y sitios',
          'Guardas y supervisores',
          'Permisos y accesos',
          'Caras registradas',
          'Bitácora',
        ],
      );
    case AppRole.supervisor:
      return const RoleInfo(
        title: 'Supervisión y monitoreo',
        subtitle: 'Tus sitios y tus guardas',
        icon: Icons.monitor_heart_rounded,
        color: Color(0xFF2E7D6B),
        modules: [
          'Mapa de sitios',
          'Guardas en turno',
          'Banderas rojas',
          'Rondas',
          'Alertas',
        ],
      );
    case AppRole.guard:
      return const RoleInfo(
        title: 'Mi turno',
        subtitle: 'Guarda de seguridad',
        icon: Icons.local_police_rounded,
        color: Color(0xFFB26A00),
        modules: ['Iniciar turno', 'Rondas', 'Botón de pánico', 'Bitácora del turno'],
      );
    case AppRole.client:
      return const RoleInfo(
        title: 'Mi propiedad',
        subtitle: 'Condominio u oficina-bodega',
        icon: Icons.apartment_rounded,
        color: Color(0xFF6A4C93),
        modules: ['Ingresos y visitantes', 'Reportes', 'Usuarios de mi propiedad'],
      );
    case AppRole.resident:
      return const RoleInfo(
        title: 'Mi cuenta',
        subtitle: 'Residente, propietario o local',
        icon: Icons.home_rounded,
        color: Color(0xFFAD3F5C),
        modules: ['Mis visitas', 'Autorizar un ingreso', 'Avisos'],
      );
  }
}
