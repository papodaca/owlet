# Point valac at the hand-written VAPIs in src/vapi/ (transcribe + libei).
add_project_arguments(['--vapidir', meson.current_source_dir() / 'vapi'],
                        language: 'vala')

# Posix namespace (Signal.USR1/USR2, getpid, chmod) used by the Phase 5
# global-shortcut fallback. The posix.vapi ships with valac and is on
# its default search path, so no --vapidir is needed.
add_project_arguments(['--pkg', 'posix'], language: 'vala')

# When libei-1.0 was detected by the top-level meson.build, expose the
# HAVE_LIBEI Vala preprocessor symbol so the libei backend in
# keystroke.vala compiles in. The VAPI and C shim are only linked when
# libei is available; without this gate the Vala references would
# otherwise fail to resolve at link time.
if have_libei
  add_project_arguments(['-D', 'HAVE_LIBEI'], language: 'vala')
endif

owlet_sources = [
  'main.vala',
  'application.vala',
  'window.vala',
  'services/recorder.vala',
  'services/transcription-source.vala',
  'services/local-source.vala',
  'services/remote-openai-source.vala',
  'services/keystroke.vala',
  'services/model-downloader.vala',
  'services/secret-store.vala',
  'services/global-shortcuts.vala',
  'services/sound-feedback.vala',
  'services/silence-detector.vala',
  'services/tray.vala',
  'services/dictation-hud.vala',
  'ui/preferences.vala',
  # Phase 5: portable SIGRTMIN (glibc exposes it as a function-based
  # macro, musl as a constant; posix.vapi has no binding).
  'vapi/signal-shim.c',
]

# Phase 13: in-process X11/XWayland override-redirect dictation OSD
# (Shape click-through + ARGB colormap). Built as a C static library so
# x11/xext/cairo-xlib never become `--pkg` arguments to valac — there is
# no system xext.vapi / cairo-xlib.vapi. Vala only consumes the hand-
# written dictation-hud-shim.vapi below.
dictation_hud_shim = static_library('dictation-hud-shim',
  'vapi/dictation-hud-shim.c',
  dependencies: [
    dependency('glib-2.0'),
    dependency('x11'),
    dependency('xext'),
    dependency('xrandr'),
    dependency('pangocairo'),
    dependency('cairo-xlib'),
  ],
  include_directories: include_directories('vapi'),
)

owlet_deps = [
  config_dep,
  dependency('gtk4'),
  dependency('libadwaita-1', version: '>= 1.8'),
  transcribe_dep,
  valac.find_library('transcribe', dirs: meson.current_source_dir() / 'vapi'),
  dependency('gstreamer-1.0'),
  dependency('gstreamer-base-1.0'),
  dependency('gstreamer-app-1.0'),
  dependency('gstreamer-audio-1.0'),
  # Phase 4: model downloader (libsoup-3.0) + API key storage (libsecret-1).
  dependency('libsoup-3.0'),
  dependency('libsecret-1'),
  # Phase 6: JSON parsing for the OpenAI-compatible /v1/audio/transcriptions
  # response ({"text": "..."} for json / verbose_json).
  dependency('json-glib-1.0'),
  # Phase 13: Vala bindings only (C X11 deps stay on the static lib above).
  valac.find_library('dictation-hud-shim',
                      dirs: meson.current_source_dir () / 'vapi'),
]

# Optional libei-1.0 backend (dictation mode keystroke injection).
# The pkg-config dep adds `--pkg libei-1.0` to the vala command, which
# resolves to our hand-written src/vapi/libei-1.0.vapi (libei ships no
# upstream VAPI). The C shim wraps the sentinel-terminated variadic
# ei_seat_bind_capabilities call.
if have_libei
  owlet_deps += [ libei_dep ]
  owlet_sources += 'vapi/libei-shim.c'
endif

owlet_sources += gnome.compile_resources('owlet-resources',
  'owlet.gresource.xml',
  c_name: 'owlet'
)

# Include src/vapi/ so the C compiled from keystroke.vala finds
# libei-shim.h (referenced by the VAPI's cheader_filename for the
# Seat shim methods), and so the signal-shim.h prototype is visible to
# application.vala's generated C for the SIGRTMIN call.
owlet_inc = [ config_inc, include_directories('vapi') ]

# Assigned so tests/meson.build can depend on the binary and pass
# OWLET_BIN via owlet.full_path().
owlet = executable('owlet', owlet_sources,
  dependencies: owlet_deps,
  include_directories: owlet_inc,
  link_with: dictation_hud_shim,
       install: true,
)

# Day-to-day uninstalled launch: builds the binary + schemas, then runs
# with GSETTINGS_SCHEMA_DIR pointed at build/data/.
# Usage: ninja -C build run
run_target('run',
  command: [owlet],
  depends: [gschemas_compiled],
  env: {'GSETTINGS_SCHEMA_DIR': owlet_schema_dir},
)