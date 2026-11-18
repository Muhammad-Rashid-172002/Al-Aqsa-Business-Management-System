import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/errors.dart';
import '../../core/money.dart';
import '../theme.dart';

/// Elevated surface card with soft depth and an optional hover lift.
class AppCard extends StatefulWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final bool hoverLift;
  final VoidCallback? onTap;
  final Gradient? gradient;
  const AppCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(20),
    this.hoverLift = false,
    this.onTap,
    this.gradient,
  });

  @override
  State<AppCard> createState() => _AppCardState();
}

class _AppCardState extends State<AppCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.of(context);
    final lifted = widget.hoverLift && _hover;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor:
          widget.onTap != null ? SystemMouseCursors.click : MouseCursor.defer,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          transform:
              Matrix4.identity()
                ..setEntry(3, 2, 0.001)
                ..translateByDouble(0.0, lifted ? -3.0 : 0.0, 0.0, 1.0)
                ..rotateX(lifted ? 0.02 : 0),
          // Shadow (and optional gradient) only. The card surface and border
          // are painted by the Material below, so ListTiles / InkWells inside
          // a card draw their background and ink splashes on the card itself
          // (Flutter 3.50 reports an error when a coloured box hides them).
          decoration: BoxDecoration(
            gradient: widget.gradient,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(
                  alpha:
                      c.dark ? (lifted ? 0.45 : 0.28) : (lifted ? 0.10 : 0.05),
                ),
                blurRadius: lifted ? 26 : 14,
                offset: Offset(0, lifted ? 12 : 6),
              ),
            ],
          ),
          child: Material(
            color: widget.gradient == null ? c.surface : Colors.transparent,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(
                color: lifted ? c.accent.withValues(alpha: 0.35) : c.border,
              ),
            ),
            clipBehavior: Clip.antiAlias,
            animationDuration: const Duration(milliseconds: 180),
            child: Padding(padding: widget.padding, child: widget.child),
          ),
        ),
      ),
    );
  }
}

/// Keyboard shortcuts that work no matter which widget has focus.
///
/// `Shortcuts` / `CallbackShortcuts` only see key events that bubble up from
/// the focused widget. After a focused field is disposed or the user clicks an
/// empty area, focus falls back to the route's FocusScope (above those
/// widgets) and the shortcuts silently stop working. This widget listens via
/// [HardwareKeyboard] instead and only reacts while its own route is the top
/// route, so open dialogs, menus and dropdowns keep their own keys.
class AppShortcuts extends StatefulWidget {
  final Map<ShortcutActivator, VoidCallback> bindings;
  final Widget child;
  const AppShortcuts({super.key, required this.bindings, required this.child});

  @override
  State<AppShortcuts> createState() => _AppShortcutsState();
}

class _AppShortcutsState extends State<AppShortcuts> {
  ModalRoute<dynamic>? _route;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  bool _onKey(KeyEvent event) {
    if (!mounted) return false;
    final route = _route;
    if (route != null && !route.isCurrent) {
      return false; // a dialog or menu is on top
    }
    for (final entry in widget.bindings.entries) {
      if (entry.key.accepts(event, HardwareKeyboard.instance)) {
        entry.value();
        return true;
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Animated number that counts up when its value changes.
class AnimatedMoney extends StatelessWidget {
  final Money value;
  final TextStyle? style;
  const AnimatedMoney(this.value, {super.key, this.style});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: value.paisa.toDouble()),
      duration: const Duration(milliseconds: 900),
      curve: Curves.easeOutCubic,
      builder:
          (_, v, __) =>
              Text(Money(v.round()).format(showDecimals: false), style: style),
    );
  }
}

class AnimatedCount extends StatelessWidget {
  final int value;
  final TextStyle? style;
  const AnimatedCount(this.value, {super.key, this.style});
  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(begin: 0, end: value.toDouble()),
    duration: const Duration(milliseconds: 800),
    curve: Curves.easeOutCubic,
    builder: (_, v, __) => Text(v.round().toString(), style: style),
  );
}

