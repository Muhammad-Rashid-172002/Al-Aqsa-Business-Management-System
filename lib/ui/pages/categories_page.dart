import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/qty.dart';
import '../../domain/models/product.dart';
import '../providers.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/forms.dart';

class CategoriesPage extends ConsumerWidget {
  const CategoriesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = AppTheme.of(context);
    final app = ref.watch(liveServicesProvider);
    final cats = app.catalog.categories();
    final products = app.catalog.products();
    Future<void> edit([ProductCategory? cat]) async {
      final name = await promptText(context, title: cat == null ? 'New category' : 'Rename category', label: 'Category name', initial: cat?.name ?? '');
      if (name == null || !context.mounted) return;
      await runAction(context, () => app.catalog.saveCategory(name, id: cat?.id), success: 'Category saved');
    }

    return Padding(
      padding: const EdgeInsets.all(28),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        PageHeader(
          title: 'Categories',
          breadcrumbs: const ['Categories'],
          subtitle: '${cats.length} categories',
          actions: [FilledButton.icon(onPressed: () => edit(), icon: const Icon(Icons.add), label: const Text('Add Category'))],
        ),
        Expanded(
          child: SingleChildScrollView(
            child: AppTable<ProductCategory>(
              rows: cats,
              onRowTap: edit,
              empty: EmptyState(
                icon: Icons.category_outlined,
                title: 'No categories yet',
                message: 'Group products, e.g. Cameras, DVR/NVR, Hard Disks, Cables, Power Supplies.',
                action: FilledButton.icon(onPressed: () => edit(), icon: const Icon(Icons.add), label: const Text('Add Category')),
              ),
              columns: [
                AppColumn('Category', flex: 4, (x) => Text(x.name, style: const TextStyle(fontWeight: FontWeight.w600))),
                AppColumn('Products', numeric: true, (x) => Text('${products.where((p) => p.categoryId == x.id).length}')),
                AppColumn('Units in stock', numeric: true, (x) => Text(Qty.sum(products.where((p) => p.categoryId == x.id).map((p) => p.stockQty)).format())),
                AppColumn('', flex: 1, numeric: true, (x) => IconButton(
                      tooltip: 'Delete',
                      icon: Icon(Icons.delete_outline, color: c.danger),
                      onPressed: () async {
                        if (await confirmDialog(context, title: 'Delete "${x.name}"?', message: 'Only empty categories can be deleted.', confirm: 'Delete', danger: true) && context.mounted) {
                          await runAction(context, () => app.catalog.deleteCategory(x.id), success: 'Category deleted');
                        }
                      },
                    )),
              ],
            ),
          ),
        ),
      ]),
    );
  }
}
