#ifndef CLACKY_CORE_H
#define CLACKY_CORE_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// A tiny polyphonic sample mixer with per-voice binaural placement.
///
/// Threading model:
///   - kc_mixer_trigger / kc_mixer_set_volume may be called from any non-audio thread.
///   - kc_mixer_render must only be called from the audio render thread. It never
///     allocates, never locks and returns quickly when nothing is playing.
typedef struct kc_mixer kc_mixer;

typedef struct {
    /// Mono float samples. Must stay valid (immutable) for as long as the voice may play.
    const float *samples;
    uint32_t length;
    /// Playback rate (1.0 = original pitch), lets each key sound slightly different.
    float rate;
    /// Per-ear gain (interaural level difference).
    float gain_l;
    float gain_r;
    /// Per-ear delay in samples (interaural time difference). Fractional values are fine.
    float delay_l;
    float delay_r;
    /// One-pole low-pass coefficient per ear, 0 < c <= 1 (1 = bypass). Models head shadow.
    float lp_l;
    float lp_r;
} kc_voice_params;

kc_mixer *kc_mixer_create(void);
void kc_mixer_destroy(kc_mixer *mixer);

/// Queues a voice to start on the next render cycle. Returns false if the queue is full.
bool kc_mixer_trigger(kc_mixer *mixer, const kc_voice_params *params);

/// Master volume, 0...8. Above 1 is a boost; a peak limiter keeps the output below full scale.
void kc_mixer_set_volume(kc_mixer *mixer, float volume);

/// Silences every voice and drops queued triggers. Only call while the audio
/// engine is stopped or paused (no render in flight), e.g. before freeing sample memory.
void kc_mixer_reset(kc_mixer *mixer);

/// Number of voices currently sounding (approximate, for idle detection).
uint32_t kc_mixer_active_voices(kc_mixer *mixer);

/// Seconds since the audio thread last asked for a block (infinity if it never has).
/// While the output is running this stays at a few milliseconds; if it grows, the
/// output has stopped pulling audio even though the engine still says it's running.
double kc_mixer_seconds_since_render(kc_mixer *mixer);

/// Renders `frames` samples into non-interleaved stereo buffers (overwrites them).
/// Returns false if the output is pure silence.
bool kc_mixer_render(kc_mixer *mixer, uint32_t frames, float *left, float *right);

#ifdef __cplusplus
}
#endif

#endif
