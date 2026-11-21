import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/money.dart';
import '../../domain/models/party.dart';
import '../../export/tabular.dart';
import '../customer_statement_flow.dart';
import '../print_actions.dart';
import '../record_actions.dart';
import '../../domain/models/user.dart';
import '../providers.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/forms.dart';
import 'parties_page.dart';

/// Payments register + quick receive/pay and account balances.
class LedgersPage extends ConsumerStatefulWidget {
  const LedgersPage({super.key});
  @override
  ConsumerState<LedgersPage> createState() => _LedgersPageState();
}

class _LedgersPageState extends ConsumerState<LedgersPage> {
  DateTime _from = DateTime(DateTime.now().year, DateTime.now().month);
  DateTime _to = DateTime.now();
  PaymentDirection? _dir;

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.of(context);
    final app = ref.watch(liveServicesProvider);
    final pays =
        app.parties
            .payments(from: _from, to: _to)
            .where((p) => _dir == null || p.direction == _dir)
            .toList();
    final cust = {
      for (final p in app.parties.list(
        PartyKind.customer,
        includeInactive: true,
      ))
        p.id: p.name,
    };
    final sup = {
      for (final p in app.parties.list(
        PartyKind.supplier,
        includeInactive: true,
      ))
        p.id: p.name,
    };
    String who(Payment p) =>
        p.partyId == null
            ? 'Walk-in'
            : ((p.partyKind == PartyKind.customer
                    ? cust[p.partyId]
                    : sup[p.partyId]) ??
                '');
    final received = Money.sum(
      pays
          .where((p) => !p.voided && p.direction == PaymentDirection.received)
          .map((p) => p.amount),
    );
    final paid = Money.sum(
      pays
          .where((p) => !p.voided && p.direction == PaymentDirection.paid)
          .map((p) => p.amount),
    );
    // One scroll view for the whole page: the header actions, stat cards and
    // filters wrap onto extra lines on small / scaled windows, so the payments
    // table must not be squeezed into the leftover height of an Expanded.
    return SingleChildScrollView(
      padding: const EdgeInsets.all(28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: 'Payments & Ledgers',
            breadcrumbs: const ['Payments & Ledgers'],
            actions: [
              ExportMenu(tables: () => [ExportTable(
                        'Payments',
                        [
                          'No',
                          'Date',
                          'Account',
                          'Direction',
                          'Method',
                          'Amount',
                          'Void',
                        ],
                        [
                          for (final p in pays)
                            [
                              p.number,
                              dateTimeFmt.format(p.at),
                              who(p),
                              p.direction.name,
                              p.method.label,
                              p.amount.paisa / 100,
                              p.voided ? p.voidReason : '',
                            ],
                        ],
                      )]),
              OutlinedButton.icon(
                key: const ValueKey('ledgers-customer-statement'),
                icon: const Icon(Icons.receipt_long_outlined, size: 18),
                label: const Text('Print Customer Statement'),
                onPressed: () => showCustomerStatement(context, ref),
              ),
              FilledButton.icon(
                icon: const Icon(Icons.call_received, size: 18),
                label: const Text('Receive from Customer'),
                onPressed: () async {
                  final p = await pickFromList<Party>(
                    context,
                    title: 'Customer',
                    items: app.parties.list(PartyKind.customer),
                    label: (x) => x.name,
                    subtitle: (x) => 'Balance ${x.balance.format()}',
                  );
                  if (p != null && context.mounted) {
                    await showPaymentDialog(context, ref, p);
                  }
                },
              ),
              FilledButton.icon(
                icon: const Icon(Icons.call_made, size: 18),
                label: const Text('Pay Supplier'),
                onPressed: () async {
                  final p = await pickFromList<Party>(
                    context,
                    title: 'Supplier',
                    items: app.parties.list(PartyKind.supplier),
                    label: (x) => x.name,
                    subtitle: (x) => 'Payable ${x.balance.format()}',
                  );
                  if (p != null && context.mounted) {
                    await showPaymentDialog(context, ref, p);
                  }
                },
              ),
            ],
          ),
          ResponsiveGrid(
            minItemWidth: 210,
            spacing: 14,
            children: [
              StatCard(
                label: 'Customer Receivables',
                icon: Icons.call_received,
                value: AnimatedMoney(app.parties.totalReceivables()),
              ),
              StatCard(
                label: 'Supplier Payables',
                icon: Icons.call_made,
                value: AnimatedMoney(app.parties.totalPayables()),
                tone: c.danger,
              ),
              StatCard(
                label: 'Received (period)',
                icon: Icons.south_west,
                value: AnimatedMoney(received),
              ),
              StatCard(
                label: 'Paid out (period)',
                icon: Icons.north_east,
                value: AnimatedMoney(paid),
                tone: c.warning,
              ),
            ],
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              ChoiceChip(
                label: const Text('All'),
                selected: _dir == null,
                onSelected: (_) => setState(() => _dir = null),
              ),
              ChoiceChip(
                label: const Text('Received'),
                selected: _dir == PaymentDirection.received,
                onSelected:
                    (_) => setState(() => _dir = PaymentDirection.received),
              ),
              ChoiceChip(
                label: const Text('Paid'),
                selected: _dir == PaymentDirection.paid,
                onSelected: (_) => setState(() => _dir = PaymentDirection.paid),
              ),
              DateRangeBar(
                from: _from,
                to: _to,
                onChanged:
                    (a, b) => setState(() {
                      _from = a;
                      _to = b;
                    }),
              ),
            ],
          ),
          const SizedBox(height: 12),
          AppTable<Payment>(
            rows: pays,
            pageSize: 40,
            onRowTap: (p) => showPaymentActions(context, ref, p),
            empty: const EmptyState(
              icon: Icons.account_balance_wallet_outlined,
              title: 'No payments in this period',
              message: 'Payments received and made are listed here.',
            ),
            columns: [
              AppColumn(
                'No',
                (p) => Text(
                  p.number,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              AppColumn('Date', (p) => Text(dateTimeFmt.format(p.at))),
              AppColumn('Account', flex: 3, (p) => Text(who(p))),
              AppColumn('Method', (p) => Text(p.method.label)),
              AppColumn('For', (p) => Text(p.refType)),
              AppColumn(
                'Amount',
                numeric: true,
                (p) => Text(
                  '${p.direction == PaymentDirection.received ? '+' : '−'}${p.amount.format()}',
                  style: TextStyle(
                    color:
                        p.voided
                            ? c.textMuted
                            : (p.direction == PaymentDirection.received
                                ? c.accent
                                : c.warning),
                    fontWeight: FontWeight.w700,
                    decoration: p.voided ? TextDecoration.lineThrough : null,
                  ),
                ),
              ),
actionsColumn<Payment>((x) => RowActionsMenu(
                  onView: () => showPaymentActions(context, ref, x),
                  onDelete: !x.voided && app.ctx.can(Permission.cancelTransactions) ? () => deletePaymentRecord(context, ref, x) : null,
                )),
],
          ),
        ],
      ),
    );
  }
}
