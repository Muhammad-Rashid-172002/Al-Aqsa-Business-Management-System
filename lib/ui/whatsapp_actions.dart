// WhatsApp buttons for customers: open the customer's chat with a message
// pre-filled. Nothing is sent automatically; the user presses Send in
// WhatsApp.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/models/party.dart';
import '../domain/services/whatsapp.dart';
import 'providers.dart';
import 'theme.dart';
import 'widgets/common.dart';
import 'widgets/forms.dart';

/// WhatsApp brand green.
const whatsAppGreen = Color(0xFF25D366);

/// Opens a URL with the operating system's handler. Replaceable in tests.
typedef UrlOpener = Future<bool> Function(Uri uri);

/// Default opener. Windows: url.dll's FileProtocolHandler (handles "&" in
/// the URL without shell quoting); macOS: open; Linux: xdg-open.
Future<bool> systemOpenUrl(Uri uri) async {
  try {
    final r = Platform.isWindows
        ? await Process.run('rundll32', ['url.dll,FileProtocolHandler', uri.toString()])
        : await Process.run(Platform.isMacOS ? 'open' : 'xdg-open', [uri.toString()]);
    return r.exitCode == 0;
  } catch (_) {
    return false;
  }
}

/// True when WhatsApp Desktop is installed (it registers the whatsapp:
/// protocol). Replaceable in tests.
typedef DesktopCheck = Future<bool> Function();

bool? _desktopCache;
Future<bool> systemHasWhatsAppDesktop() async {
  if (_desktopCache != null) return _desktopCache!;
  var found = false;
  try {
    if (Platform.isWindows) {
      final r = await Process.run('reg', ['query', r'HKCR\whatsapp', '/ve']);
      found = r.exitCode == 0;
    } else if (Platform.isMacOS) {
      found = Directory('/Applications/WhatsApp.app').existsSync();
    }
  } catch (_) {}
  return _desktopCache = found;
}

UrlOpener whatsAppUrlOpener = systemOpenUrl;
DesktopCheck whatsAppDesktopCheck = systemHasWhatsAppDesktop;

/// Opens the chat with [number] (already normalised) and [message]
/// pre-filled: WhatsApp Desktop when installed, otherwise wa.me in the
/// browser (which offers WhatsApp Desktop or WhatsApp Web). Returns the URL
/// that was opened, or null if nothing could be opened.
Future<Uri?> openWhatsAppChat(String number, String message) async {
  if (await whatsAppDesktopCheck()) {
    final app = whatsAppAppLink(number, message);
    if (await whatsAppUrlOpener(app)) return app;
  }
  final web = whatsAppWebLink(number, message);
  return await whatsAppUrlOpener(web) ? web : null;
}

void _noNumber(BuildContext context, Party p) => showToast(
      context,
      '${p.name} has no valid mobile number. Use Edit to add one, e.g. 03001234567 or +923001234567.',
      error: true,
    );

Future<void> _open(BuildContext context, String number, String message) async {
  final opened = await openWhatsAppChat(number, message);
  if (!context.mounted) return;
  if (opened == null) {
    await Clipboard.setData(ClipboardData(text: whatsAppWebLink(number, message).toString()));
    if (context.mounted) showToast(context, 'Could not open WhatsApp. The chat link was copied; paste it into your browser.', error: true);
  } else {
    showToast(context, 'Opening WhatsApp chat with ${displayWhatsAppNumber(number)}. Review the message and press Send.');
  }
}

/// Table button: opens the customer's chat straight away with the general
/// greeting pre-filled (editable in WhatsApp before sending).
Future<void> quickWhatsApp(BuildContext context, WidgetRef ref, Party p) async {
  final nums = whatsAppNumbersOf(p);
  if (nums.isEmpty) return _noNumber(context, p);
  final app = ref.read(servicesProvider);
  await _open(context, nums.first, waMessage(WaTemplate.general, waContextFor(app, p)));
}

