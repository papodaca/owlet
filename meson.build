project('owlet', ['c', 'vala'],
          version: '0.5.0',
    meson_version: '>= 1.0.0',
  default_options: [ 'warning_level=2', 'werror=false', ],
)

# C++ is required to link the transcribe.cpp static lib (C++17). Use
# required: false so the error message names the missing toolchain
# only when the transcribe subproject is actually built.
add_languages('cpp', required: false)

i18n = import('i18n')
gnome = import('gnome')
valac = meson.get_compiler('vala')
cc    = meson.get_compiler('c')

# About / Config.PACKAGE_VERSION. Same rule as packaging/: an exact
# vX.Y.Z tag on HEAD wins; otherwise the project() version above.
# project() must stay a literal (it is meson's first statement), so
# this lookup runs afterward. Reconfigure after tagging.
package_version = meson.project_version()
git_prog = find_program('git', required: false)
if git_prog.found()
  git_describe = run_command(
    git_prog, '-C', meson.project_source_root(),
    'describe', '--tags', '--exact-match', 'HEAD',
    check: false,
  )
  if git_describe.returncode() == 0
    tag = git_describe.stdout().strip()
    if tag.startswith('v')
      package_version = tag.substring(1)
    elif tag != ''
      package_version = tag
    endif
  endif
endif
message('Owlet version: ' + package_version)

srcdir = meson.project_source_root() / 'src'

config_h = configuration_data()
config_h.set_quoted('PACKAGE_VERSION', package_version)
config_h.set_quoted('GETTEXT_PACKAGE', 'owlet')
config_h.set_quoted('LOCALEDIR', get_option('prefix') / get_option('localedir'))
# GPU_BACKEND is filled in below, after the auto-detect block has
# finalised the resolved backend. Config.vapi exposes it read-only.
# The configure_file() call that writes config.h is deferred until
# after GPU_BACKEND is set, so the emitted header reflects the
# resolved backend.

config_dep = valac.find_library ('config', dirs: srcdir)
config_inc = include_directories('.')

add_project_arguments('-DGETTEXT_PACKAGE="' + meson.project_name () + '"', language: 'c')

# --------------------------------------------------------------------------- #
# Optional libei-1.0 dependency for keystroke injection (dictation mode).    #
# Owlet's libei path needs EI_DEVICE_CAP_TEXT / ei_device_text_utf8* (libei   #
# ≥ 1.6). Older distro libei (e.g. 1.5 on Ubuntu 26.04 / Debian sid) is       #
# treated as unavailable so the build still succeeds and dictation falls      #
# back to ydotool / xdotool.                                                  #
# --------------------------------------------------------------------------- #
libei_dep = dependency('libei-1.0', required: false)
have_libei = false
if libei_dep.found()
  if cc.has_header_symbol('libei.h', 'EI_DEVICE_CAP_TEXT',
                          dependencies: libei_dep)
    have_libei = true
    message('libei-1.0 with TEXT (≥ 1.6): enabling libei keystroke backend')
  else
    message('libei-1.0 found but lacks EI_DEVICE_CAP_TEXT (< 1.6): dictation will use ydotool/xdotool')
  endif
else
  message('libei-1.0 not found: dictation will use ydotool/xdotool')
endif

# --------------------------------------------------------------------------- #
# transcribe.cpp sidecar build                                                #
# --------------------------------------------------------------------------- #
#
# We invoke transcribe.cpp's CMake build directly rather than via
# meson's cmake.subproject() wrapper. As of meson 1.11.2 the wrapper
# has two gaps that block GPU backends:
#   - Vulkan: mishandles $<CONFIG> in ExternalProject_Add BUILD_COMMAND
#     (cmake receives `--config ';;;'` from meson's `;;;` subcommand sep).
#   - HIP: doesn't model the HIP language; sees .cu sources and demands nvcc.
# A direct cmake invocation sidesteps both. The custom_target below runs
# `cmake -S ... -B ...` then `cmake --build --target transcribe`; the
# resulting static archives are wrapped in a declare_dependency and
# consumed by src/meson.build like any other dep.

gpu_backend = get_option('gpu_backend')

