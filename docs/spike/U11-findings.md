# U11 Spike Findings — Local TTS Engine & Voice (2026-08-23)

Machine: Ryzen 7 7800X3D (8C/16T), 62 GB RAM, RX 7900 XTX (gfx1100, Vulkan/ROCm).
Test text: 35-word *Time Machine* passage (`test-quick.txt`) + 14,964-word 30-page doc (`doc-30page.txt`).
All artifacts in `/tmp/opencode/tts-spike/`.

## Measured (same passage, all backends)

| Backend | File | Audio | CPU wall | Vulkan wall (7900 XTX) | Rate | Peak RSS | Weight license |
|---|---|---|---|---|---|---|---|
| Kokoro v0_19 fp32 · af_bella sid 1 · sherpa-onnx v1.13.6 | kokoro_quick_test.wav | 11.2 s | ~15 s | n/a (no Vulkan EP) | CPU **~5× RT** (full doc: 895 s → 74.8 min audio) | 1.71 GB | Apache-2.0 (engine + voices) |
| Piper lessac-medium · sherpa-onnx VITS | piper_quick_test.wav | 9.9 s | <10 s | n/a (same runtime) | CPU real-time+ | small | Apache-2.0 |
| Bark-small · bark.cpp (ggml f16) | bark_quick_test.wav | 10.9 s | **689 s** | **crash** (op gap) | CPU ~63× slower than RT | ~2 GB | **non-commercial (Suno)** |
| Qwen3-TTS 1.7B CV Q8_0 · serena · qwentts.cpp | qwen_quick_test.wav / _vulkan.wav | 18.4 / 15.5 s | 595 s (incl. 2.2 GB load) | **4 s** (incl. load) | CPU ~20–30× slower than RT · GPU **>5× RT** | ~2.5 GB / ~4 GB VRAM | Apache-2.0 (weights) + MIT (code) |

Owner ear verdicts: Kokoro af_bella — **"need more"** (not passed). Piper/Bark/Qwen clips delivered for comparison.

---

## sherpa-onnx + Kokoro (the plan's KTD-1/KTD-2 pick)

**What it is.** Apache-2.0, C/C++ inference runtime (Xiaomi k2-fsa) with a large offline-TTS/ASR model zoo. The Owlet plan already designs U1 as a pinned source sidecar mirroring transcribe.cpp (`custom_target` + `declare_dependency`).

**Verified in this spike.**
- Latest release **v1.13.6** (2026-08). Prebuilt linux-x64 tarballs (shared/static, CPU) bundle onnxruntime + the `sherpa-onnx-offline-tts` CLI. GPU prebuilts are **CUDA-only**.
- Pins **onnxruntime v1.27.1** (csukuangfj `onnxruntime-libs`, glibc2.17) fetched as a zip at cmake configure time — the configure-time fetch U1/U6 already plan for.
- Execution providers in the pinned ORT: CPU, CUDA, CoreML, XNNPACK, NNAPI, TRT, DirectML, SpacemiT. **No Vulkan EP** — upstream issue #21917 is still open with no plans; the endorsed alternative is the experimental WebGPU EP (Dawn-based, plugin-EP registration, limited op coverage). Not a product path. ROCm EP exists but was excluded per owner (disk footprint).
- Kokoro v0_19 English asset: official `kokoro-en-v0_19.tar.bz2` (305 MB; sha256 `91280485…605ac7`), contains `model.onnx` (fp32, 330 MB), `voices.bin`, `tokens.txt`, `espeak-ng-data/`, LICENSE = Apache-2.0. Roster (11 speakers, official docs): 0 af · 1 af_bella · 2 af_nicole · 3 af_sarah · 4 af_sky · 5 am_adam · 6 am_michael · 7 bf_emma · 8 bf_isabella · 9 bm_george · 10 bm_lewis. `af_heart` is not in this roster (plan KTD-2 correct).
- C API shape matches the plan: config (model/voices/tokens/espeak-data-dir/threads) → generate with progress callback → PCM @ 24 kHz; `--sid` picks the speaker.
- **Performance (8C/16T CPU, 16 threads):** full 30-page doc → 74.8 min audio in 895 s (RTF ≈ 0.20, ~5× real-time), peak RSS **1.71 GB**. Fits the product's CPU-first, streaming shape with headroom.

**Why it is still the default.** Only candidate that is real-time on CPU *and* license-clean end-to-end (code + engine + voice). Integration path (U1 sidecar, VAPI subset, asset pipeline) is already designed. Swap flexibility: Piper and KittenTTS models run through the same runtime (config change, not re-integration).

**Open issue.** The committed voice (af_bella) did **not** pass the owner's ear check. The other 10 roster voices are one `--sid` away (~15 s to render each) — untried before ruling the engine out.

