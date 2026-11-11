import 'package:flutter/material.dart';

import '../../theme.dart';
import 'admin_data.dart';
import 'admin_sheets.dart';
import 'admin_ui.dart';

/// Fila de bandera, reutilizada en el panel y en la lista de banderas.
class FlagTile extends StatelessWidget {
  const FlagTile({super.key, required this.d, required this.v, required this.reload});
  final AdminData d;
  final AVerif v;
  final Reload reload;

  @override
  Widget build(BuildContext context) {
    final repeat = v.guardId != null && d.repeatGuards.contains(v.guardId);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Panel(
        onTap: () => showFlagSheet(context, d, v, reload),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Icon(
              Icons.flag_rounded,
              color: v.pending ? AppColors.danger : AppColors.muted,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    d.guardName(v.guardId),
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${d.siteName(v.siteId)} · ${fmtWhen(v.createdAt)}',
                    style: const TextStyle(color: AppColors.muted, fontSize: 13),
                  ),
                  Text(
                    v.reason ?? 'Sin motivo',
                    style: const TextStyle(fontSize: 13),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Pill(Outcome.label(v.outcome), outcomeColor(v.outcome)),
                if (repeat) ...[
                  const SizedBox(height: 6),
                  const Pill('Reincidente', AppColors.danger),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ───────────────────────── Banderas ─────────────────────────

class FlagsView extends StatelessWidget {
  const FlagsView({
    super.key,
    required this.d,
    required this.filter,
    required this.onFilter,
    required this.reload,
  });

  final AdminData d;
  final String filter; // pending | repeat | reviewed | all
  final ValueChanged<String> onFilter;
  final Reload reload;

  @override
  Widget build(BuildContext context) {
    final repeat = d.repeatGuards;
    final all = d.flags;
    final list = all.where((v) {
      switch (filter) {
        case 'pending':
          return v.pending;
        case 'repeat':
          return v.guardId != null && repeat.contains(v.guardId);
        case 'reviewed':
          return v.reviewed;
        default:
          return true;
      }
    }).toList();

    final options = <String, String>{
      'pending': 'Pendientes (${d.pending.length})',
      'repeat': 'Reincidentes',
      'reviewed': 'Revisadas',
      'all': 'Todas (${all.length})',
    };

    return AdminPage(
      onRefresh: reload,
      children: [
        const SectionHead('Banderas · últimos 7 días'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final e in options.entries)
              ChoiceChip(
                label: Text(e.value),
                selected: filter == e.key,
                onSelected: (_) => onFilter(e.key),
              ),
          ],
        ),
        const SizedBox(height: 14),
        if (list.isEmpty)
          EmptyState(
            filter == 'pending' ? Icons.verified_rounded : Icons.flag_outlined,
            filter == 'pending'
                ? 'Nada pendiente. Todo revisado.'
                : 'No hay banderas con este filtro.',
          )
        else
          for (final v in list) FlagTile(d: d, v: v, reload: reload),
      ],
    );
  }
}

// ───────────────────────── Sitios ─────────────────────────

class SitesView extends StatelessWidget {
  const SitesView({super.key, required this.d, required this.reload});
  final AdminData d;
  final Reload reload;

  @override
  Widget build(BuildContext context) {
    return AdminPage(
      onRefresh: reload,
      children: [
        SectionHead(
          'Sitios (${d.sites.length})',
          trailing: FilledButton.icon(
            style: smallBtn(),
            onPressed: () {
              final cid = d.companyId;
              if (cid == null) {
                toast(context, 'Esta cuenta no tiene empresa asignada.');
                return;
              }
              showNewSiteDialog(context, d, cid, reload);
            },
            icon: const Icon(Icons.add_rounded),
            label: const Text('Nuevo sitio'),
          ),
        ),
        if (d.sites.isEmpty)
          const EmptyState(
            Icons.place_outlined,
            'Aún no hay sitios. Crea el primero para empezar a recibir verificaciones.',
          )
        else
          for (final s in d.sites)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Panel(
                onTap: () => showSiteSheet(context, d, s, reload),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                child: Row(
                  children: [
                    const Icon(Icons.place_rounded, color: AppColors.navy),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(s.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                          Text(
                            '${d.clientName(s.clientId)} · ${d.guardsAt(s.id).length} guardas · ${s.radius} m',
                            style: const TextStyle(color: AppColors.muted, fontSize: 13),
                          ),
                        ],
                      ),
                    ),
                    if (d.pendingAt(s.id) > 0)
                      Pill('${d.pendingAt(s.id)} pendientes', AppColors.danger),
                  ],
                ),
              ),
            ),
      ],
    );
  }
}

// ───────────────────────── Guardas ─────────────────────────

class GuardsView extends StatelessWidget {
  const GuardsView({super.key, required this.d, required this.reload});
  final AdminData d;
  final Reload reload;

  @override
  Widget build(BuildContext context) {
    final today = d.verifiedTodayGuards;
    final repeat = d.repeatGuards;
    return AdminPage(
      onRefresh: reload,
      children: [
        SectionHead('Guardas (${d.guards.length})'),
        if (d.guards.isEmpty)
          const EmptyState(
            Icons.badge_outlined,
            'Aún no hay guardas. Los usuarios se crearán desde aquí en la siguiente fase.',
          )
        else
          for (final g in d.guards)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Panel(
                onTap: () => showGuardSheet(context, d, g, reload),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                child: Row(
                  children: [
                    const Icon(Icons.badge_rounded, color: AppColors.navy),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(g.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                          Text(
                            '${(d.assign[g.id] ?? const <String>{}).length} sitios · ${d.flagCount(g.id)} banderas en 7 días',
                            style: const TextStyle(color: AppColors.muted, fontSize: 13),
                          ),
                        ],
                      ),
                    ),
                    if (!g.active)
                      const Pill('Inactivo', AppColors.muted)
                    else if (repeat.contains(g.id))
                      const Pill('Reincidente', AppColors.danger)
                    else if (today.contains(g.id))
                      const Pill('Verificado hoy', kOk)
                    else
                      const Pill('Sin verificar hoy', kWarn),
                  ],
                ),
              ),
            ),
      ],
    );
  }
}

// ───────────────────────── Clientes ─────────────────────────

class ClientsView extends StatelessWidget {
  const ClientsView({super.key, required this.d, required this.reload});
  final AdminData d;
  final Reload reload;

  @override
  Widget build(BuildContext context) {
    return AdminPage(
      onRefresh: reload,
      children: [
        SectionHead(
          'Clientes (${d.clients.length})',
          trailing: FilledButton.icon(
            style: smallBtn(),
            onPressed: () {
              final cid = d.companyId;
              if (cid == null) {
                toast(context, 'Esta cuenta no tiene empresa asignada.');
                return;
              }
              showNewClientDialog(context, cid, reload);
            },
            icon: const Icon(Icons.add_rounded),
            label: const Text('Nuevo cliente'),
          ),
        ),
        if (d.clients.isEmpty)
          const EmptyState(
            Icons.business_outlined,
            'Aún no hay clientes. Un cliente agrupa sus sitios.',
          )
        else
          for (final c in d.clients)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Panel(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                child: Row(
                  children: [
                    const Icon(Icons.business_rounded, color: AppColors.navy),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(c.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                          Text(
                            '${d.sites.where((s) => s.clientId == c.id).length} sitios',
                            style: const TextStyle(color: AppColors.muted, fontSize: 13),
                          ),
                        ],
                      ),
                    ),
                    if (!c.active) const Pill('Inactivo', AppColors.muted),
                  ],
                ),
              ),
            ),
      ],
    );
  }
}