class StatCard extends StatelessWidget {
  final String label;
  final IconData icon;
  final Widget value;
  final String? caption;
  final Color? tone;
  final VoidCallback? onTap;
  const StatCard({
    super.key,
    required this.label,
    required this.icon,
    required this.value,
    this.caption,
    this.tone,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.of(context);
    final t = tone ?? c.accent;
    return AppCard(
      hoverLift: true,
      onTap: onTap,
      padding: const EdgeInsets.all(18),
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              gradient: LinearGradient(
                colors: [t.withValues(alpha: 0.28), t.withValues(alpha: 0.08)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
            child: Icon(icon, color: t, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: c.textMuted,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 4),
                // Large amounts shrink to fit the card instead of splitting digits.
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: AlignmentDirectional.centerStart,
                  child: DefaultTextStyle(
                    maxLines: 1,
                    style: TextStyle(
                      color: c.text,
                      fontSize: 21,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.3,
                    ),
                    child: value,
                  ),
                ),
                if (caption != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    caption!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: c.textMuted, fontSize: 11.5),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class PageHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final List<String> breadcrumbs;
  final List<Widget> actions;
  const PageHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.breadcrumbs = const [],
    this.actions = const [],
  });

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.of(context);
    final titleBlock = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (breadcrumbs.isNotEmpty)
          Text(
            ['Home', ...breadcrumbs].join('  ›  '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: c.textMuted, fontSize: 12),
          ),
        const SizedBox(height: 4),
        Text(
          title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 26,
            fontWeight: FontWeight.w700,
            color: c.text,
            letterSpacing: -0.4,
          ),
        ),
        if (subtitle != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(subtitle!, style: TextStyle(color: c.textMuted)),
          ),
      ],
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: LayoutBuilder(
        builder: (_, cons) {
          if (actions.isEmpty) return titleBlock;
          // Narrow: title on top, actions wrap underneath.
          if (cons.maxWidth < 760) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                titleBlock,
                const SizedBox(height: 12),
                Wrap(spacing: 10, runSpacing: 10, children: actions),
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(child: titleBlock),
              const SizedBox(width: 16),
              Flexible(
                child: Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 10,
                  runSpacing: 10,
                  children: actions,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Equal-width card grid: as many columns as fit [minItemWidth], wrapping
/// to new rows on narrow windows.
class ResponsiveGrid extends StatelessWidget {
  final List<Widget> children;
  final double minItemWidth;
  final double spacing;
  const ResponsiveGrid({
    super.key,
    required this.children,
    this.minItemWidth = 250,
    this.spacing = 16,
  });

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (_, cons) {
      if (children.isEmpty) return const SizedBox.shrink();
      final cols = (cons.maxWidth / minItemWidth).floor().clamp(
        1,
        children.length,
      );
      final w = (cons.maxWidth - (cols - 1) * spacing) / cols;
      return Wrap(
        spacing: spacing,
        runSpacing: spacing,
        children: [for (final ch in children) SizedBox(width: w, child: ch)],
      );
    },
  );
}

/// Side-by-side panels on wide windows, stacked on narrow ones.
class AdaptiveSplit extends StatelessWidget {
  final List<Widget> children;
  final List<int>? flex;
  final double breakpoint;
  final double spacing;
  const AdaptiveSplit({
    super.key,
    required this.children,
    this.flex,
    this.breakpoint = 900,
    this.spacing = 16,
  });

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (_, cons) {
      if (cons.maxWidth >= breakpoint) {
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var k = 0; k < children.length; k++) ...[
              if (k > 0) SizedBox(width: spacing),
              Expanded(flex: flex?[k] ?? 1, child: children[k]),
            ],
          ],
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var k = 0; k < children.length; k++) ...[
            if (k > 0) SizedBox(height: spacing),
            children[k],
          ],
        ],
      );
    },
  );
}

/// Gives [child] at least [minWidth] x [minHeight] and scrolls when the
/// window is smaller, so screens built from `Expanded` panels never get
/// squeezed below a usable size (small laptops, 125-150% Windows scaling).
/// When the space is large enough this is a no-op.
class MinSizeScroll extends StatefulWidget {
  final Widget child;
  final double minWidth;
  final double minHeight;
  const MinSizeScroll({
    super.key,
    required this.child,
    this.minWidth = 0,
    this.minHeight = 0,
  });
  @override
  State<MinSizeScroll> createState() => _MinSizeScrollState();
}

class _MinSizeScrollState extends State<MinSizeScroll> {
  final _v = ScrollController();
  final _h = ScrollController();

  @override
  void dispose() {
    _v.dispose();
    _h.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (_, cons) {
      final needW = cons.hasBoundedWidth && cons.maxWidth < widget.minWidth;
      final needH = cons.hasBoundedHeight && cons.maxHeight < widget.minHeight;
      if (!needW && !needH) return widget.child;
      final w = needW ? widget.minWidth : cons.maxWidth;
      final h = needH ? widget.minHeight : cons.maxHeight;
      Widget box = SizedBox(width: w, height: h, child: widget.child);
      if (needW) {
        box = Scrollbar(
          controller: _h,
          thumbVisibility: true,
          notificationPredicate: (n) => n.depth == 0,
          child: SingleChildScrollView(
            controller: _h,
            scrollDirection: Axis.horizontal,
            child: box,
          ),
        );
      }
      if (needH) {
        box = Scrollbar(
          controller: _v,
          thumbVisibility: true,
          child: SingleChildScrollView(
            controller: _v,
            child: needW ? SizedBox(height: h + 14, child: box) : box,
          ),
        );
      }
      return box;
    },
  );
}

