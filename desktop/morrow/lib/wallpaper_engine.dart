import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;

import 'motion.dart';

const backgroundImageExtensions = ['png', 'jpg', 'jpeg', 'webp', 'bmp', 'gif'];

bool isVideoBackground(String file) =>
    path.extension(file).toLowerCase() == '.mp4';

bool isSceneBackground(String file) =>
    path.basename(file).toLowerCase() == 'project.json';

class EngineWallpaper {
  const EngineWallpaper(
    this.title,
    this.id,
    this.type,
    this.file,
    this.preview,
  );

  final String title, id, type, file;
  final String? preview;

  String get formatLabel => switch (type) {
    'video' => '视频壁纸 · 静音循环',
    'scene' => '场景壁纸 · 实时渲染',
    'web' => '网页壁纸 · 使用预览图',
    _ => '壁纸预览图',
  };

  static Future<EngineWallpaper?> read(Directory folder) async {
    try {
      final root = await folder.resolveSymbolicLinks();
      final manifest = File(path.join(root, 'project.json'));
      if (await manifest.length() > 2 * 1024 * 1024) return null;
      if (!path.isWithin(root, await manifest.resolveSymbolicLinks()))
        return null;
      final json = jsonDecode(await manifest.readAsString());
      if (json is! Map<String, dynamic>) return null;

      Future<String?> asset(Object? value, List<String> extensions) async {
        if (value is! String || value.isEmpty || path.isAbsolute(value))
          return null;
        final candidate = path.normalize(path.join(root, value));
        final extension = path.extension(candidate).toLowerCase();
        if (!path.isWithin(root, candidate) ||
            !extensions.any((allowed) => extension == '.$allowed')) {
          return null;
        }
        final file = File(candidate);
        if (!await file.exists()) return null;
        final resolved = await file.resolveSymbolicLinks();
        return path.isWithin(root, resolved) ? resolved : null;
      }

      final type = json['type'] is String ? json['type'] as String : '';
      final id = path.basename(root);
      final title = json['title'] is String
          ? (json['title'] as String).trim()
          : '';
      final preview = await asset(json['preview'], backgroundImageExtensions);
      final video = type == 'video'
          ? await asset(json['file'], const ['mp4'])
          : null;
      final scene =
          type == 'scene' &&
          (await asset(json['file'], const ['json', 'pkg']) != null ||
              await asset('scene.pkg', const ['pkg']) != null);
      final file = scene ? manifest.path : video ?? preview;
      if (file == null) return null;
      return EngineWallpaper(
        title.isEmpty ? id : title,
        id,
        (video == null && type == 'video') || (!scene && type == 'scene')
            ? ''
            : type,
        file,
        preview,
      );
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }
}

Future<Set<String>> _steamLibraries() async {
  if (!Platform.isWindows) return {};
  final env = Platform.environment;
  final steam = <String>{
    if (env['ProgramFiles(x86)'] case final dir?) path.join(dir, 'Steam'),
  };
  try {
    final result = await Process.run(
      path.join(env['SystemRoot'] ?? r'C:\Windows', 'System32', 'reg.exe'),
      ['query', r'HKCU\Software\Valve\Steam', '/v', 'SteamPath'],
    ).timeout(const Duration(seconds: 3));
    final match = RegExp(
      r'^\s*SteamPath\s+REG_SZ\s+(.+)$',
      multiLine: true,
    ).firstMatch(result.stdout.toString());
    if (match != null) steam.add(match[1]!.trim());
  } on Exception {
    // The directory picker remains available when Steam cannot be found.
  }

  final libraries = {...steam};
  for (final root in steam) {
    final file = File(path.join(root, 'steamapps', 'libraryfolders.vdf'));
    try {
      final contents = await file.readAsString();
      for (final match in RegExp(
        r'"path"\s*"((?:\\.|[^"\\])*)"',
      ).allMatches(contents)) {
        libraries.add(match[1]!.replaceAll(r'\\', r'\'));
      }
    } on FileSystemException {
      continue;
    } on FormatException {
      continue;
    }
  }
  return libraries;
}

Future<String?> findWallpaperEngineInstall() async {
  for (final root in await _steamLibraries()) {
    final dir = path.join(root, 'steamapps', 'common', 'wallpaper_engine');
    if (await File(path.join(dir, 'wallpaper64.exe')).exists() ||
        await File(path.join(dir, 'wallpaper32.exe')).exists()) {
      return Directory(dir).resolveSymbolicLinks();
    }
  }
  return null;
}

Future<List<EngineWallpaper>> discoverEngineWallpapers() async {
  final wallpapers = <String, EngineWallpaper>{};
  for (final root in await _steamLibraries()) {
    final steamapps = path.join(root, 'steamapps');
    for (final directory in [
      path.join(steamapps, 'workshop', 'content', '431960'),
      for (final name in ['myprojects', 'defaultprojects'])
        path.join(steamapps, 'common', 'wallpaper_engine', 'projects', name),
    ]) {
      try {
        await for (final entry in Directory(
          directory,
        ).list(followLinks: false)) {
          if (entry is! Directory) continue;
          final wallpaper = await EngineWallpaper.read(entry);
          if (wallpaper != null) {
            wallpapers[wallpaper.file.toLowerCase()] = wallpaper;
          }
        }
      } on FileSystemException {
        continue;
      }
    }
  }
  return wallpapers.values.toList()
    ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
}

Future<EngineWallpaper?> chooseEngineWallpaper(BuildContext context) =>
    showMotionDialog<EngineWallpaper>(
      context: context,
      builder: (_) => const _WallpaperPicker(),
    );

class _WallpaperPicker extends StatefulWidget {
  const _WallpaperPicker();

  @override
  State<_WallpaperPicker> createState() => _WallpaperPickerState();
}

class _WallpaperPickerState extends State<_WallpaperPicker> {
  late final wallpapers = discoverEngineWallpapers();
  String query = '';
  String? folderError;
  bool pickingFolder = false;

  Widget thumbnail(EngineWallpaper wallpaper) {
    final icon = Icon(
      isVideoBackground(wallpaper.file) || isSceneBackground(wallpaper.file)
          ? Icons.movie_outlined
          : Icons.image_outlined,
    );
    final preview = wallpaper.preview;
    if (preview == null) return icon;
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        width: 72,
        height: 44,
        child: TickerMode(
          enabled: false,
          child: Image.file(
            File(preview),
            fit: BoxFit.cover,
            cacheWidth: 144,
            errorBuilder: (_, _, _) => icon,
          ),
        ),
      ),
    );
  }

  Future<void> pickFolder() async {
    setState(() {
      pickingFolder = true;
      folderError = null;
    });
    try {
      final folder = await getDirectoryPath(confirmButtonText: '选择壁纸目录');
      if (folder == null || !mounted) return;
      final wallpaper = await EngineWallpaper.read(Directory(folder));
      if (!mounted) return;
      if (wallpaper != null) {
        Navigator.pop(context, wallpaper);
      } else {
        setState(() => folderError = '请选择包含 project.json 和可用视频或预览图的壁纸目录。');
      }
    } on Exception {
      if (mounted) setState(() => folderError = '无法读取所选壁纸目录。');
    } finally {
      if (mounted) setState(() => pickingFolder = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Wallpaper Engine 壁纸'),
    content: SizedBox(
      width: 560,
      height: 420,
      child: Column(
        children: [
          TextField(
            onChanged: (value) =>
                setState(() => query = value.trim().toLowerCase()),
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: '搜索壁纸名称或创意工坊 ID',
            ),
          ),
          if (folderError case final error?)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                error,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          Expanded(
            child: FutureBuilder<List<EngineWallpaper>>(
              future: wallpapers,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                final entries = snapshot.data ?? const <EngineWallpaper>[];
                if (entries.isEmpty) {
                  return const Center(child: Text('未找到可导入的壁纸。可以手动选择壁纸目录。'));
                }
                final filtered = entries
                    .where(
                      (wallpaper) =>
                          wallpaper.title.toLowerCase().contains(query) ||
                          wallpaper.id.contains(query),
                    )
                    .toList();
                if (filtered.isEmpty)
                  return const Center(child: Text('没有匹配的壁纸。'));
                return ListView.builder(
                  itemCount: filtered.length,
                  itemBuilder: (context, index) {
                    final wallpaper = filtered[index];
                    return ListTile(
                      enabled: !pickingFolder,
                      leading: thumbnail(wallpaper),
                      title: Text(
                        wallpaper.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(wallpaper.formatLabel),
                      onTap: () => Navigator.pop(context, wallpaper),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    ),
    actions: [
      OutlinedButton(
        onPressed: pickingFolder ? null : pickFolder,
        child: const Text('选择壁纸目录'),
      ),
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
    ],
  );
}
