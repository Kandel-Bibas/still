#ifndef STILL_AUDIO_DSP_H
#define STILL_AUDIO_DSP_H

#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct StillDSP StillDSP;

// Float32 PCM stereo input. Offset is measured in AudioBuffers, not channels.
// Creation/destruction run off the audio thread; destroy only after IO stops.
StillDSP* _Nullable StillDSPCreate(double sampleRate, uint32_t inputBufferOffset,
                         uint32_t inputChannels, bool inputInterleaved,
                         uint32_t outputChannels, bool outputInterleaved);
void StillDSPDestroy(StillDSP* _Nullable dsp);
// Thread-safe. Finite gains clamp to [0, 1]; nonfinite gains silence rendering.
void StillDSPSetGain(StillDSP* _Nullable dsp, float gain);
// Opt-in diagnostics; disabled by default. Only peak amplitudes are retained.
// Peaks describe the latest completed callback, including any gain ramp.
void StillDSPSetMetering(StillDSP* _Nullable dsp, bool enabled);
float StillDSPGetInputPeak(StillDSP* _Nullable dsp);
float StillDSPGetOutputPeak(StillDSP* _Nullable dsp);
// One render thread per instance. Input and output storage must not alias.
// Output is cleared first. Invalid active buffers return kAudio_ParamError.
// Empty/inactive output is ignored and does not increment either counter.
OSStatus StillDSPRender(StillDSP* _Nullable dsp, const AudioBufferList* _Nullable input,
                        AudioBufferList* _Nullable output);
OSStatus StillDSPIOProc(AudioObjectID device, const AudioTimeStamp* _Nonnull now,
                        const AudioBufferList* _Nonnull input, const AudioTimeStamp* _Nonnull inputTime,
                        AudioBufferList* _Nonnull output, const AudioTimeStamp* _Nonnull outputTime,
                        void* _Nullable context);
uint64_t StillDSPGetFaultCount(StillDSP* _Nullable dsp);
uint64_t StillDSPGetRenderCount(StillDSP* _Nullable dsp);

#ifdef __cplusplus
}
#endif

#endif
