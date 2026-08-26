# CLI helpers that exercise Vala libsoup paths without launching the GTK app.
src_dir = meson.project_source_root() / 'src'

download_cli = executable(
  'owlet-download-cli',
  files('download_cli.vala', src_dir / 'services' / 'model-downloader.vala'),
  dependencies: [
    dependency('glib-2.0'),
    dependency('gobject-2.0'),
    dependency('gio-2.0'),
    dependency('libsoup-3.0'),
  ],
  install: false,
)

document_cli = executable(
  'owlet-document-cli',
  files(
    'document_cli.vala',
    src_dir / 'services' / 'document.vala',
    src_dir / 'services' / 'word-spans.vala',
  ),
  dependencies: [
    dependency('glib-2.0'),
    dependency('gobject-2.0'),
    dependency('gio-2.0'),
  ],
  install: false,
)

engine_cli = executable(
  'owlet-engine-cli',
  files('engine_cli.vala'),
  dependencies: [
    dependency('glib-2.0'),
    dependency('gobject-2.0'),
    dependency('gio-2.0'),
    tts_dep,
    valac.find_library('tts', dirs: src_dir / 'vapi'),
  ],
  install: false,
)

voice_cli = executable(
  'owlet-voice-cli',
  files(
    'voice_cli.vala',
    src_dir / 'services' / 'model-downloader.vala',
    src_dir / 'services' / 'voice-models.vala',
  ),
  dependencies: [
    dependency('glib-2.0'),
    dependency('gobject-2.0'),
    dependency('gio-2.0'),
    dependency('libsoup-3.0'),
    dependency('libarchive'),
  ],
  install: false,
)

tts_cli = executable(
  'owlet-tts-cli',
  files(
    'tts_cli.vala',
    src_dir / 'services' / 'document.vala',
    src_dir / 'services' / 'speech-player.vala',
    src_dir / 'services' / 'word-spans.vala',
  ),
  dependencies: [
    dependency('glib-2.0'),
    dependency('gobject-2.0'),
    dependency('gio-2.0'),
    dependency('gstreamer-1.0'),
    dependency('gstreamer-base-1.0'),
    dependency('gstreamer-app-1.0'),
    dependency('gstreamer-audio-1.0'),
    tts_dep,
    valac.find_library('tts', dirs: src_dir / 'vapi'),
  ],
  install: false,
)

remote_cli = executable(
  'owlet-remote-cli',
  files(
    'remote_cli.vala',
    src_dir / 'services' / 'transcription-source.vala',
    src_dir / 'services' / 'remote-openai-source.vala',
  ),
  dependencies: [
    dependency('glib-2.0'),
    dependency('gobject-2.0'),
    dependency('gio-2.0'),
    dependency('libsoup-3.0'),
    dependency('json-glib-1.0'),
  ],
  install: false,
)
