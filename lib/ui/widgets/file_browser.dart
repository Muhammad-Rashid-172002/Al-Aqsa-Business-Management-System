import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../theme.dart';
import 'forms.dart';

enum BrowseMode { openFile, pickFolder, saveFile }

/// Offline file / folder browser (no plugins). Shows Windows drives
/// (C:, D:, USB drives) or the home folder on macOS/Linux.
Future<String?> browseFiles(
  BuildContext context, {
  required BrowseMode mode,
  String title = 'Choose',
  List<String> extensions = const [],
  String suggestedName = '',
  String? startDir,
}) =>
    showDialog<String>(
      context: context,
      builder: (_) => _FileBrowser(mode: mode, title: title, extensions: extensions.map((e) => e.toLowerCase()).toList(), suggestedName: suggestedName, startDir: startDir),
    );

class _FileBrowser extends StatefulWidget {
  final BrowseMode mode;
  final String title;
  final List<String> extensions;
  final String suggestedName;
  final String? startDir;
  const _FileBrowser({required this.mode, required this.title, required this.extensions, required this.suggestedName, this.startDir});
  @override
  State<_FileBrowser> createState() => _FileBrowserState();
}

class _FileBrowserState extends State<_FileBrowser> {
  String? _dir; // null = roots view
  late final _name = TextEditingController(text: widget.suggestedName);
  String? _error;

  @override
  void initState() {
    super.initState();
    final start = widget.startDir;
    if (start != null && Directory(start).existsSync()) {
      _dir = start;
    } else if (!Platform.isWindows) {
      _dir = Platform.environment['HOME'] ?? '/';
    }
  }

  List<String> _roots() {
    if (Platform.isWindows) {
      return [for (var c = 65; c <= 90; c++) '${String.fromCharCode(c)}:\\'].where((d) => Directory(d).existsSync()).toList();
    }
    final home = Platform.environment['HOME'] ?? '/';
    return [home, if (Directory('/Volumes').existsSync()) '/Volumes', if (Directory('/media').existsSync()) '/media', '/'];
  }

  List<FileSystemEntity> _entries() {
    try {
      final list = Directory(_dir!).listSync(followLinks: false).where((e) => !p.basename(e.path).startsWith('.') && !p.basename(e.path).startsWith(r'$')).toList();
      final dirs = list.whereType<Directory>().toList()..sort((a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));
      final files = widget.mode == BrowseMode.pickFolder
          ? <File>[]
          : (list.whereType<File>().where((f) => widget.extensions.isEmpty || widget.extensions.contains(p.extension(f.path).toLowerCase())).toList()
            ..sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified)));
      _error = null;
      return [...dirs, ...files];
    } catch (e) {
      _error = 'Cannot open this folder.';
      return [];
    }
  }

  void _up() {
    if (_dir == null) return;
    final parent = p.dirname(_dir!);
    setState(() => _dir = parent == _dir ? (Platform.isWindows ? null : _dir) : parent);
  }

  Future<void> _newFolder() async {
    final name = await promptText(context, title: 'New folder', label: 'Folder name');
    if (name == null || _dir == null) return;
    try {
      await Directory(p.join(_dir!, name)).create();
      setState(() {});
    } catch (_) {
      setState(() => _error = 'Could not create folder.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.of(context);
    final roots = _dir == null;
    final entries = roots ? <FileSystemEntity>[] : _entries();
    final screen = MediaQuery.sizeOf(context);
    return Dialog(
      insetPadding: EdgeInsets.symmetric(horizontal: screen.width < 800 ? 12 : 40, vertical: screen.height < 640 ? 12 : 24),
      child: SizedBox(
        width: 720,
        height: (screen.height - 48).clamp(320.0, 600.0),
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 12, 6),
            child: Row(children: [
              Expanded(child: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: c.text))),
              IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(children: [
              IconButton(tooltip: 'Up', onPressed: roots ? null : _up, icon: const Icon(Icons.arrow_upward)),
              IconButton(tooltip: 'Drives', onPressed: () => setState(() => _dir = Platform.isWindows ? null : (Platform.environment['HOME'] ?? '/')), icon: const Icon(Icons.storage)),
              Expanded(child: Text(_dir ?? 'This PC', overflow: TextOverflow.ellipsis, style: TextStyle(color: c.textMuted))),
              if (!roots && widget.mode != BrowseMode.openFile)
                TextButton.icon(onPressed: _newFolder, icon: const Icon(Icons.create_new_folder_outlined, size: 18), label: const Text('New folder')),
            ]),
          ),
          const Divider(height: 1),
          Expanded(
            child: roots
                ? ListView(children: [
                    for (final r in _roots())
                      ListTile(leading: Icon(Icons.storage, color: c.accent), title: Text(r), onTap: () => setState(() => _dir = r)),
                  ])
                : (_error != null
                    ? Center(child: Text(_error!, style: TextStyle(color: c.danger)))
                    : ListView.builder(
                        itemCount: entries.length,
                        itemBuilder: (_, k) {
                          final e = entries[k];
                          final isDir = e is Directory;
                          return ListTile(
                            dense: true,
                            leading: Icon(isDir ? Icons.folder_rounded : Icons.insert_drive_file_outlined, color: isDir ? c.warning : c.textMuted),
                            title: Text(p.basename(e.path), maxLines: 1, overflow: TextOverflow.ellipsis),
                            subtitle: isDir ? null : Text(dateTimeFmt.format((e as File).statSync().modified), style: TextStyle(color: c.textMuted, fontSize: 11)),
                            onTap: () {
                              if (isDir) {
                                setState(() => _dir = e.path);
                              } else if (widget.mode == BrowseMode.openFile) {
                                Navigator.pop(context, e.path);
                              } else if (widget.mode == BrowseMode.saveFile) {
                                setState(() => _name.text = p.basename(e.path));
                              }
                            },
                          );
                        },
                      )),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(14),
            child: Row(children: [
              if (widget.mode == BrowseMode.saveFile)
                Expanded(child: TextField(controller: _name, decoration: const InputDecoration(labelText: 'File name')))
              else
                const Spacer(),
              const SizedBox(width: 12),
              OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
              const SizedBox(width: 10),
              if (widget.mode != BrowseMode.openFile)
                FilledButton(
                  onPressed: roots
                      ? null
                      : () {
                          if (widget.mode == BrowseMode.pickFolder) {
                            Navigator.pop(context, _dir);
                          } else {
                            final n = _name.text.trim();
                            if (n.isEmpty) return;
                            Navigator.pop(context, p.join(_dir!, n));
                          }
                        },
                  child: Text(widget.mode == BrowseMode.pickFolder ? 'Use this folder' : 'Save here'),
                ),
            ]),
          ),
        ]),
      ),
    );
  }
}
