import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../models/profile.dart';
import '../../supabase.dart';
import '../../theme.dart';
import 'admin_data.dart';
import 'admin_sheets.dart';
import 'admin_ui.dart';
import 'admin_views.dart';

/// Pantalla del administrador de empresa: centro de mando + secciones.
class AdminHome extends StatefulWidget {
  const AdminHome({super.key, required this.profile, this.preview = false});

  final Profile profile;
  final bool preview;

  @override
  State<AdminHome> createState() => _AdminHomeState();
}

class _AdminHomeState extends State<AdminHome> {
  int _tab = 0;
  String _flagFilter = 'pending';
  AdminData? _data;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await loadAdminData();
      if (!mounted) return;
      setState(() {
        _data = d;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
    }
  }

  void _go(int tab, {String? filter}) => setState(() {
        _tab = tab;
        if (filter != null) _flagFilter = filter;
      });

  @override
  Widget build(BuildContext context) {
    final d = _data;
    final pendingCount = d?.pending.length ?? 0;

    final dests = <(IconData, String)>[
      (Icons.dashboard_rounded, 'Panel'),
      (Icons.flag_rounded, 'Alertas'),
      (Icons.place_rounded, 'Sitios'),
      (Icons.badge_rounded, 'Guardas'),
      (Icons.business_rounded, 'Clientes'),
    ];

    Widget icon(int i) {
      final base = Icon(dests[i].$1);
      if (i == 1 && pendingCount > 0) {
        return Badge(label: Text('$pendingCount'), child: base);
      }
      return base;
    }

    return LayoutBuilder(
      builder: (context, c) {
        final wide = c.maxWidth >= 820;
        return Scaffold(
          appBar: AppBar(
            backgroundColor: AppColors.navy,
            foregroundColor: Colors.white,
            title: Text(widget.profile.companyName ?? 'Administración'),
            actions: [
              IconButton(
                tooltip: 'Actualizar',
                icon: const Icon(Icons.refresh_rounded),
                onPressed: _load,
              ),
              if (!widget.preview)
                IconButton(
                  tooltip: 'Cerrar sesión',
                  icon: const Icon(Icons.logout_rounded),
                  onPressed: () => supabase.auth.signOut(),
                ),
            ],
          ),
          bottomNavigationBar: wide
              ? null
              : NavigationBar(
                  selectedIndex: _tab,
                  onDestinationSelected: (i) => _go(i),
                  destinations: [
                    for (var i = 0; i < dests.length; i++)
                      NavigationDestination(icon: icon(i), label: dests[i].$2),
                  ],
                ),
          body: Column(
            children: [
              if (widget.preview)
                Container(
                  width: double.infinity,
                  color: AppColors.amber,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  child: const Text(
                    'Vista previa: así la verá un administrador de empresa',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontWeight: FontWeight.w600, color: AppColors.navy),
                  ),
                ),
              Expanded(
                child: Row(
                  children: [
                    if (wide) ...[
                      NavigationRail(
                        selectedIndex: _tab,
                        labelType: NavigationRailLabelType.all,
                        onDestinationSelected: (i) => _go(i),
                        destinations: [
                          for (var i = 0; i < dests.length; i++)
                            NavigationRailDestination(
                              icon: icon(i),
                              label: Text(dests[i].$2),
                            ),
                        ],
                      ),
                      const VerticalDivider(width: 1),
                    ],
                    Expanded(child: _body(d)),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _body(AdminData? d) {
    if (_error != null && d == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_rounded, size: 40, color: AppColors.muted),
            const SizedBox(height: 10),
            const Text('No pudimos cargar los datos.'),
            const SizedBox(height: 12),
            OutlinedButton(
              style: smallOutline(),
              onPressed: _load,
              child: const Text('Reintentar'),
            ),
          ],
        ),
      );
    }
    if (d == null) {
      return const Center(child: CircularProgressIndicator(color: AppColors.navy));
    }
    switch (_tab) {
      case 1:
        return FlagsView(
          d: d,
          filter: _flagFilter,
          onFilter: (f) => setState(() => _flagFilter = f),
          reload: _load,
        );
      case 2:
        return SitesView(d: d, reload: _load);
      case 3:
        return GuardsView(d: d, reload: _load);
      case 4:
        return ClientsView(d: d, reload: _load);
      default:
        return _Dashboard(
          d: d,
          profile: widget.profile,
          reload: _load,
          go: _go,
        );
    }
  }
}

// ───────────────────────── Panel (centro de mando) ─────────────────────────

class _Dashboard extends StatelessWidget {
  const _Dashboard({
    required this.d,
    required this.profile,
    required this.reload,
    required this.go,
  });

  final AdminData d;
  final Profile profile;
  final Reload reload;
  final void Function(int tab, {String? filter}) go;

  @override
  Widget build(BuildContext context) {
    final pending = d.pending;
    final repeat = d.repeatGuards;
    final activeGuards = d.guards.where((g) => g.active).length;
    final verified = d.verifiedTodayGuards.length;
    final uncovered = d.sitesWithoutCheckToday;

    final kpis = [
      Kpi(
        label: 'Alertas por revisar',
        value: '${pending.length}',
        icon: Icons.flag_rounded,
        color: pending.isEmpty ? kOk : AppColors.danger,
        onTap: () => go(1, filter: 'pending'),
      ),
      Kpi(
        label: 'Guardas reincidentes',
        value: '${repeat.length}',
        icon: Icons.repeat_rounded,
        color: repeat.isEmpty ? kOk : AppColors.danger,
        onTap: () => go(1, filter: 'repeat'),
      ),
      Kpi(
        label: 'Guardas verificados hoy',
        value: '$verified de $activeGuards',
        icon: Icons.how_to_reg_rounded,
        color: AppColors.navy,
        onTap: () => go(3),
      ),
      Kpi(
        label: 'Sitios sin verificación hoy',
        value: '${uncovered.length}',
        icon: Icons.location_off_rounded,
        color: uncovered.isEmpty ? kOk : kWarn,
        onTap: () => go(2),
      ),
    ];

    return AdminPage(
      onRefresh: reload,
      children: [
        Text(
          'Hola, ${profile.firstName}',
          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 4),
        const Text(
          'Toca cualquier tarjeta, alerta o sitio para ir directo al detalle.',
          style: TextStyle(color: AppColors.muted),
        ),
        const SizedBox(height: 16),
        LayoutBuilder(
          builder: (context, c) {
            const gap = 12.0;
            final cols = c.maxWidth >= 900 ? 4 : (c.maxWidth >= 520 ? 2 : 1);
            final w = (c.maxWidth - gap * (cols - 1)) / cols;
            return Wrap(
              spacing: gap,
              runSpacing: gap,
              children: [for (final k in kpis) SizedBox(width: w, child: k)],
            );
          },
        ),
        const SizedBox(height: 24),
        LayoutBuilder(
          builder: (context, c) {
            final flagsCol = _FlagsCard(d: d, reload: reload, go: go);
            final mapCol = _MapCard(d: d, reload: reload, go: go);
            if (c.maxWidth >= 900) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: flagsCol),
                  const SizedBox(width: 16),
                  Expanded(child: mapCol),
                ],
              );
            }
            return Column(
              children: [flagsCol, const SizedBox(height: 24), mapCol],
            );
          },
        ),
      ],
    );
  }
}

