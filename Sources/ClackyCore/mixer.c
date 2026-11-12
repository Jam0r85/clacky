#include "ClackyCore.h"

#include <mach/mach_time.h>
#include <math.h>
#include <os/lock.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#define KC_MAX_VOICES 32
#define KC_QUEUE_SIZE 64 /* must be a power of two */
#define KC_QUEUE_MASK (KC_QUEUE_SIZE - 1)
#define KC_FILTER_TAIL 64.0f /* extra samples so the low-pass can ring out */
#define KC_MAX_VOLUME 8.0f   /* +18 dB, room to make up for a turned-down Mac */
#define KC_LIMIT_CEILING 0.95f
#define KC_LIMIT_RECOVERY 0.0003f /* per sample, back towards unity: ~70 ms at 48 kHz */

typedef struct {
    kc_voice_params p;
    float pos;  /* playhead in source samples, before per-ear delay */
    float end;  /* playhead value at which both ears are finished */
    float z_l;  /* low-pass state */
    float z_r;
    bool active;
} kc_voice;

struct kc_mixer {
    kc_voice voices[KC_MAX_VOICES];
    kc_voice_params queue[KC_QUEUE_SIZE];
    _Atomic uint32_t head; /* consumer: audio thread */
    _Atomic uint32_t tail; /* producers, serialised by producer_lock */
    os_unfair_lock producer_lock;
    _Atomic float volume;
    _Atomic uint32_t active_count;
    _Atomic uint64_t last_render; /* mach_absolute_time() of the latest render call, 0 = never */
    /* Audio thread only. */
    float applied_volume; /* ramps to `volume` across a block, so changes don't click */
    float limit_gain;     /* peak limiter, 1 = not limiting */
};

kc_mixer *kc_mixer_create(void) {
    kc_mixer *m = calloc(1, sizeof(kc_mixer));
    if (!m) return NULL;
    m->producer_lock = OS_UNFAIR_LOCK_INIT;
    atomic_store(&m->volume, 0.6f);
    m->applied_volume = 0.6f;
    m->limit_gain = 1.0f;
    return m;
}

void kc_mixer_destroy(kc_mixer *m) { free(m); }

bool kc_mixer_trigger(kc_mixer *m, const kc_voice_params *p) {
    if (!m || !p || !p->samples || p->length == 0) return false;

    os_unfair_lock_lock(&m->producer_lock);
    uint32_t tail = atomic_load_explicit(&m->tail, memory_order_relaxed);
    uint32_t head = atomic_load_explicit(&m->head, memory_order_acquire);
    bool ok = (tail - head) < KC_QUEUE_SIZE;
    if (ok) {
        m->queue[tail & KC_QUEUE_MASK] = *p;
        atomic_store_explicit(&m->tail, tail + 1, memory_order_release);
    }
    os_unfair_lock_unlock(&m->producer_lock);
    return ok;
}

void kc_mixer_set_volume(kc_mixer *m, float v) {
    if (!m) return;
    if (!(v >= 0.0f)) v = 0.0f; /* also catches NaN */
    if (v > KC_MAX_VOLUME) v = KC_MAX_VOLUME;
    atomic_store_explicit(&m->volume, v, memory_order_relaxed);
}

void kc_mixer_reset(kc_mixer *m) {
    if (!m) return;
    os_unfair_lock_lock(&m->producer_lock);
    for (int i = 0; i < KC_MAX_VOICES; i++) m->voices[i].active = false;
    atomic_store(&m->head, atomic_load(&m->tail));
    atomic_store(&m->active_count, 0);
    m->limit_gain = 1.0f;
    os_unfair_lock_unlock(&m->producer_lock);
}

uint32_t kc_mixer_active_voices(kc_mixer *m) {
    if (!m) return 0;
    uint32_t pending = atomic_load_explicit(&m->tail, memory_order_acquire) -
                       atomic_load_explicit(&m->head, memory_order_acquire);
    return atomic_load_explicit(&m->active_count, memory_order_relaxed) + pending;
}

double kc_mixer_seconds_since_render(kc_mixer *m) {
    if (!m) return INFINITY;
    uint64_t last = atomic_load_explicit(&m->last_render, memory_order_relaxed);
    if (last == 0) return INFINITY;
    uint64_t now = mach_absolute_time();
    if (now <= last) return 0;
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    return (double)(now - last) * timebase.numer / timebase.denom / 1e9;
}

static inline float sample_at(const float *s, uint32_t len, float x) {
    if (x < 0.0f) return 0.0f;
    uint32_t i = (uint32_t)x;
    if (i >= len) return 0.0f;
    float frac = x - (float)i;
    float a = s[i];
    float b = (i + 1 < len) ? s[i + 1] : 0.0f;
    return a + (b - a) * frac;
}