/// Small green WhatsApp-style icon (chat bubble on a green circle).
class WhatsAppIcon extends StatelessWidget {
  final double size;
  final bool enabled;
  const WhatsAppIcon({super.key, this.size = 22, this.enabled = true});
  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: enabled ? whatsAppGreen : AppTheme.of(context).textMuted.withValues(alpha: 0.45), shape: BoxShape.circle),
        child: Icon(Icons.chat_rounded, color: Colors.white, size: size * 0.58),
      );
}

/// The small WhatsApp button used in the customers table.
class WhatsAppButton extends ConsumerWidget {
  final Party party;
  const WhatsAppButton({super.key, required this.party});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ok = whatsAppNumbersOf(party).isNotEmpty;
    return IconButton(
      key: ValueKey('wa-${party.id}'),
      tooltip: ok ? 'WhatsApp ${party.name}' : 'No valid mobile number for WhatsApp',
      visualDensity: VisualDensity.compact,
      icon: WhatsAppIcon(enabled: ok),
      onPressed: () => quickWhatsApp(context, ref, party),
    );
  }
}

/// Customer details: pick a number and a template, edit the text, then open
/// WhatsApp with it pre-filled.
Future<void> showWhatsAppComposer(BuildContext context, WidgetRef ref, Party p, {WaTemplate initial = WaTemplate.general}) async {
  final nums = whatsAppNumbersOf(p);
  if (nums.isEmpty) return _noNumber(context, p);
  final x = waContextFor(ref.read(servicesProvider), p);
  var template = waTemplateUnavailable(initial, x) == null ? initial : WaTemplate.general;
  var number = nums.first;
  final text = TextEditingController(text: waMessage(template, x));
  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(builder: (ctx, setS) {
      final c = AppTheme.of(ctx);
      return AlertDialog(
        key: const ValueKey('wa-composer'),
        scrollable: true,
        title: Row(children: [const WhatsAppIcon(size: 26), const SizedBox(width: 10), Expanded(child: Text('WhatsApp ${p.name}', overflow: TextOverflow.ellipsis))]),
        content: SizedBox(
          width: 520,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (nums.length > 1)
              AppDropdown<String>(
                key: const ValueKey('wa-number'),
                value: number,
                decoration: const InputDecoration(labelText: 'Number'),
                items: [for (final n in nums) DropdownMenuItem(value: n, child: Text(displayWhatsAppNumber(n)))],
                onChanged: (v) => setS(() => number = v ?? number),
              )
            else
              Text('To: ${displayWhatsAppNumber(number)}', style: TextStyle(color: c.textMuted)),
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final t in WaTemplate.values)
                Tooltip(
                  message: waTemplateUnavailable(t, x) ?? '',
                  child: ChoiceChip(
                    key: ValueKey('wa-t-${t.name}'),
                    label: Text(t.label),
                    selected: template == t,
                    onSelected: waTemplateUnavailable(t, x) != null
                        ? null
                        : (_) => setS(() {
                              template = t;
                              text.text = waMessage(t, x);
                            }),
                  ),
                ),
            ]),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('wa-message'),
              controller: text,
              minLines: 5,
              maxLines: 12,
              decoration: const InputDecoration(labelText: 'Message (edit before opening WhatsApp)', alignLabelWithHint: true),
            ),
            const SizedBox(height: 8),
            Text('WhatsApp opens with this text filled in. Nothing is sent until you press Send in WhatsApp.', style: TextStyle(color: c.textMuted, fontSize: 12)),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton.icon(
            key: const ValueKey('wa-open'),
            style: FilledButton.styleFrom(backgroundColor: whatsAppGreen, foregroundColor: Colors.white),
            onPressed: () async {
              final msg = text.text;
              Navigator.pop(ctx);
              await _open(context, number, msg);
            },
            icon: const Icon(Icons.open_in_new, size: 18),
            label: const Text('Open in WhatsApp'),
          ),
        ],
      );
    }),
  );
}