transcribe_dir = get_option('transcribe_dir')
if transcribe_dir == ''
  transcribe_src = meson.project_source_root() / 'subprojects' / 'transcribe.cpp'
  transcribe_inc = include_directories('subprojects' / 'transcribe.cpp' / 'include')
  transcribe_include_args = []
else
  transcribe_src = transcribe_dir
  transcribe_inc = []
  transcribe_include_args = ['-I' + (transcribe_src / 'include')]
endif
transcribe_builddir = meson.current_build_dir() / 'subprojects' / 'transcribe.cpp'

# CMake args common to all backends. We only build the `transcribe` target
# (libtranscribe.a + the ggml archives the selected backend pulls in); the
# standalone CLI, tests, tools, and install rules are all OFF.
cmake_args = [
  '-S', transcribe_src,
  '-B', transcribe_builddir,
  '-DCMAKE_BUILD_TYPE=Release',
  # Static ggml/transcribe archives are linked into the PIE owlet
  # binary (Debian hardening=+all; also typical on Arch). Without PIC,
  # HIP objects in particular fail at final link with R_X86_64_32
  # relocations — CMAKE_HIP_FLAGS does not inherit dpkg CXXFLAGS.
  # Typed BOOL so enable_language(HIP) cannot treat this as UNINITIALIZED
  # and drop it from the cache.
  '-DCMAKE_POSITION_INDEPENDENT_CODE:BOOL=ON',
  '-DTRANSCRIBE_BUILD_SHARED=OFF',
  '-DTRANSCRIBE_BUILD_TESTS=OFF',
  '-DTRANSCRIBE_BUILD_EXAMPLES=OFF',
  '-DTRANSCRIBE_BUILD_TOOLS=OFF',
  '-DTRANSCRIBE_INSTALL=OFF',
]

# Public defines propagated to owlet's C compile so transcribe.h sees the
# static-contract decoration. Backend-specific GGML_USE_* are also added
# so any GGML headers owlet touches pick the right backend guards.
transcribe_compile_defs = ['-DTRANSCRIBE_STATIC']
extra_archives = []           # backend-specific ggml archive, appended to link_args
path_prefix = ''              # HIP prepends /opt/rocm/bin here; empty for others
transcribe_link_libs = []     # backend-specific + math/cblas/stdc++ libs

# Math, C++ stdlib, and BLAS libs needed at the final link step. Found
# here (before the backend switch) so the HIP branch below can append
# the HIP runtime to the same list.
cblas_lib  = cc.find_library('cblas',  required: false)
blas_lib   = cc.find_library('blas',   required: false)
m_lib      = cc.find_library('m',      required: false)
stdcpp_lib = cc.find_library('stdc++', required: false)
if cblas_lib.found()
  transcribe_link_libs += cblas_lib
endif
if blas_lib.found()
  transcribe_link_libs += blas_lib
endif
if m_lib.found()
  transcribe_link_libs += m_lib
endif
if stdcpp_lib.found()
  transcribe_link_libs += stdcpp_lib
endif

rocminfo  = find_program('rocminfo',  required: false)
hipcc     = find_program('hipcc',     required: false)
hipconfig = find_program('hipconfig', required: false)

if gpu_backend == 'auto'
  if hipcc.found() and hipconfig.found()
    gpu_backend = 'hip'
  elif dependency('vulkan', required: false).found()
    gpu_backend = 'vulkan'
  else
    gpu_backend = 'cpu'
  endif
  message('Auto-detected GPU backend: @0@'.format(gpu_backend))
endif

# Now that gpu_backend is resolved (auto-detect ran above), expose it
# via Config.GPU_BACKEND for runtime read-only access from Vala.
config_h.set_quoted('GPU_BACKEND', gpu_backend)
configure_file(output: 'config.h', configuration: config_h)