class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  final Widget? action;
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.of(context);
    return Center(
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 500),
        curve: Curves.easeOutBack,
        builder:
            (_, t, child) => Opacity(
              opacity: t.clamp(0, 1),
              child: Transform.scale(scale: 0.9 + 0.1 * t, child: child),
            ),
        child: Padding(
          padding: const EdgeInsets.all(40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 84,
                height: 84,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      c.accent.withValues(alpha: 0.22),
                      c.accent.withValues(alpha: 0.02),
                    ],
                  ),
                ),
                child: Icon(icon, size: 38, color: c.accent),
              ),
              const SizedBox(height: 16),
              Text(
                title,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: c.text,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                message,
                textAlign: TextAlign.center,
                style: TextStyle(color: c.textMuted),
              ),
              if (action != null) ...[const SizedBox(height: 18), action!],
            ],
          ),
        ),
      ),
    );
  }
}

/// Column definition for [AppTable].
class AppColumn<T> {
  final String label;
  final int flex;
  final bool numeric;
  final Widget Function(T row) cell;

  /// Narrowest usable width for this column. Defaults to 52 px per flex unit
  /// (min 72). When the table is narrower than the sum of its columns it
  /// scrolls horizontally instead of squeezing cells.
  final double? minWidth;
  const AppColumn(
    this.label,
    this.cell, {
    this.flex = 2,
    this.numeric = false,
    this.minWidth,
  });

  double get effectiveMinWidth => minWidth ?? math.max(72, flex * 52.0);
}

/// Clean, paginated data table built for large lists.
class AppTable<T> extends StatefulWidget {
  final List<T> rows;
  final List<AppColumn<T>> columns;
  final void Function(T row)? onRowTap;
  final int pageSize;
  final Widget? empty;
  const AppTable({
    super.key,
    required this.rows,
    required this.columns,
    this.onRowTap,
    this.pageSize = 25,
    this.empty,
  });

  @override
  State<AppTable<T>> createState() => _AppTableState<T>();
}

class _AppTableState<T> extends State<AppTable<T>> {
  int _page = 0;
  int? _hover;
  final _hScroll = ScrollController();

  @override
  void dispose() {
    _hScroll.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant AppTable<T> old) {
    super.didUpdateWidget(old);
    final pages = (widget.rows.length / widget.pageSize).ceil();
    if (_page >= pages) _page = pages == 0 ? 0 : pages - 1;
  }

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.of(context);
    if (widget.rows.isEmpty) return widget.empty ?? const SizedBox.shrink();
    final pages = (widget.rows.length / widget.pageSize).ceil();
    final start = _page * widget.pageSize;
    final slice = widget.rows.skip(start).take(widget.pageSize).toList();

