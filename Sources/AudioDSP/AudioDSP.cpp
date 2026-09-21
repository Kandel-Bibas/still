#include "AudioDSP.h"

#include <atomic>
#include <cmath>
#include <cstring>
#include <limits>
#include <new>

static_assert(std::atomic<float>::is_always_lock_free);
static_assert(std::atomic<uint64_t>::is_always_lock_free);
static_assert(std::atomic<bool>::is_always_lock_free);

struct StillDSP {
    uint32_t inputOffset;
    uint32_t outputChannels;
    uint32_t rampFrames;
    bool inputInterleaved;
    bool outputInterleaved;
    std::atomic<float> targetGain{1.0f};
    std::atomic<uint64_t> faults{0};
    std::atomic<uint64_t> renders{0};
    std::atomic<bool> metering{false};
    std::atomic<float> inputPeak{0};
    std::atomic<float> outputPeak{0};
    float currentGain = 0;
    float previousTarget = 0;
    float gainStep = 0;
    uint32_t rampRemaining = 0;
};

StillDSP* StillDSPCreate(double sampleRate, uint32_t inputBufferOffset,
                         uint32_t inputChannels, bool inputInterleaved,
                         uint32_t outputChannels, bool outputInterleaved) {
    const double frames = std::ceil(sampleRate * 0.005);
    if (!std::isfinite(sampleRate) || sampleRate <= 0 ||
        frames > std::numeric_limits<uint32_t>::max() || inputChannels != 2 ||
        outputChannels == 0 || outputChannels > UINT32_MAX / sizeof(float) ||
        inputBufferOffset > UINT32_MAX - (inputInterleaved ? 1u : 2u)) {
        return nullptr;
    }
    auto* dsp = new (std::nothrow) StillDSP;
    if (!dsp) return nullptr;
    dsp->inputOffset = inputBufferOffset;
    dsp->outputChannels = outputChannels;
    dsp->rampFrames = frames < 1 ? 1 : static_cast<uint32_t>(frames);
    dsp->inputInterleaved = inputInterleaved;
    dsp->outputInterleaved = outputInterleaved;
    return dsp;
}

void StillDSPDestroy(StillDSP* dsp) { delete dsp; }

void StillDSPSetGain(StillDSP* dsp, float gain) {
    if (!dsp) return;
    if (std::isfinite(gain)) {
        gain = gain < 0 ? 0 : (gain > 1 ? 1 : gain);
    }
    dsp->targetGain.store(gain, std::memory_order_relaxed);
}

void StillDSPSetMetering(StillDSP* dsp, bool enabled) {
    if (!dsp) return;
    dsp->inputPeak.store(0, std::memory_order_relaxed);
    dsp->outputPeak.store(0, std::memory_order_relaxed);
    dsp->metering.store(enabled, std::memory_order_relaxed);
}

float StillDSPGetInputPeak(StillDSP* dsp) {
    return dsp && dsp->metering.load(std::memory_order_relaxed) ?
        dsp->inputPeak.load(std::memory_order_relaxed) : 0;
}

float StillDSPGetOutputPeak(StillDSP* dsp) {
    return dsp && dsp->metering.load(std::memory_order_relaxed) ?
        dsp->outputPeak.load(std::memory_order_relaxed) : 0;
}

static void clearPeaks(StillDSP* dsp) {
    if (!dsp) return;
    dsp->inputPeak.store(0, std::memory_order_relaxed);
    dsp->outputPeak.store(0, std::memory_order_relaxed);
}

static OSStatus fault(StillDSP* dsp) {
    if (dsp) {
        clearPeaks(dsp);
        dsp->faults.fetch_add(1, std::memory_order_relaxed);
        dsp->currentGain = 0;
        dsp->previousTarget = 0;
        dsp->rampRemaining = 0;
    }
    return kAudio_ParamError;
}

static bool validBuffer(const AudioBuffer& buffer, uint32_t channels,
                        uint32_t& frames) {
    const uint32_t bytesPerFrame = channels * static_cast<uint32_t>(sizeof(float));
    if (!buffer.mData || buffer.mNumberChannels != channels ||
        buffer.mDataByteSize == 0 || buffer.mDataByteSize % bytesPerFrame != 0 ||
        reinterpret_cast<uintptr_t>(buffer.mData) % alignof(float) != 0) {
        return false;
    }
    frames = buffer.mDataByteSize / bytesPerFrame;
    return true;
}

