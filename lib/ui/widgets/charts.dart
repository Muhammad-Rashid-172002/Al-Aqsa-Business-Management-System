import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme.dart';

class BarSeries {
  final String name;
  final Color color;
  final List<double> values;
  const BarSeries(this.name, this.color, this.values);
}

/// Animated grouped bar chart with an optional line overlay.
class GroupedBarChart extends StatelessWidget {
  final List<String> labels;
  final List<BarSeries> bars;
  final BarSeries? line;
  final String Function(double) format;
  const GroupedBarChart({
    super.key,
    required this.labels,
    required this.bars,
    this.line,
    required this.format,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.of(context);
    return Column(
      children: [
        Expanded(
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: 1),
            duration: const Duration(milliseconds: 900),
            curve: Curves.easeOutCubic,
            builder:
                (_, t, __) => CustomPaint(
                  size: Size.infinite,
                  painter: _BarPainter(c, labels, bars, line, format, t),
                ),
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 18,
          children: [
            for (final s in [...bars, if (line != null) line!])
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: s.color,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    s.name,
                    style: TextStyle(color: c.textMuted, fontSize: 12),
                  ),
                ],
              ),
          ],
        ),
      ],
    );
  }
}

class _BarPainter extends CustomPainter {
  final AppColors c;
  final List<String> labels;
  final List<BarSeries> bars;
  final BarSeries? line;
  final String Function(double) format;
  final double t;
  _BarPainter(this.c, this.labels, this.bars, this.line, this.format, this.t);