    Widget cellBox(AppColumn<T> col, Widget child) => Expanded(
      flex: col.flex,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Align(
          alignment: col.numeric ? Alignment.centerRight : Alignment.centerLeft,
          child: child,
        ),
      ),
    );

    // 40 = horizontal row padding; 8 px breathing room between columns.
    final minTableWidth = widget.columns.fold<double>(
      40,
      (a, col) => a + col.effectiveMinWidth + 8,
    );

    Widget table(double width) => SizedBox(
      width: width,
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            decoration: BoxDecoration(
              color: c.surfaceHigh,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(16),
              ),
            ),
            child: Row(
              children: [
                for (final col in widget.columns)
                  cellBox(
                    col,
                    Text(
                      col.label.toUpperCase(),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: c.textMuted,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.6,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          for (var k = 0; k < slice.length; k++)
            MouseRegion(
              onEnter: (_) => setState(() => _hover = k),
              onExit: (_) => setState(() => _hover = null),
              cursor:
                  widget.onRowTap != null
                      ? SystemMouseCursors.click
                      : MouseCursor.defer,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap:
                    widget.onRowTap == null
                        ? null
                        : () => widget.onRowTap!(slice[k]),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 13,
                  ),
                  decoration: BoxDecoration(
                    color:
                        _hover == k
                            ? c.accent.withValues(alpha: 0.06)
                            : Colors.transparent,
                    border: Border(
                      top: BorderSide(color: c.border.withValues(alpha: 0.6)),
                    ),
                  ),
                  child: DefaultTextStyle(
                    style: TextStyle(color: c.text, fontSize: 13.5),
                    child: Row(
                      children: [
                        for (final col in widget.columns)
                          cellBox(col, col.cell(slice[k])),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );

    final pager = Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: c.border)),
      ),
      child: Row(
        children: [
          Flexible(
            child: Text(
              '${start + 1}–${start + slice.length} of ${widget.rows.length}',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: c.textMuted, fontSize: 12.5),
            ),
          ),
          const Spacer(),
          IconButton(
            tooltip: 'Previous page',
            onPressed: _page > 0 ? () => setState(() => _page--) : null,
            icon: const Icon(Icons.chevron_left),
          ),
          Text(
            'Page ${_page + 1} / $pages',
            style: TextStyle(color: c.textMuted, fontSize: 12.5),
          ),
          IconButton(
            tooltip: 'Next page',
            onPressed: _page < pages - 1 ? () => setState(() => _page++) : null,
            icon: const Icon(Icons.chevron_right),
          ),
        ],
      ),
    );

    return AppCard(
      padding: EdgeInsets.zero,
      child: LayoutBuilder(
        builder: (_, cons) {
          final fits = !cons.hasBoundedWidth || cons.maxWidth >= minTableWidth;
          if (fits) {
            return Column(
              children: [
                table(cons.hasBoundedWidth ? cons.maxWidth : minTableWidth),
                pager,
              ],
            );
          }
          // Too narrow for every column: scroll sideways (scrollbar is draggable
          // with the mouse; Shift + wheel also works) and keep the pager fixed.
          return Column(
            children: [
              Scrollbar(
                controller: _hScroll,
                thumbVisibility: true,
                child: SingleChildScrollView(
                  controller: _hScroll,
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.only(bottom: 10),
                  child: table(minTableWidth),
                ),
              ),
              pager,
            ],
          );
        },
      ),
    );
  }
}

class StatusPill extends StatelessWidget {
  final String text;
  final Color color;
  const StatusPill(this.text, this.color, {super.key});
  @override
  Widget build(BuildContext context) => Tooltip(
    message: text,
    waitDuration: const Duration(milliseconds: 600),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(
        text,
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: color,
          fontSize: 11.5,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
  );
}

/// Animated toast for success / error feedback.
void showToast(BuildContext context, String message, {bool error = false}) {
  final c = AppTheme.of(context);
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        width: math.min(420, MediaQuery.sizeOf(context).width - 32),
        duration: Duration(seconds: error ? 5 : 3),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(
            color: (error ? c.danger : c.accent).withValues(alpha: 0.5),
          ),
        ),
        content: Row(
          children: [
            Icon(
              error ? Icons.error_outline : Icons.check_circle_outline,
              color: error ? c.danger : c.accent,
            ),
            const SizedBox(width: 12),
            Expanded(child: Text(message)),
          ],
        ),
      ),
    );
}

/// Runs an action, showing a friendly toast on success or failure.
Future<bool> runAction(
  BuildContext context,
  Future<void> Function() action, {
  String? success,
}) async {
  try {
    await action();
    if (context.mounted && success != null) showToast(context, success);
    return true;
  } catch (e) {
    if (context.mounted) showToast(context, friendlyError(e), error: true);
    return false;
  }
}

Future<bool> confirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  String confirm = 'Confirm',
  bool danger = false,
}) async {
  final c = AppTheme.of(context);
  final r = await showDialog<bool>(
    context: context,
    builder:
        (ctx) => AlertDialog(
          scrollable: true,
          title: Text(title),
          content: SizedBox(width: 420, child: Text(message)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style:
                  danger
                      ? FilledButton.styleFrom(backgroundColor: c.danger)
                      : null,
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(confirm),
            ),
          ],
        ),
  );
  return r ?? false;
}

class SearchBox extends StatelessWidget {
  final String hint;
  final ValueChanged<String> onChanged;
  final double width;
  final FocusNode? focusNode;
  final ValueChanged<String>? onSubmitted;
  final TextEditingController? controller;
  const SearchBox({
    super.key,
    required this.hint,
    required this.onChanged,
    this.width = 320,
    this.focusNode,
    this.onSubmitted,
    this.controller,
  });
  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: BoxConstraints(
      maxWidth: width,
      minWidth: math.min(width, 200),
    ),
    child: TextField(
      controller: controller,
      focusNode: focusNode,
      onChanged: onChanged,
      onSubmitted: onSubmitted,
      decoration: InputDecoration(
        hintText: hint,
        prefixIcon: const Icon(Icons.search, size: 20),
      ),
    ),
  );
}
