import 'package:flutter/material.dart';

import '../../theme.dart';
import '../sites/implement_catalog.dart';
import '../sites/site_data.dart' show kOrange, sevColor, siteStatusColor, siteStatusLabel;
import '../sites/site_detail.dart';
import '../sites/site_form.dart';
import '../sites/visitor_companies.dart';
import '../sites/visitor_photos.dart';
import 'admin_data.dart';
import 'admin_sheets.dart';
import 'admin_ui.dart';

// ───────────────────────── Sitios ─────────────────────────

class SitesView extends StatelessWidget {
  const SitesView({super.key, required this.d, required this.reload});
  final AdminData d;
  final Reload reload;

  Future<void> _new(BuildContext context) async {
    final cid = d.companyId;
    if (cid == null) {
      toast(context, 'Esta cuenta no tiene empresa asignada.');
      return;
    }
    final saved = await openSiteForm(context, asAdmin: true, companyId: cid, guards: d.guards);
    if (saved == true) await reload();
  }

  Widget _tile(BuildContext context, ASite s) {
    final pend = d.pendingAlertsAt(s.id);
    final worst = d.worstAt(s.id);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Panel(
        onTap: () => openSiteDetail(context, siteId: s.id, asAdmin: true, d: d, reload: reload),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Icon(Icons.place_rounded, color: s.approved ? AppColors.navy : siteStatusColor(s.status)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(s.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                  Text(
                    s.approved
                        ? '${d.clientName(s.clientId)} · ${d.guardsAt(s.id).length} guardas · ${s.radius} m'
                        : (s.status == 'returned' && (s.reviewNote ?? '').isNotEmpty
                            ? 'Devuelto: ${s.reviewNote}'
                            : 'Propuesta del supervisor'),
                    style: const TextStyle(color: AppColors.muted, fontSize: 13),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (!s.approved) Pill(siteStatusLabel(s.status), siteStatusColor(s.status)),
                if (s.approved && !s.active) const Pill('Inactivo', AppColors.muted),
                if (pend > 0) ...[
                  const SizedBox(height: 4),
                  Pill('$pend alertas', sevColor(worst)),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final toApprove = d.sites.where((s) => s.status == 'pending').toList();
    final approved = d.sites.where((s) => s.approved).toList();
    final others = d.sites.where((s) => s.status == 'returned' || s.status == 'draft').toList();
    return AdminPage(
      onRefresh: reload,
      children: [
        SectionHead(
          'Sitios (${approved.length})',
          trailing: FilledButton.icon(
            style: smallBtn(),
            onPressed: () => _new(context),
            icon: const Icon(Icons.add_rounded),
            label: const Text('Nuevo sitio'),
          ),
        ),
        Wrap(
          spacing: 4,
          children: [
            TextButton.icon(
              onPressed: () {
                final cid = d.companyId;
                if (cid == null) return;
                openImplementCatalog(context, companyId: cid);
              },
              icon: const Icon(Icons.inventory_2_outlined),
              label: const Text('Catálogo de implementos y nivel de alerta'),
            ),
            TextButton.icon(
              onPressed: () {
                final cid = d.companyId;
                if (cid == null) return;
                openVisitorCompanies(context, companyId: cid);
              },
              icon: const Icon(Icons.business_outlined),
              label: const Text('Empresas que visitan'),
            ),
            TextButton.icon(
              onPressed: () {
                final cid = d.companyId;
                if (cid == null) return;
                openVisitorPhotos(context, companyId: cid);
              },
              icon: const Icon(Icons.photo_library_outlined),
              label: const Text('Fotos de documentos'),
            ),
          ],
        ),
        const SizedBox(height: 6),
        if (toApprove.isNotEmpty) ...[
          Text('Por aprobar (${toApprove.length})',
              style: const TextStyle(fontWeight: FontWeight.w800, color: kOrange)),
          const SizedBox(height: 8),
          for (final s in toApprove) _tile(context, s),
          const SizedBox(height: 12),
        ],
        if (approved.isEmpty)
          const EmptyState(
            Icons.place_outlined,
            'Aún no hay sitios aprobados. Crea uno o aprueba la propuesta de un supervisor.',
          )
        else
          for (final s in approved) _tile(context, s),
        if (others.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text('Con el supervisor: devueltos o en borrador (${others.length})',
              style: const TextStyle(fontWeight: FontWeight.w800, color: AppColors.muted)),
          const SizedBox(height: 8),
          for (final s in others) _tile(context, s),
        ],
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