if gpu_backend == 'hip'
  amd_targets = get_option('amd_targets')
  if amd_targets == ''
    if not rocminfo.found()
      error('gpu_backend=hip requires rocminfo to autodetect AMD target. Install rocminfo or pass -Damd_targets=gfxXXXX.')
    endif
    r = run_command(rocminfo, '--show-product-name', check: true)
    foreach line : r.stdout().split('\n')
      if line.contains('gfx')
        amd_targets = line.strip().split(' ')[-1]
        break
      endif
    endforeach
    if amd_targets == ''
      error('Could not autodetect AMD GPU target. Pass -Damd_targets=gfxXXXX.')
    endif
    message('Auto-detected AMD target: @0@'.format(amd_targets))
  endif
  cmake_amd_targets = '\'' + amd_targets + '\''
  cmake_args += [
    '-DTRANSCRIBE_HIP=ON',
    '-DAMDGPU_TARGETS=' + cmake_amd_targets,
    '-DCMAKE_HIP_ARCHITECTURES=' + cmake_amd_targets,
    # HIP language flags are separate from CXXFLAGS; force -fPIC so
    # libggml-hip.a can link into a PIE owlet (see POSITION_INDEPENDENT
    # note on cmake_args above). FLAGS_INIT seeds enable_language(HIP);
    # typed STRING CMAKE_HIP_FLAGS keeps -fPIC if the language module
    # would otherwise reset an UNINITIALIZED -D value to empty.
    '-DCMAKE_HIP_FLAGS_INIT=-fPIC',
    '-DCMAKE_HIP_FLAGS:STRING=-fPIC',
  ]
  # CMake's enable_language(HIP) needs to find hipcc and clang on PATH
  # (CMAKE_HIP_COMPILER rejects the hipcc wrapper — it wants clang
  # directly). On Arch, /opt/rocm/bin is not on PATH by default even
  # when hip-runtime-amd is installed. We prepend it to PATH for the
  # sidecar subprocess only, leaving the user's session alone.
  if hipcc.found()
    rocm_bindir = hipcc.path().split('/hipcc')[0]
    path_prefix = 'PATH=' + rocm_bindir + ':$PATH '
  else
    path_prefix = ''
  endif
  transcribe_compile_defs += ['-DGGML_USE_HIP', '-DGGML_USE_CUDA']
  extra_archives += transcribe_builddir / 'ggml' / 'src' / 'ggml-hip' / 'libggml-hip.a'
  # HIP runtime + ROCm math libs: libggml-hip.a calls hipGetLastError,
  # hipMalloc (amdhip64), hipblasGemmEx (hipblas → rocblas), and the
  # ROCm collectives (rccl) for multi-GPU. No pkg-config; find the
  # shared libs in /opt/rocm/lib (or wherever hipcc was found).
  rocm_libdir = hipcc.path().split('/bin/hipcc')[0] / 'lib'
  foreach rocm_lib : ['amdhip64', 'hipblas', 'rocblas', 'rccl']
    rocm_dep = cc.find_library(rocm_lib, dirs: rocm_libdir, required: false)
    if rocm_dep.found()
      transcribe_link_libs += rocm_dep
    endif
  endforeach
elif gpu_backend == 'vulkan'
  cmake_args += ['-DTRANSCRIBE_VULKAN=ON']
  transcribe_compile_defs += ['-DGGML_USE_VULKAN']
  extra_archives += transcribe_builddir / 'ggml' / 'src' / 'ggml-vulkan' / 'libggml-vulkan.a'
elif gpu_backend == 'cpu'
  transcribe_compile_defs += ['-DGGML_USE_CPU']
else
  error('Unknown GPU backend: @0@'.format(gpu_backend))
endif

