import 'package:flutter/material.dart';

import '../../models/profile.dart';
import '../../supabase.dart';
import '../../theme.dart';
import '../admin/admin_ui.dart' show EmptyState, Panel, Pill;
import '../sites/site_data.dart';
import '../sites/site_detail.dart';
import '../sites/site_form.dart';
import '../sites/visit_history.dart';

/// Supervisión y monitoreo (v1): sus sitios y las propuestas de sitios nuevos.
class SupervisorHome extends StatefulWidget {
  const SupervisorHome({super.key, required this.profile});
  final Profile profile;

  @override
  State<SupervisorHome> createState() => _SupervisorHomeState();
}

class _SupervisorHomeState extends State<SupervisorHome> {
  List<Map<String, dynamic>>? _sites;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final rows = await supabase
          .from('sites')
          .select('id, name, status, active, review_note, address, radius_m, visitor_control')
          .order('name');
      if (!mounted) return;
      setState(() {
        _sites = rows;
        _error = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = 'No se pudieron cargar tus sitios. Revisa tu conexión.');
    }
  }

  Future<void> _propose() async {
    final saved = await openSiteForm(context, asAdmin: false);
    if (saved == true) await _load();
  }

  Widget _tile(Map<String, dynamic> s) {
    final status = (s['status'] as String?) ?? 'approved';
    final approved = status == 'approved';
    final note = s['review_note'] as String?;
    final active = (s['active'] as bool?) ?? false;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Panel(
        onTap: () => openSiteDetail(context, siteId: s['id'] as String, asAdmin: false, reload: _load),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Icon(Icons.place_rounded, color: approved ? AppColors.navy : siteStatusColor(status)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text((s['name'] as String?) ?? 'Sitio', style: const TextStyle(fontWeight: FontWeight.w700)),
                  Text(
                    status == 'returned' && (note ?? '').isNotEmpty
                        ? 'Devuelto: $note'
                        : ((s['address'] as String?) ?? '${s['radius_m'] ?? 100} m de perímetro'),
                    style: TextStyle(
                      color: status == 'returned' ? AppColors.danger : AppColors.muted,
                      fontSize: 13,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (!approved) Pill(siteStatusLabel(status), siteStatusColor(status)),
            if (approved && !active) const Pill('Inactivo', AppColors.muted),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final sites = _sites;
    final proposals = (sites ?? const []).where((s) => s['status'] != 'approved').toList();
    final mine = (sites ?? const []).where((s) => s['status'] == 'approved').toList();
    return Scaffold(
      appBar: AppBar(
        backgroundColor: AppColors.navy,
        foregroundColor: Colors.white,
        title: const Text('Supervisión y monitoreo'),
        actions: [
          IconButton(
            tooltip: 'Cerrar sesión',
            icon: const Icon(Icons.logout_rounded),
            onPressed: () => supabase.auth.signOut(),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _propose,
        icon: const Icon(Icons.add_location_alt_rounded),
        label: const Text('Proponer sitio'),
      ),
      body: sites == null
          ? Center(
              child: _error == null
                  ? const CircularProgressIndicator(color: AppColors.navy)
                  : Padding(padding: const EdgeInsets.all(24), child: Text(_error!, textAlign: TextAlign.center)),
            )
          : LayoutBuilder(
              builder: (context, c) {
                final side = ((c.maxWidth - 760) / 2).clamp(16.0, double.infinity);
                return RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: EdgeInsets.fromLTRB(side, 16, side, 96),
                    children: [
                      Text('Hola, ${widget.profile.firstName}',
                          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
                      const SizedBox(height: 4),
                      const Text(
                        'Registra los sitios nuevos desde el lugar: ubicación, puestos, implementos, consignas y el levantamiento. '
                        'El administrador los aprueba y asigna a los guardas.',
                        style: TextStyle(color: AppColors.muted),
                      ),
                      const SizedBox(height: 16),
                      if (proposals.isNotEmpty) ...[
                        Text('Mis propuestas (${proposals.length})',
                            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                        const SizedBox(height: 8),
                        for (final s in proposals) _tile(s),
                        const SizedBox(height: 16),
                      ],
                      if (mine.any((s) => s['visitor_control'] == true)) ...[
                        Panel(
                          onTap: () => openVisitHistory(
                            context,
                            sites: [
                              for (final s in mine)
                                if (s['visitor_control'] == true) (s['id'] as String, (s['name'] as String?) ?? 'Sitio'),
                            ],
                          ),
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                          child: const Row(
                            children: [
                              Icon(Icons.manage_search_rounded, color: AppColors.navy),
                              SizedBox(width: 12),
                              Expanded(
                                child: Text('Historial de visitas: buscar por placa, DPI, nombre o empresa',
                                    style: TextStyle(fontWeight: FontWeight.w700)),
                              ),
                              Icon(Icons.chevron_right_rounded, color: AppColors.muted),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                      ],
                      Text('Mis sitios (${mine.length})',
                          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                      const SizedBox(height: 8),
                      if (mine.isEmpty)
                        const Panel(
                          child: EmptyState(
                            Icons.place_outlined,
                            'Aún no tienes sitios asignados. Propón uno con el botón de abajo.',
                          ),
                        )
                      else
                        for (final s in mine) _tile(s),
                    ],
                  ),
                );
              },
            ),
    );
  }
}