class _FlagsCard extends StatelessWidget {
  const _FlagsCard({required this.d, required this.reload, required this.go});
  final AdminData d;
  final Reload reload;
  final void Function(int tab, {String? filter}) go;

  @override
  Widget build(BuildContext context) {
    final pending = d.pending;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHead(
          'Por revisar',
          trailing: pending.length > 5
              ? TextButton(
                  onPressed: () => go(1, filter: 'pending'),
                  child: Text('Ver las ${pending.length}'),
                )
              : null,
        ),
        if (pending.isEmpty)
          const Panel(
            child: EmptyState(Icons.verified_rounded, 'Nada pendiente. Todo revisado.'),
          )
        else
          for (final v in pending.take(5)) FlagTile(d: d, v: v, reload: reload),
      ],
    );
  }
}

class _MapCard extends StatelessWidget {
  const _MapCard({required this.d, required this.reload, required this.go});
  final AdminData d;
  final Reload reload;
  final void Function(int tab, {String? filter}) go;

  @override
  Widget build(BuildContext context) {
    final sites = d.sites.where((s) => s.hasCoords).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHead('Mapa de sitios'),
        if (sites.isEmpty)
          Panel(
            child: EmptyState(
              Icons.map_outlined,
              'Aún no hay sitios con ubicación.',
              action: FilledButton(
                style: smallBtn(),
                onPressed: () => go(2),
                child: const Text('Ir a Sitios'),
              ),
            ),
          )
        else
          ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: SizedBox(
              height: 340,
              child: FlutterMap(
                options: MapOptions(
                  initialCenter: LatLng(
                    sites.map((s) => s.lat!).reduce((a, b) => a + b) / sites.length,
                    sites.map((s) => s.lng!).reduce((a, b) => a + b) / sites.length,
                  ),
                  initialZoom: sites.length == 1 ? 15 : 12,
                ),
                children: [
                  TileLayer(
                    urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                    userAgentPackageName: 'app.saasdag',
                  ),
                  MarkerLayer(
                    markers: [
                      for (final s in sites)
                        Marker(
                          point: LatLng(s.lat!, s.lng!),
                          width: 44,
                          height: 44,
                          child: GestureDetector(
                            onTap: () => showSiteSheet(context, d, s, reload),
                            child: Icon(
                              Icons.location_on,
                              size: 44,
                              color: d.pendingAt(s.id) > 0
                                  ? AppColors.danger
                                  : AppColors.navy,
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