# The custom_target produces a stamp file as its meson-visible output;
# the real archives are side-effects at the known paths below. The
# stamp is added to transcribe_dep via `sources:` so any consumer of
# transcribe_dep builds the archives first. `cmake --build --target
# transcribe` is itself incremental, so re-running ninja is cheap when
# nothing changed.
#
# cmake --parallel with no count uses nproc. On GitHub's 4-core / 16 GiB
# runners that OOMs (exit 137) while compiling sherpa-onnx-core at -O3;
# docker-in-docker for release.yml is tighter still. CMAKE_BUILD_PARALLEL_LEVEL
# wins when set (CI sets 2). Otherwise cap by MemAvailable at ~4 GiB per
# compiler so a local machine still uses the cores it can feed.
sidecar_pick_jobs = '''
ncpu=$(nproc)
mem_kb=$(awk '/MemAvailable:/ {print $2; exit}' /proc/meminfo 2>/dev/null || echo 0)
if [ -n "${CMAKE_BUILD_PARALLEL_LEVEL:-}" ]; then
  jobs=$CMAKE_BUILD_PARALLEL_LEVEL
else
  if [ "$mem_kb" -gt 0 ]; then
    jobs=$((mem_kb / 4194304))
  else
    jobs=$ncpu
  fi
  [ "$jobs" -lt 1 ] && jobs=1
  [ "$jobs" -gt "$ncpu" ] && jobs=$ncpu
fi
echo "sidecar cmake --parallel $jobs (nproc=$ncpu MemAvailable_kB=${mem_kb:-unknown} CMAKE_BUILD_PARALLEL_LEVEL=${CMAKE_BUILD_PARALLEL_LEVEL:-unset})"
'''
configure_cmd = ' '.join(['cmake'] + cmake_args)
build_cmd     = 'cmake --build ' + transcribe_builddir + ' --target transcribe --parallel "$jobs"'
touch_cmd     = ' '.join(['cmake', '-E', 'touch', '@OUTPUT@'])
# path_prefix is empty for non-HIP backends; HIP prepends /opt/rocm/bin
# (or wherever hipcc was found) to PATH so cmake's enable_language(HIP)
# can locate hipcc + clang without polluting the user's session.
sidecar_script = sidecar_pick_jobs + path_prefix + configure_cmd + ' && ' + build_cmd + ' && ' + touch_cmd

transcribe_build = custom_target(
  'transcribe-build',
  output: 'owlet-transcribe-stamp',
  command: [find_program('sh'), '-c', sidecar_script],
  build_by_default: true,
  console: true,
)

# Absolute paths to the archives cmake writes into transcribe_builddir.
libtranscribe_a = transcribe_builddir / 'src'        / 'libtranscribe.a'
libggml_a        = transcribe_builddir / 'ggml' / 'src' / 'libggml.a'
libggml_base_a   = transcribe_builddir / 'ggml' / 'src' / 'libggml-base.a'
libggml_cpu_a    = transcribe_builddir / 'ggml' / 'src' / 'libggml-cpu.a'

transcribe_dep = declare_dependency(
  sources: transcribe_build,
  include_directories: transcribe_inc,
  compile_args: transcribe_compile_defs + transcribe_include_args,
  link_args: [libtranscribe_a, libggml_a, libggml_base_a, libggml_cpu_a] + extra_archives,
  dependencies: transcribe_link_libs,
)

# --------------------------------------------------------------------------- #
# sherpa-onnx sidecar build                                                   #
# --------------------------------------------------------------------------- #
#
# Like transcribe.cpp, we drive sherpa-onnx's CMake build directly via
# custom_target + declare_dependency.
#
# Pinned to v1.13.6. At configure time, upstream's cmake FetchContent
# pulls the archives listed in packaging/sherpa-onnx-archives.sh (URLs
# + sha256 + local-file fallback names). U6 seeds CMAKE_BINARY_DIR so
# Arch/Debian/AppImage builds resolve them without a network fetch:
#   - onnxruntime-linux-{x64,aarch64}-static_lib-1.27.1-glibc2_17.zip
#   - espeak-ng-ed530aa113046142eb5115cf2fc9157854d0ffe1.zip
#   - piper-phonemize-f3ff95afc03640bc1399e113e83361192a2fafb4.zip
#   - simple-sentencepiece-0.7.tar.gz
#   - kaldi-native-fbank-1.22.3.tar.gz
#   - kaldi-decoder-0.3.0.tar.gz
#   - kaldifst-1.8.0.tar.gz
#   - openfst-1.8.5-2026-07-09.tar.gz
#   - kissfft-febd4caeed32e33ad8b2e0bb5ea77542c40f18ec.zip
#   - json-3.12.0.tar.gz
#   - eigen-5.0.1.tar.gz

sherpa_src = meson.project_source_root() / 'subprojects' / 'sherpa-onnx'
sherpa_inc = include_directories(
  'subprojects' / 'sherpa-onnx',
  'subprojects' / 'sherpa-onnx' / 'sherpa-onnx' / 'c-api',
)
sherpa_builddir = meson.current_build_dir() / 'subprojects' / 'sherpa-onnx'

