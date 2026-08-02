import numpy as np
from scipy.io import wavfile

sample_rate = 44100

def generate_soft_pluck(freq, duration=0.15, sr=44100):
    t = np.linspace(0, duration, int(sr * duration), False)
    
    # Fundamental + warm 2nd/3rd harmonics
    wave = 0.6 * np.sin(2 * np.pi * freq * t)
    wave += 0.25 * np.sin(2 * np.pi * (freq * 2) * t)
    wave += 0.10 * np.sin(2 * np.pi * (freq * 3) * t)
    
    # Envelope: 10ms attack, exponential decay
    attack = np.minimum(t / 0.010, 1.0)
    decay = np.exp(-t * 22)
    envelope = attack * decay
    
    return wave * envelope

# C5 (523.25 Hz) -> E5 (659.25 Hz)
tone1 = generate_soft_pluck(523.25, duration=0.14)
tone2 = generate_soft_pluck(659.25, duration=0.18)

# Stagger notes by 40ms
offset = int(sample_rate * 0.04)
combined_length = offset + len(tone2)
sound = np.zeros(combined_length)

sound[:len(tone1)] += tone1
sound[offset:offset+len(tone2)] += tone2

# -------------------------------------------------------------
# PADDING FIX: Prevent audio driver startup cutoff & Ogg clipping
# -------------------------------------------------------------
pad_front = np.zeros(int(sample_rate * 0.05))  # 50ms silence at start
pad_back = np.zeros(int(sample_rate * 0.15))   # 150ms silence at end

buffer = np.concatenate([pad_front, sound, pad_back])

# Normalize and convert to 16-bit PCM WAV
buffer = buffer / np.max(np.abs(buffer)) * 0.8
audio_16bit = (buffer * 32767).astype(np.int16)

wavfile.write("start_dictation.wav", sample_rate, audio_16bit)
print("Saved start_dictation.wav with leading padding!")