OSStatus StillDSPRender(StillDSP* dsp, const AudioBufferList* input,
                        AudioBufferList* output) {
    if (!output) return fault(dsp);
    bool active = false;
    for (uint32_t i = 0; i < output->mNumberBuffers; ++i) {
        auto& buffer = output->mBuffers[i];
        if (buffer.mData && buffer.mDataByteSize) {
            std::memset(buffer.mData, 0, buffer.mDataByteSize);
            active = true;
        }
    }
    if (!active) {
        clearPeaks(dsp);
        return noErr;
    }
    if (!dsp || !input) return fault(dsp);

    const uint32_t inputBufferCount = dsp->inputInterleaved ? 1 : 2;
    const uint32_t outputBufferCount = dsp->outputInterleaved ? 1 : dsp->outputChannels;
    if (input->mNumberBuffers < dsp->inputOffset + inputBufferCount ||
        output->mNumberBuffers != outputBufferCount) return fault(dsp);

    uint32_t frames = 0;
    if (!validBuffer(input->mBuffers[dsp->inputOffset],
                     dsp->inputInterleaved ? 2 : 1, frames)) return fault(dsp);
    for (uint32_t i = 1; i < inputBufferCount; ++i) {
        uint32_t otherFrames = 0;
        if (!validBuffer(input->mBuffers[dsp->inputOffset + i], 1, otherFrames) ||
            otherFrames != frames) return fault(dsp);
    }
    for (uint32_t i = 0; i < outputBufferCount; ++i) {
        uint32_t otherFrames = 0;
        if (!validBuffer(output->mBuffers[i],
                         dsp->outputInterleaved ? dsp->outputChannels : 1,
                         otherFrames) || otherFrames != frames) return fault(dsp);
    }

    const float target = dsp->targetGain.load(std::memory_order_relaxed);
    if (!std::isfinite(target)) return fault(dsp);
    if (target != dsp->previousTarget) {
        dsp->previousTarget = target;
        dsp->rampRemaining = dsp->rampFrames;
        dsp->gainStep = (target - dsp->currentGain) / dsp->rampFrames;
    }
    const auto* left = static_cast<const float*>(input->mBuffers[dsp->inputOffset].mData);
    const auto* right = dsp->inputInterleaved ? left + 1 :
        static_cast<const float*>(input->mBuffers[dsp->inputOffset + 1].mData);
    const uint32_t inputStride = dsp->inputInterleaved ? 2 : 1;
    auto* outputLeft = static_cast<float*>(output->mBuffers[0].mData);
    auto* outputRight = dsp->outputChannels == 1 ? outputLeft :
        (dsp->outputInterleaved ? outputLeft + 1 :
         static_cast<float*>(output->mBuffers[1].mData));
    const uint32_t outputStride = dsp->outputInterleaved ? dsp->outputChannels : 1;
    const bool metering = dsp->metering.load(std::memory_order_relaxed);
    float inputPeak = 0;
    float outputPeak = 0;
    for (uint32_t i = 0; i < frames; ++i) {
        if (dsp->rampRemaining) {
            --dsp->rampRemaining;
            dsp->currentGain = dsp->rampRemaining ? dsp->currentGain + dsp->gainStep : target;
        }
        const float l = left[i * inputStride] * dsp->currentGain;
        const float r = right[i * inputStride] * dsp->currentGain;
        if (dsp->outputChannels == 1) {
            outputLeft[i] = l * 0.5f + r * 0.5f;
        } else {
            outputLeft[i * outputStride] = l;
            outputRight[i * outputStride] = r;
        }
        if (metering) {
            const float inputL = std::fabs(left[i * inputStride]);
            const float inputR = std::fabs(right[i * inputStride]);
            const float outputL = std::fabs(outputLeft[i * outputStride]);
            const float outputR = std::fabs(outputRight[i * outputStride]);
            if (inputL > inputPeak) inputPeak = inputL;
            if (inputR > inputPeak) inputPeak = inputR;
            if (outputL > outputPeak) outputPeak = outputL;
            if (outputR > outputPeak) outputPeak = outputR;
        }
    }
    if (metering) {
        dsp->inputPeak.store(inputPeak, std::memory_order_relaxed);
        dsp->outputPeak.store(outputPeak, std::memory_order_relaxed);
    }
    dsp->renders.fetch_add(1, std::memory_order_relaxed);
    return noErr;
}

uint64_t StillDSPGetFaultCount(StillDSP* dsp) {
    return dsp ? dsp->faults.load(std::memory_order_relaxed) : 0;
}

OSStatus StillDSPIOProc(AudioObjectID, const AudioTimeStamp*,
                        const AudioBufferList* input, const AudioTimeStamp*,
                        AudioBufferList* output, const AudioTimeStamp*, void* context) {
    return StillDSPRender(static_cast<StillDSP*>(context), input, output);
}

uint64_t StillDSPGetRenderCount(StillDSP* dsp) {
    return dsp ? dsp->renders.load(std::memory_order_relaxed) : 0;
}
