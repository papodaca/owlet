desktop_file = i18n.merge_file(
        input: 'im.apodaca.owlet.desktop.in',
       output: 'im.apodaca.owlet.desktop',
         type: 'desktop',
       po_dir: '../po',
      install: true,
  install_dir: get_option('datadir') / 'applications'
)

desktop_utils = find_program('desktop-file-validate', required: false)
if desktop_utils.found()
  test('Validate desktop file', desktop_utils, args: [desktop_file])
endif

appstream_file = i18n.merge_file(
        input: 'im.apodaca.owlet.metainfo.xml.in',
       output: 'im.apodaca.owlet.metainfo.xml',
       po_dir: '../po',
      install: true,
  install_dir: get_option('datadir') / 'metainfo'
)

appstreamcli = find_program('appstreamcli', required: false, disabler: true)
test('Validate appstream file', appstreamcli,
     args: ['validate', '--no-net', '--explain', appstream_file])

install_data('im.apodaca.owlet.gschema.xml',
  install_dir: get_option('datadir') / 'glib-2.0' / 'schemas'
)

# Copy the schema into the builddir and compile it so uninstalled runs
# (ninja -C build run) can set GSETTINGS_SCHEMA_DIR without a manual
# /tmp/owlet-schemas dance. Install still uses gnome.post_install.
gschema_file = configure_file(
  input: 'im.apodaca.owlet.gschema.xml',
  output: 'im.apodaca.owlet.gschema.xml',
  copy: true,
)

compile_schemas = find_program('glib-compile-schemas', required: true)

gschemas_compiled = custom_target(
  'gschemas-compiled',
  input: gschema_file,
  output: 'gschemas.compiled',
  command: [compile_schemas, meson.current_build_dir()],
  build_by_default: true,
)

# Absolute builddir path consumed by src/meson.build's run_target.
owlet_schema_dir = meson.current_build_dir()

test('Validate schema file',
     compile_schemas,
     args: ['--strict', '--dry-run', meson.current_source_dir()])


service_conf = configuration_data()
service_conf.set('bindir', get_option('prefix') / get_option('bindir'))
configure_file(
  input: 'im.apodaca.owlet.service.in',
  output: 'im.apodaca.owlet.service',
  configuration: service_conf,
  install_dir: get_option('datadir') / 'dbus-1' / 'services'
)

# Phase 5: fallback global-shortcut helper. Installed next to the owlet
# executable so users on portal-less desktops can bind `owlet-signal
# toggle` as a GNOME custom shortcut. The Preferences Shortcuts page
# offers to copy the same script to ~/.local/bin for uninstalled builds.
install_data('owlet-signal.sh',
  install_dir: get_option('bindir'),
  install_mode: 'rwxr-xr-x',
  rename: 'owlet-signal'
)

subdir('icons')
