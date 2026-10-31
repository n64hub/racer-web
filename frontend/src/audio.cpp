// Sound: the game's AI buffers (16-bit stereo, from osAiSetNextBuffer) go to an SDL audio queue.
//
// The game asks how much is still buffered (osAiGetLength) to decide how much to mix next. Normally
// that's the real queue. In deterministic mode (netplay) the real queue differs per machine, which
// would change what the game does, so the answer comes from game time instead: what the game queued
// minus what game time says has played. Both machines then mix the same amounts.
//
// On a page the sound goes to N64Recomp-browser's output (audio_output.h) in place of SDL's queue, whose callback runs
// on the page's thread, where WebGPU's work runs too, and breaks up whenever that thread is busy. The output plays at
// the page's rate, so the game's buffers are resampled to it here, and its queue is counted back in the game's frames.

#include <SDL.h>

#include <algorithm>
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <vector>

#include "config.hpp"
#include "internal.hpp"
#ifdef __EMSCRIPTEN__
#include "audio_output.h"
#endif

namespace fe {
namespace {

SDL_AudioDeviceID g_device = 0;
uint32_t g_rate = 0;
constexpr int kChannels = 2;
constexpr uint32_t kBytesPerFrame = kChannels * sizeof(float);

// Deterministic mode's model of the buffer, in sample frames.
uint64_t g_det_queued = 0;
uint64_t g_det_first_retrace = 0;
bool g_det_started = false;

#ifdef __EMSCRIPTEN__
uint32_t g_output_rate = 0;  // the page's audio context's
double g_resample_pos = 0.0; // where the next output frame falls, in input frames after g_last
float g_last[kChannels] = {};

void open_device(uint32_t rate) {
    if (g_output_rate == 0) g_output_rate = n64recomp_browser::audio::open(kChannels);
    g_device = 1;
    printf("[audio] %u Hz, played at %u Hz\n", rate, g_output_rate);
}

// Linear interpolation from the game's rate to the output's, carried across buffers.
void output(const float* in, size_t frames) {
    static std::vector<float> out;
    const double step = (double)g_rate / g_output_rate;
    out.clear();
    for (;;) {
        const size_t i = (size_t)g_resample_pos; // between input frame i - 1 (g_last when 0) and i
        if (i >= frames) break;
        const float t = (float)(g_resample_pos - i);
        for (int c = 0; c < kChannels; c++) {
            const float a = i == 0 ? g_last[c] : in[(i - 1) * kChannels + c];
            out.push_back(a + (in[i * kChannels + c] - a) * t);
        }
        g_resample_pos += step;
    }
    g_resample_pos -= frames;
    if (frames) for (int c = 0; c < kChannels; c++) g_last[c] = in[(frames - 1) * kChannels + c];
    n64recomp_browser::audio::queue(out.data(), out.size() / kChannels);
}

size_t device_queued_frames() {
    return g_output_rate ? (size_t)((uint64_t)n64recomp_browser::audio::queued_frames() * g_rate / g_output_rate) : 0;
}
#else
void open_device(uint32_t rate) {
    if (g_device) SDL_CloseAudioDevice(g_device);
    SDL_AudioSpec want{}, have{};
    want.freq = (int)rate;
    want.format = AUDIO_F32SYS;
    want.channels = kChannels;
    want.samples = 512;
    g_device = SDL_OpenAudioDevice(nullptr, 0, &want, &have, 0);
    if (!g_device) { fprintf(stderr, "[audio] can't open an audio device: %s\n", SDL_GetError()); return; }
    SDL_PauseAudioDevice(g_device, 0);
    printf("[audio] %u Hz\n", rate);
}

void output(const float* frames, size_t count) {
    SDL_QueueAudio(g_device, frames, (Uint32)(count * kBytesPerFrame));
}

size_t device_queued_frames() {
    return SDL_GetQueuedAudioSize(g_device) / kBytesPerFrame;
}
#endif

void queue_samples(int16_t* data, size_t count) {
    if (det_enabled()) {
        if (!g_det_started) { g_det_started = true; g_det_first_retrace = det_frame(); }
        g_det_queued += count / kChannels;
    }
    if (!g_device) return;
    // ponytail: in deterministic mode game time and the sound card drift apart slowly; drop a buffer
    // when the queue passes 200 ms rather than resampling.
    if (det_enabled() && device_queued_frames() > g_rate / 5) return;

    static std::vector<float> out;
    out.resize(count);
    const float volume = std::clamp((float)g_config.volume, 0.0f, 1.0f) / 32768.0f;
    // The buffer is read through the N64's byte-swapped memory, so each frame's channels come swapped.
    for (size_t i = 0; i + 1 < count; i += 2) {
        out[i] = data[i + 1] * volume;
        out[i + 1] = data[i] * volume;
    }
    // <prefix>AUDIODUMP=<file>: also write the output as raw 16-bit stereo, for checks without speakers.
    static FILE* dump = [] { const char* p = std::getenv((g_game.env_prefix + "AUDIODUMP").c_str()); return p ? std::fopen(p, "wb") : nullptr; }();
    if (dump) {
        for (size_t i = 0; i + 1 < count; i += 2) { int16_t lr[2] = { data[i + 1], data[i] }; std::fwrite(lr, sizeof(lr), 1, dump); }
        std::fflush(dump);
    }
    output(out.data(), count / kChannels);
}

size_t queued_frames() {
    if (det_enabled()) {
        if (!g_det_started || g_rate == 0) return 0;
        uint64_t played = (det_frame() - g_det_first_retrace) * g_rate / 60;
        return g_det_queued > played ? (size_t)(g_det_queued - played) : 0;
    }
    // (The runtime reports half a frame less than this, so the game mixes a little ahead.)
    return g_device ? device_queued_frames() : 0;
}

// Never report more than two video frames' worth. Real hardware never has more queued than that,
// and games mix "a frame minus what's queued" in 16 bits: Racer's mixer wraps a big backlog (after a
// hitch) into a huge positive count, overflows its command list and halts forever. Reporting
// "plenty" makes the game mix its minimum, so a backlog drains on its own.
size_t get_frames_remaining() {
    return std::min(queued_frames(), (size_t)(g_rate / 30));
}

void set_frequency(uint32_t rate) {
    if (rate == g_rate) return;
    g_rate = rate; // even if no device opens: deterministic mode's model needs it on every machine
    open_device(rate);
}

} // namespace

ultramodern::audio_callbacks_t audio_callbacks() {
    return { queue_samples, get_frames_remaining, set_frequency };
}

} // namespace fe