sherpa_cmake_args = [
  '-S', sherpa_src,
  '-B', sherpa_builddir,
  '-DCMAKE_BUILD_TYPE=Release',
  '-DCMAKE_POSITION_INDEPENDENT_CODE:BOOL=ON',
  '-DCMAKE_CXX_FLAGS=-D_GLIBCXX_USE_CXX11_ABI=0',
  # GCC 16 treats -Werror=format-security without -Wformat as an error.
  # sherpa-onnx 1.13.6 adds -Wno-format to espeak-ng after Arch/Debian
  # CFLAGS inject both flags, so the later -Wno-format leaves
  # format-security as a hard error. Setting CMAKE_C_FLAGS drops the
  # env -Werror=format-security; Release still supplies -O3.
  '-DCMAKE_C_FLAGS=-Wno-error=format-security',
  '-DBUILD_SHARED_LIBS=OFF',
  '-DSHERPA_ONNX_ENABLE_PYTHON=OFF',
  '-DSHERPA_ONNX_ENABLE_TESTS=OFF',
  '-DSHERPA_ONNX_ENABLE_CHECK=OFF',
  '-DSHERPA_ONNX_ENABLE_PORTAUDIO=OFF',
  '-DSHERPA_ONNX_ENABLE_JNI=OFF',
  '-DSHERPA_ONNX_ENABLE_C_API=ON',
  '-DSHERPA_ONNX_ENABLE_WEBSOCKET=OFF',
  '-DSHERPA_ONNX_ENABLE_GPU=OFF',
  '-DSHERPA_ONNX_ENABLE_BINARY=OFF',
  '-DSHERPA_ONNX_BUILD_C_API_EXAMPLES=OFF',
  '-DSHERPA_ONNX_ENABLE_TTS=ON',
  '-DSHERPA_ONNX_ENABLE_SPEAKER_DIARIZATION=OFF',
]

sherpa_configure_cmd = ' '.join(['cmake'] + sherpa_cmake_args)
sherpa_build_cmd     = 'cmake --build ' + sherpa_builddir + ' --target sherpa-onnx-c-api --parallel "$jobs"'
sherpa_touch_cmd     = ' '.join(['cmake', '-E', 'touch', '@OUTPUT@'])
sherpa_sidecar_script = sidecar_pick_jobs + sherpa_configure_cmd + ' && ' + sherpa_build_cmd + ' && ' + sherpa_touch_cmd

sherpa_build = custom_target(
  'sherpa-build',
  output: 'owlet-sherpa-stamp',
  command: [find_program('sh'), '-c', sherpa_sidecar_script],
  build_by_default: true,
  console: true,
)

sherpa_archives = [
  sherpa_builddir / 'lib' / 'libsherpa-onnx-c-api.a',
  sherpa_builddir / 'lib' / 'libsherpa-onnx-core.a',
  sherpa_builddir / 'lib' / 'libkaldi-decoder-core.a',
  sherpa_builddir / 'lib' / 'libsherpa-onnx-kaldifst-core.a',
  sherpa_builddir / 'lib' / 'libsherpa-onnx-fstfar.a',
  sherpa_builddir / 'lib' / 'libsherpa-onnx-fst.a',
  sherpa_builddir / 'lib' / 'libpiper_phonemize.a',
  sherpa_builddir / 'lib' / 'libssentencepiece_core.a',
  sherpa_builddir / 'lib' / 'libespeak-ng.a',
  sherpa_builddir / 'lib' / 'libkaldi-native-fbank-core.a',
  sherpa_builddir / 'lib' / 'libucd.a',
  sherpa_builddir / 'lib' / 'libkissfft-float.a',
  sherpa_builddir / '_deps' / 'onnxruntime-src' / 'lib' / 'libonnxruntime.a',
]

tts_dep = declare_dependency(
  sources: sherpa_build,
  include_directories: sherpa_inc,
  link_args: sherpa_archives,
  dependencies: [m_lib, stdcpp_lib],
)


subdir('data')
subdir('src')
subdir('po')
subdir('tests')

gnome.post_install(
     glib_compile_schemas: true,
    gtk_update_icon_cache: true,
  update_desktop_database: true,
)
