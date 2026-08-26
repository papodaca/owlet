subdir('helpers')

# Prefer a local tests/.venv when it is runnable on this host (see
# tests/README.md). A bind-mounted foreign venv (e.g. Arch paths inside
# an Ubuntu packaging container) fails its shebang — fall back to PATH
# pytest in that case (python3-pytest Build-Depends).
fs = import('fs')
venv_pytest = meson.current_source_dir() / '.venv' / 'bin' / 'pytest'
pytest_dirs = []
if fs.exists(venv_pytest)
  # Probe via sh so a foreign shebang (ENOENT interpreter) is a normal
  # non-zero exit under check: false, not a Meson hard error.
  venv_probe = run_command(
    'sh', '-c', '"$@" --version >/dev/null 2>&1',
    'pytest-probe',
    venv_pytest,
    check: false,
  )
  if venv_probe.returncode() == 0
    pytest_dirs += [meson.current_source_dir() / '.venv' / 'bin']
  else
    message('tests/.venv pytest is not runnable here; using system pytest')
  endif
endif

pytest = find_program(
  'pytest',
  dirs: pytest_dirs,
  required: false,
  disabler: true,
)

tests_dir = meson.current_source_dir()

test_env = environment()
test_env.set('OWLET_BIN', owlet.full_path())
test_env.set('OWLET_SOURCE_ROOT', meson.project_source_root())
test_env.set('OWLET_DOWNLOAD_CLI', download_cli.full_path())
test_env.set('OWLET_DOCUMENT_CLI', document_cli.full_path())
test_env.set('OWLET_ENGINE_CLI', engine_cli.full_path())
test_env.set('OWLET_VOICE_CLI', voice_cli.full_path())
test_env.set('OWLET_TTS_CLI', tts_cli.full_path())
test_env.set('OWLET_REMOTE_CLI', remote_cli.full_path())
# Only prepend the venv when we accepted it above; a broken foreign
# venv on PATH would shadow system pytest at test runtime too.
if pytest_dirs.length() > 0
  test_env.prepend('PATH', meson.current_source_dir() / '.venv' / 'bin')
endif

pytest_args = ['-q', '--tb=short']

test('pytest-unit', pytest,
  args: pytest_args + [tests_dir / 'unit'],
  env: test_env,
  suite: 'unit',
  workdir: meson.project_source_root(),
  depends: [owlet, document_cli, engine_cli],
)

test('pytest-integration', pytest,
  args: pytest_args + [tests_dir / 'integration'],
  env: test_env,
  suite: 'integration',
  workdir: meson.project_source_root(),
  depends: [owlet, download_cli, voice_cli, remote_cli],
  is_parallel: false,
  timeout: 120,
)

test('pytest-ui', pytest,
  args: pytest_args + ['-m', 'ui', tests_dir / 'ui'],
  env: test_env,
  suite: 'ui',
  workdir: meson.project_source_root(),
  depends: [owlet],
  is_parallel: false,
  timeout: 180,
)

test('pytest-network', pytest,
  args: pytest_args + ['-m', 'network', tests_dir / 'network'],
  env: test_env,
  suite: 'network',
  workdir: meson.project_source_root(),
  depends: [owlet, tts_cli],
  # Buffers now carry PTS, so fakesink's sync=true finally paces the
  # play-family fixtures in real time instead of draining at synthesis
  # speed. The suite is dominated by that playback wall clock.
  timeout: 900,
)