static inline float clampf(float x, float lo, float hi) {
    if (!(x >= lo)) return lo; /* NaN -> lo */
    return x > hi ? hi : x;
}

/* Free voice if there is one, otherwise steal the one furthest through its sound. */
static kc_voice *allocate_voice(kc_mixer *m) {
    kc_voice *victim = &m->voices[0];
    float victim_progress = -1.0f;
    for (int i = 0; i < KC_MAX_VOICES; i++) {
        kc_voice *v = &m->voices[i];
        if (!v->active) return v;
        float progress = v->pos / v->end;
        if (progress > victim_progress) {
            victim_progress = progress;
            victim = v;
        }
    }
    return victim;
}

static void start_queued_voices(kc_mixer *m) {
    uint32_t head = atomic_load_explicit(&m->head, memory_order_relaxed);
    uint32_t tail = atomic_load_explicit(&m->tail, memory_order_acquire);
    while (head != tail) {
        const kc_voice_params *p = &m->queue[head & KC_QUEUE_MASK];
        kc_voice *v = allocate_voice(m);
        v->p = *p;
        v->p.rate = clampf(p->rate, 0.25f, 4.0f);
        v->p.delay_l = clampf(p->delay_l, 0.0f, 4096.0f);
        v->p.delay_r = clampf(p->delay_r, 0.0f, 4096.0f);
        v->p.lp_l = clampf(p->lp_l, 0.001f, 1.0f);
        v->p.lp_r = clampf(p->lp_r, 0.001f, 1.0f);
        v->pos = 0.0f;
        v->z_l = 0.0f;
        v->z_r = 0.0f;
        v->end = (float)p->length + fmaxf(v->p.delay_l, v->p.delay_r) + KC_FILTER_TAIL;
        v->active = true;
        head++;
    }
    atomic_store_explicit(&m->head, head, memory_order_release);
}

bool kc_mixer_render(kc_mixer *m, uint32_t frames, float *left, float *right) {
    memset(left, 0, frames * sizeof(float));
    memset(right, 0, frames * sizeof(float));
    if (!m) return false;
    atomic_store_explicit(&m->last_render, mach_absolute_time(), memory_order_relaxed);

    start_queued_voices(m);

    const float volume = atomic_load_explicit(&m->volume, memory_order_relaxed);
    if (frames == 0) return false;
    uint32_t still_active = 0;
    bool rendered = false;

    for (int vi = 0; vi < KC_MAX_VOICES; vi++) {
        kc_voice *v = &m->voices[vi];
        if (!v->active) continue;
        rendered = true;

        const float *s = v->p.samples;
        const uint32_t len = v->p.length;
        const float rate = v->p.rate;
        const float gl = v->p.gain_l, gr = v->p.gain_r;
        const float dl = v->p.delay_l, dr = v->p.delay_r;
        const float cl = v->p.lp_l, cr = v->p.lp_r;
        const float end = v->end;
        float pos = v->pos, zl = v->z_l, zr = v->z_r;

        for (uint32_t i = 0; i < frames; i++) {
            zl += cl * (sample_at(s, len, pos - dl) - zl);
            zr += cr * (sample_at(s, len, pos - dr) - zr);
            left[i] += zl * gl;
            right[i] += zr * gr;
            pos += rate;
            if (pos >= end) break;
        }

        v->pos = pos;
        v->z_l = zl;
        v->z_r = zr;
        if (pos >= end) {
            v->active = false;
        } else {
            still_active++;
        }
    }

    atomic_store_explicit(&m->active_count, still_active, memory_order_relaxed);

    if (!rendered) {
        m->applied_volume = volume;
        m->limit_gain = 1.0f;
        return false;
    }

    /* Master volume, then a stereo-linked peak limiter: it pulls the gain down at once
     * when a click would pass the ceiling and lets it recover over ~70 ms. Below the
     * ceiling it does nothing, so normal levels are untouched. */
    float vol = m->applied_volume, g = m->limit_gain;
    const float step = (volume - vol) / (float)frames;
    for (uint32_t i = 0; i < frames; i++) {
        vol += step;
        const float l = left[i] * vol, r = right[i] * vol;
        const float peak = fmaxf(fabsf(l), fabsf(r));
        if (peak * g > KC_LIMIT_CEILING) g = KC_LIMIT_CEILING / peak;
        left[i] = clampf(l * g, -1.0f, 1.0f);
        right[i] = clampf(r * g, -1.0f, 1.0f);
        g += (1.0f - g) * KC_LIMIT_RECOVERY;
    }
    m->applied_volume = volume;
    m->limit_gain = g;
    return true;
}