---

## qwentts.cpp (Qwen3-TTS port)

**What it is.** MIT-licensed (code, "omnivoice.cpp authors") C++17 GGML port of **Qwen3-TTS 12Hz** (Alibaba Qwen team), tested at commit `a8a7716` (2026-08-07). Model weights are **Apache-2.0** (HF tag on `Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice`). Pre-converted GGUFs published at HF `Serveurperso/Qwen3-TTS-GGUF` (F32/BF16/Q8_0/Q4_K_M) — no conversion step needed for a spike or a pinned asset.

**Architecture.** Two-stage, 12 Hz frame rate, 24 kHz mono: a **Talker LM** (0.6B or 1.7B) emits the semantic codebook while a code-predictor MTP head emits 15 acoustic codes per frame (both KV-cached), decoded by a 16-codebook RVQ codec (SEANet + ConvNeXt + DAC v2). Seedable sampling (temp/top-k/top-p/rep-pen, greedy).

**Product-relevant features.**
- **Named speakers** (CustomVoice mode): serena, vivian, uncle_fu, ryan, aiden, ono_anna, sohee, eric (sichuan), dylan (beijing) — a speaker is baked into the checkpoint, so consistency is structural, not emergent.
- **Zero-shot voice cloning** (Base mode: reference WAV + transcript, x-vector or in-context) and **voice design** from a text instruction (1.7B only) — future surface, not v1.
- Three tools: `qwen-tts` (text→WAV), `qwen-codec` (WAV↔RVQ), `tts-server` (OpenAI-compatible HTTP).
- Backends: CPU, CUDA, **Vulkan**, Metal (build scripts per backend; no ROCm script).

**Measured.**
- CPU (8 threads on 16T; the binary hard-defaults to 8, **no thread-count flag**, force device via `GGML_BACKEND=Vulkan0` env): 595 s wall for 18.4 s audio incl. 2.2 GB one-time load (TTFA 5.5 s) → ~20–30× slower than real-time. A 75-min document is a **multi-day CPU render** — not the product shape.
- Vulkan (RX 7900 XTX): 4 s wall for 15.5 s audio incl. 2.2 GB load → **>5× real-time on GPU**; ~4 GB VRAM.

**Limitations found.**
- `--max-new` defaults to **2048 frames ≈ 163 s of audio per one-shot call** — long documents need chunked multi-call generation (~150 calls for 75 min). The CLI has no built-in long-text splitting (line-by-line mode flushes per line).
- Asset size: 1.7B Q8_0 talker 2.0 GB + tokenizer 278 MB (≈2.3 GB download vs Kokoro's 305 MB).
- New dependency surface for Owlet: ggml sidecar (different build shape from the transcribe.cpp/onnxruntime pattern the plan assumes) and a GGUF asset class.

---

## Disqualifiers recorded

- **Bark / bark.cpp** (MIT code): weights are Suno community license — **non-commercial, no redistribution**; the port has **no voice-prompt API** (speaker is emergent and drifts per generation; 256-token hard cap per generation); CPU is ~63× slower than real-time; its pinned 2023-era ggml-vulkan backend aborts on Bark's graph (`Missing op: SET`; also lacks CONV_1D/CONV_TRANSPOSE_1D). Rejected on license, consistency, and speed simultaneously.
- **Kokoro GPU:** no Vulkan EP in pinned onnxruntime — irrelevant for the CPU-first product, noted for completeness.

## Spike finding (for the decision)

1. **Kokoro via sherpa-onnx** is the only candidate that is CPU-real-time with a clean license and a designed integration path — but the pinned voice (af_bella) failed the ear check. **Cheapest next step: render the other 10 roster sids** (~2 min total) before ruling the engine out.
2. **Qwen3-TTS via qwentts.cpp** is license-clean (MIT + Apache-2.0), has structurally consistent named speakers, and is real-time+ **on Vulkan only**. Adopting it changes the product assumption "acceptable CPU cost" into a **GPU (Vulkan) requirement**, adds a ggml sidecar + 2.3 GB asset, and needs a chunked long-form pipeline in Owlet (the `--max-new` 163 s cap). The 0.6B variant exists if a lighter CPU option is wanted (untested).
3. **Piper** remains the designated low-risk fallback (CPU-real-time, Apache-2.0), at the known "utility, not hour-long narration" quality level.

Verdict: pending owner choice — (a) hear the remaining Kokoro voices, (b) commit to Qwen + Vulkan requirement, or (c) both (Kokoro default, Qwen as documented alternative). Nothing in this spike changes the U2/U8 scope; U1's engine pin is the single constant the choice updates.
