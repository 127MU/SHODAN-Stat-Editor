import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:shodan_desktop/wallpaper_engine.dart';

void main() {
  late Directory root;
  late Directory project;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('shodan-wallpaper-');
    project = await Directory(path.join(root.path, '431960123')).create();
  });
  tearDown(() => root.delete(recursive: true));

  Future<EngineWallpaper?> read(Map<String, String> manifest) async {
    await File(
      path.join(project.path, 'project.json'),
    ).writeAsString(jsonEncode(manifest));
    return EngineWallpaper.read(project);
  }

  test('video projects prefer the local MP4 and keep their preview', () async {
    await File(path.join(project.path, '星空.MP4')).create();
    await File(path.join(project.path, 'preview.jpg')).create();
    final wallpaper = (await read({
      'title': '星空',
      'type': 'video',
      'file': '星空.MP4',
      'preview': 'preview.jpg',
    }))!;
    expect(wallpaper.title, '星空');
    expect(wallpaper.id, '431960123');
    expect(isVideoBackground(wallpaper.file), isTrue);
    expect(path.basename(wallpaper.preview!), 'preview.jpg');
  });

  test('packed scenes are opened as projects and retain the poster', () async {
    await File(path.join(project.path, 'scene.pkg')).create();
    final manifest = {'type': 'scene', 'file': 'scene.json'};
    final scene = (await read(manifest))!;
    expect(isSceneBackground(scene.file), isTrue);
    expect(scene.preview, isNull);
    await File(path.join(project.path, 'preview.gif')).create();
    final withPreview = (await read({...manifest, 'preview': 'preview.gif'}))!;
    expect(isSceneBackground(withPreview.file), isTrue);
    expect(path.basename(withPreview.preview!), 'preview.gif');
  });

  test(
    'web projects use their preview rather than their entry point',
    () async {
      await File(path.join(project.path, 'preview.gif')).create();
      final wallpaper = (await read({
        'type': 'web',
        'file': 'index.html',
        'preview': 'preview.gif',
      }))!;
      expect(path.basename(wallpaper.file), 'preview.gif');
      expect(wallpaper.type, 'web');
    },
  );

  test(
    'rejects outside assets and uses a valid preview if the video is missing',
    () async {
      final outside = await File(path.join(root.path, 'outside.mp4')).create();
      final manifest = {'type': 'video', 'file': '../outside.mp4'};
      expect(await read(manifest), isNull);
      expect(await read({...manifest, 'file': outside.path}), isNull);
      await File(path.join(project.path, 'preview.png')).create();
      final wallpaper = (await read({...manifest, 'preview': 'preview.png'}))!;
      expect(isVideoBackground(wallpaper.file), isFalse);
    },
  );
}