  @override
  void paint(Canvas canvas, Size size) {
    const left = 64.0, bottom = 24.0, top = 8.0;
    final h = size.height - bottom - top;
    final w = size.width - left;
    var maxV = 0.0;
    for (final s in [...bars, if (line != null) line!]) {
      for (final v in s.values) {
        maxV = math.max(maxV, v);
      }
    }
    if (maxV <= 0) maxV = 1;
    final grid = Paint()..color = c.border.withValues(alpha: 0.6);
    final tp = TextPainter(textDirection: TextDirection.ltr);
    for (var k = 0; k <= 4; k++) {
      final y = top + h - h * k / 4;
      canvas.drawLine(Offset(left, y), Offset(size.width, y), grid);
      tp.text = TextSpan(
        text: format(maxV * k / 4),
        style: TextStyle(color: c.textMuted, fontSize: 10.5),
      );
      tp.layout();
      tp.paint(canvas, Offset(left - tp.width - 8, y - tp.height / 2));
    }
    final n = labels.length;
    if (n == 0) return;
    final group = w / n;
    final barW = math.min(26.0, group * 0.7 / bars.length);
    for (var k = 0; k < n; k++) {
      final gx = left + group * k + (group - barW * bars.length) / 2;
      for (var b = 0; b < bars.length; b++) {
        final v = bars[b].values[k] * t;
        final bh = h * v / maxV;
        final rect = RRect.fromRectAndCorners(
          Rect.fromLTWH(gx + barW * b, top + h - bh, barW - 3, bh),
          topLeft: const Radius.circular(5),
          topRight: const Radius.circular(5),
        );
        canvas.drawRRect(
          rect,
          Paint()
            ..shader = LinearGradient(
              colors: [bars[b].color, bars[b].color.withValues(alpha: 0.45)],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ).createShader(rect.outerRect),
        );
      }
      tp.text = TextSpan(
        text: labels[k],
        style: TextStyle(color: c.textMuted, fontSize: 11),
      );
      tp.layout();
      tp.paint(
        canvas,
        Offset(
          left + group * k + group / 2 - tp.width / 2,
          size.height - bottom + 6,
        ),
      );
    }
    if (line != null) {
      final path = Path();
      final pts = <Offset>[];
      for (var k = 0; k < n; k++) {
        final p = Offset(
          left + group * k + group / 2,
          top + h - h * math.max(0.0, line!.values[k] * t) / maxV,
        );
        pts.add(p);
        if (k == 0) {
          path.moveTo(p.dx, p.dy);
        } else {
          path.lineTo(p.dx, p.dy);
        }
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = line!.color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5
          ..strokeCap = StrokeCap.round,
      );
      for (final p in pts) {
        canvas.drawCircle(p, 4, Paint()..color = c.surface);
        canvas.drawCircle(
          p,
          4,
          Paint()
            ..color = line!.color
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _BarPainter old) =>
      old.t != t || old.bars != bars || old.c != c;
}

/// Animated donut chart with legend.
class DonutChart extends StatelessWidget {
  final Map<String, double> data;
  final List<Color> palette;
  final String centerLabel;
  const DonutChart({
    super.key,
    required this.data,
    required this.palette,
    this.centerLabel = '',
  });

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.of(context);
    final entries =
        data.entries.where((e) => e.value > 0).toList()
          ..sort((a, b) => b.value.compareTo(a.value));
    final total = entries.fold(0.0, (a, e) => a + e.value);
    return LayoutBuilder(
      builder: (context, cons) {
        final ring = (cons.maxWidth * 0.42).clamp(96.0, 150.0).toDouble();
        return Row(
          children: [
            SizedBox(
              width: ring,
              height: ring,
              child: TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: 1),
                duration: const Duration(milliseconds: 1000),
                curve: Curves.easeOutCubic,
                builder:
                    (_, t, __) => CustomPaint(
                      painter: _DonutPainter(
                        entries.map((e) => e.value).toList(),
                        palette,
                        c,
                        t,
                      ),
                      child: Center(
                        child: Padding(
                          padding: const EdgeInsets.all(28),
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  total.round().toString(),
                                  style: TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.w700,
                                    color: c.text,
                                  ),
                                ),
                                Text(
                                  centerLabel,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: c.textMuted,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
              ),
            ),
            SizedBox(width: ring < 130 ? 12 : 20),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var k = 0; k < entries.length && k < 6; k++)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: [
                          Container(
                            width: 10,
                            height: 10,
                            decoration: BoxDecoration(
                              color: palette[k % palette.length],
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              entries[k].key,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: c.text, fontSize: 12.5),
                            ),
                          ),
                          Text(
                            '${(entries[k].value / (total == 0 ? 1 : total) * 100).round()}%',
                            style: TextStyle(color: c.textMuted, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _DonutPainter extends CustomPainter {
  final List<double> values;
  final List<Color> palette;
  final AppColors c;
  final double t;
  _DonutPainter(this.values, this.palette, this.c, this.t);

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromCircle(
      center: size.center(Offset.zero),
      radius: size.shortestSide / 2 - 10,
    );
    final stroke =
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 18
          ..strokeCap = StrokeCap.butt;
    canvas.drawArc(rect, 0, math.pi * 2, false, stroke..color = c.surfaceHigh);
    final total = values.fold(0.0, (a, v) => a + v);
    if (total <= 0) return;
    var start = -math.pi / 2;
    for (var k = 0; k < values.length; k++) {
      final sweep = math.pi * 2 * values[k] / total * t;
      canvas.drawArc(
        rect,
        start,
        math.max(0, sweep - 0.03),
        false,
        stroke..color = palette[k % palette.length],
      );
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(covariant _DonutPainter old) =>
      old.t != t || old.values != values;
}

/// Horizontal bar list (e.g. top products).
class RankBars extends StatelessWidget {
  final List<(String, double, String)> rows; // label, value, display
  final Color color;
  const RankBars({super.key, required this.rows, required this.color});

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.of(context);
    final maxV = rows.fold(0.0, (a, r) => math.max(a, r.$2));
    return Column(
      children: [
        for (final r in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        r.$1,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: c.text, fontSize: 13),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        r.$3,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.right,
                        style: TextStyle(color: c.textMuted, fontSize: 12),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0, end: maxV == 0 ? 0 : r.$2 / maxV),
                  duration: const Duration(milliseconds: 900),
                  curve: Curves.easeOutCubic,
                  builder:
                      (_, f, __) => ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: LinearProgressIndicator(
                          value: f,
                          minHeight: 7,
                          backgroundColor: c.surfaceHigh,
                          valueColor: AlwaysStoppedAnimation(color),
                        ),
                      ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
