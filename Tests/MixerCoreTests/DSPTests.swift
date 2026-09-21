import AudioDSP
import CoreAudio
import XCTest

private final class BufferList {
    let pointer: UnsafeMutablePointer<AudioBufferList>
    let buffers: UnsafeMutableAudioBufferListPointer
    private var storage: [UnsafeMutablePointer<Float>] = []

    init(_ values: [[Float]], channels: [UInt32]) {
        precondition(values.count == channels.count)
        buffers = AudioBufferList.allocate(maximumBuffers: values.count)
        pointer = buffers.unsafeMutablePointer
        for index in values.indices {
            let samples = UnsafeMutablePointer<Float>.allocate(capacity: max(1, values[index].count))
            samples.initialize(repeating: 0, count: max(1, values[index].count))
            for (offset, value) in values[index].enumerated() { samples[offset] = value }
            storage.append(samples)
            buffers[index] = AudioBuffer(mNumberChannels: channels[index],
                                         mDataByteSize: UInt32(values[index].count * MemoryLayout<Float>.size),
                                         mData: samples)
        }
    }

    func samples(_ index: Int = 0) -> [Float] {
        Array(UnsafeBufferPointer(start: storage[index],
                                  count: Int(buffers[index].mDataByteSize) / MemoryLayout<Float>.size))
    }

    deinit {
        for samples in storage { samples.deallocate() }
        free(pointer)
    }
}

final class DSPTests: XCTestCase {
    private func makeDSP(inputOffset: UInt32 = 0, inputInterleaved: Bool = true,
                         outputChannels: UInt32 = 2, outputInterleaved: Bool = true) throws -> OpaquePointer {
        try XCTUnwrap(StillDSPCreate(1_000, inputOffset, 2, inputInterleaved,
                                    outputChannels, outputInterleaved))
    }

    private func settle(_ dsp: OpaquePointer, channels: UInt32 = 2,
                        interleaved: Bool = true) {
        let input = BufferList([Array(repeating: 1, count: 10)], channels: [2])
        let values = interleaved ? [Array(repeating: Float(9), count: 5 * Int(channels))] :
            Array(repeating: Array(repeating: Float(9), count: 5), count: Int(channels))
        let output = BufferList(values, channels: interleaved ? [channels] : Array(repeating: 1, count: Int(channels)))
        XCTAssertEqual(StillDSPRender(dsp, input.pointer, output.pointer), noErr)
    }

    func testStereoIdentityAfterStartupRampAndAttenuation() throws {
        let dsp = try makeDSP()
        defer { StillDSPDestroy(dsp) }
        settle(dsp)
        let input = BufferList([[0.2, -0.4, 0.7, -0.9]], channels: [2])
        let output = BufferList([[9, 9, 9, 9]], channels: [2])
        XCTAssertEqual(StillDSPRender(dsp, input.pointer, output.pointer), noErr)
        XCTAssertEqual(output.samples(), input.samples())
        StillDSPSetGain(dsp, 0.25)
        settle(dsp)
        XCTAssertEqual(StillDSPRender(dsp, input.pointer, output.pointer), noErr)
        XCTAssertEqual(output.samples(), input.samples().map { $0 * 0.25 })
        XCTAssertEqual(StillDSPGetRenderCount(dsp), 4)
        XCTAssertEqual(StillDSPGetFaultCount(dsp), 0)
    }

    func testFiveMillisecondRampUsesSameGainForBothChannelsAndMutes() throws {
        let dsp = try makeDSP()
        defer { StillDSPDestroy(dsp) }
        let input = BufferList([Array(repeating: 1, count: 12)], channels: [2])
        let output = BufferList([Array(repeating: 9, count: 12)], channels: [2])
        XCTAssertEqual(StillDSPRender(dsp, input.pointer, output.pointer), noErr)
        let startup: [Float] = [0.2, 0.4, 0.6, 0.8, 1, 1]
        for index in startup.indices {
            XCTAssertEqual(output.samples()[index * 2], startup[index], accuracy: 0.000001)
            XCTAssertEqual(output.samples()[index * 2], output.samples()[index * 2 + 1])
        }
        StillDSPSetGain(dsp, 0)
        XCTAssertEqual(StillDSPRender(dsp, input.pointer, output.pointer), noErr)
        let muted: [Float] = [0.8, 0.6, 0.4, 0.2, 0, 0]
        for index in muted.indices {
            XCTAssertEqual(output.samples()[index * 2], muted[index], accuracy: 0.000001)
            XCTAssertEqual(output.samples()[index * 2], output.samples()[index * 2 + 1])
        }
    }

    func testRampContinuesAcrossCallbacksAndRetargetsFromCurrentGain() throws {
        let dsp = try makeDSP()
        defer { StillDSPDestroy(dsp) }
        let input = BufferList([[1, 1, 1, 1]], channels: [2])
        let output = BufferList([[9, 9, 9, 9]], channels: [2])
        XCTAssertEqual(StillDSPRender(dsp, input.pointer, output.pointer), noErr)
        XCTAssertEqual(output.samples()[2], 0.4, accuracy: 0.000001)
        XCTAssertEqual(StillDSPRender(dsp, input.pointer, output.pointer), noErr)
        XCTAssertEqual(output.samples()[0], 0.6, accuracy: 0.000001)
        StillDSPSetGain(dsp, 0.3)
        XCTAssertEqual(StillDSPRender(dsp, input.pointer, output.pointer), noErr)
        XCTAssertEqual(output.samples()[0], 0.7, accuracy: 0.000001)
        XCTAssertEqual(output.samples()[2], 0.6, accuracy: 0.000001)
    }

    func testMonoDownmix() throws {
        let dsp = try makeDSP(outputChannels: 1)
        defer { StillDSPDestroy(dsp) }
        settle(dsp, channels: 1)
        let input = BufferList([[0.4, 0.8, -0.6, 0.2]], channels: [2])
        let output = BufferList([[9, 9]], channels: [1])
        XCTAssertEqual(StillDSPRender(dsp, input.pointer, output.pointer), noErr)
        XCTAssertEqual(output.samples()[0], 0.6, accuracy: 0.000001)
        XCTAssertEqual(output.samples()[1], -0.2, accuracy: 0.000001)
    }

    func testSurroundOutputZerosEveryUnusedChannel() throws {
        for interleaved in [true, false] {
            let dsp = try makeDSP(outputChannels: 4, outputInterleaved: interleaved)
            defer { StillDSPDestroy(dsp) }
            settle(dsp, channels: 4, interleaved: interleaved)
            let input = BufferList([[0.2, 0.4, 0.6, 0.8]], channels: [2])
            let output = BufferList(interleaved ? [Array(repeating: 9, count: 8)] : Array(repeating: [9, 9], count: 4),
                                    channels: interleaved ? [4] : [1, 1, 1, 1])
            XCTAssertEqual(StillDSPRender(dsp, input.pointer, output.pointer), noErr)
            if interleaved {
                XCTAssertEqual(output.samples(), [0.2, 0.4, 0, 0, 0.6, 0.8, 0, 0])
            } else {
                XCTAssertEqual(output.samples(0), [0.2, 0.6])
                XCTAssertEqual(output.samples(1), [0.4, 0.8])
                XCTAssertEqual(output.samples(2), [0, 0])
                XCTAssertEqual(output.samples(3), [0, 0])
            }
        }
    }

    func testNoninterleavedInputAndPhysicalInputOffset() throws {
        for interleaved in [true, false] {
            let dsp = try makeDSP(inputOffset: 1, inputInterleaved: interleaved,
                                  outputInterleaved: false)
            defer { StillDSPDestroy(dsp) }
            let left: [Float] = [0.1, 0.2, 0.3, 0.4, 0.5]
            let right: [Float] = [-0.1, -0.2, -0.3, -0.4, -0.5]
            let stereo = zip(left, right).flatMap { [$0.0, $0.1] }
            let input = BufferList(interleaved ? [[99], stereo] : [[99], left, right],
                                   channels: interleaved ? [1, 2] : [1, 1, 1])
            let output = BufferList([Array(repeating: 9, count: 5), Array(repeating: 9, count: 5)],
                                    channels: [1, 1])
            XCTAssertEqual(StillDSPRender(dsp, input.pointer, output.pointer), noErr)
            XCTAssertEqual(StillDSPRender(dsp, input.pointer, output.pointer), noErr)
            XCTAssertEqual(output.samples(0), left)
            XCTAssertEqual(output.samples(1), right)
        }
    }

    func testInvalidInputAlwaysClearsOutputAndCountsOnlyFaults() throws {
        let dsp = try makeDSP()
        defer { StillDSPDestroy(dsp) }
        let inputs = [BufferList([[1, 2]], channels: [2]),
                      BufferList([[1, 2, 3, 4]], channels: [1]),
                      BufferList([[1, 2, 3]], channels: [2])]
        for input in inputs {
            let output = BufferList([[9, 9, 9, 9]], channels: [2])
            XCTAssertEqual(StillDSPRender(dsp, input.pointer, output.pointer), kAudio_ParamError)
            XCTAssertEqual(output.samples(), [0, 0, 0, 0])
        }
        XCTAssertEqual(StillDSPGetFaultCount(dsp), 3)
        XCTAssertEqual(StillDSPGetRenderCount(dsp), 0)
    }

    func testMissingOffsetBufferAndNullInputAreSilentFaults() throws {
        let dsp = try makeDSP(inputOffset: 1)
        defer { StillDSPDestroy(dsp) }
        let input = BufferList([[1, 1]], channels: [2])
        let output = BufferList([[9, 9]], channels: [2])
        XCTAssertEqual(StillDSPRender(dsp, input.pointer, output.pointer), kAudio_ParamError)
        XCTAssertEqual(output.samples(), [0, 0])
        XCTAssertEqual(StillDSPRender(dsp, nil, output.pointer), kAudio_ParamError)
        XCTAssertEqual(StillDSPGetFaultCount(dsp), 2)
    }

    func testNonfiniteGainSilencesImmediatelyAndFiniteGainRecovers() throws {
        let dsp = try makeDSP()
        defer { StillDSPDestroy(dsp) }
        settle(dsp)
        let input = BufferList([[1, 1]], channels: [2])
        for gain: Float in [.nan, .infinity, -.infinity] {
            let output = BufferList([[9, 9]], channels: [2])
            StillDSPSetGain(dsp, gain)
            XCTAssertEqual(StillDSPRender(dsp, input.pointer, output.pointer), kAudio_ParamError)
            XCTAssertEqual(output.samples(), [0, 0])
        }
        StillDSPSetGain(dsp, 1)
        let output = BufferList([[9, 9]], channels: [2])
        XCTAssertEqual(StillDSPRender(dsp, input.pointer, output.pointer), noErr)
        XCTAssertEqual(output.samples()[0], 0.2, accuracy: 0.000001)
        XCTAssertEqual(StillDSPGetFaultCount(dsp), 3)
        XCTAssertEqual(StillDSPGetRenderCount(dsp), 2)
    }

    func testGainClampsAndInactiveOutputIsIgnored() throws {
        let dsp = try makeDSP()
        defer { StillDSPDestroy(dsp) }
        StillDSPSetGain(dsp, 2)
        settle(dsp)
        let input = BufferList([[1, 1]], channels: [2])
        let output = BufferList([[9, 9]], channels: [2])
        XCTAssertEqual(StillDSPRender(dsp, input.pointer, output.pointer), noErr)
        XCTAssertEqual(output.samples(), [1, 1])
        StillDSPSetGain(dsp, -2)
        settle(dsp)
        XCTAssertEqual(StillDSPRender(dsp, input.pointer, output.pointer), noErr)
        XCTAssertEqual(output.samples(), [0, 0])
        let inactive = BufferList([[9, 9]], channels: [2])
        inactive.buffers[0].mData = nil
        XCTAssertEqual(StillDSPRender(dsp, nil, inactive.pointer), noErr)
        XCTAssertEqual(StillDSPGetRenderCount(dsp), 4)
        XCTAssertEqual(StillDSPGetFaultCount(dsp), 0)
    }

    func testInvalidConfigurationsAreRejected() {
        for rate in [Double.nan, .infinity, -1, 0, Double.greatestFiniteMagnitude] {
            XCTAssertNil(StillDSPCreate(rate, 0, 2, true, 2, true))
        }
        XCTAssertNil(StillDSPCreate(48_000, .max, 2, true, 2, true))
        XCTAssertNil(StillDSPCreate(48_000, 0, 1, true, 2, true))
        XCTAssertNil(StillDSPCreate(48_000, 0, 2, true, 0, true))
        XCTAssertNil(StillDSPCreate(48_000, 0, 2, true, .max, true))
    }

    func testMismatchedPlanarFramesAndMalformedOutputStaySilent() throws {
        let dsp = try makeDSP(inputInterleaved: false, outputInterleaved: false)
        defer { StillDSPDestroy(dsp) }
        let input = BufferList([[1, 1], [1]], channels: [1, 1])
        let output = BufferList([[9, 9], [9, 9]], channels: [1, 1])
        XCTAssertEqual(StillDSPRender(dsp, input.pointer, output.pointer), kAudio_ParamError)
        XCTAssertEqual(output.samples(0), [0, 0])
        XCTAssertEqual(output.samples(1), [0, 0])
        let validInput = BufferList([[1, 1], [1, 1]], channels: [1, 1])
        let badOutput = BufferList([[9, 9], [9]], channels: [1, 1])
        XCTAssertEqual(StillDSPRender(dsp, validInput.pointer, badOutput.pointer), kAudio_ParamError)
        XCTAssertEqual(badOutput.samples(0), [0, 0])
        XCTAssertEqual(badOutput.samples(1), [0])
        let disabledChannel = BufferList([[9, 9], [9, 9]], channels: [1, 1])
        disabledChannel.buffers[1].mData = nil
        XCTAssertEqual(StillDSPRender(dsp, validInput.pointer, disabledChannel.pointer), kAudio_ParamError)
        XCTAssertEqual(disabledChannel.samples(0), [0, 0])
        XCTAssertEqual(StillDSPGetFaultCount(dsp), 3)
        XCTAssertEqual(StillDSPGetRenderCount(dsp), 0)
    }

    func testCDeviceCallbackRendersWithOpaqueContext() throws {
        let dsp = try makeDSP()
        defer { StillDSPDestroy(dsp) }
        settle(dsp)
        let input = BufferList([[0.4, -0.7]], channels: [2])
        let output = BufferList([[9, 9]], channels: [2])
        var timestamp = AudioTimeStamp()
        withUnsafePointer(to: &timestamp) { time in
            XCTAssertEqual(StillDSPIOProc(0, time, input.pointer, time, output.pointer, time,
                                          UnsafeMutableRawPointer(dsp)), noErr)
        }
        XCTAssertEqual(output.samples(), input.samples())
    }

    func testDiagnosticMeteringIsDisabledByDefaultAndClearsWhenDisabled() throws {
        let dsp = try makeDSP()
        defer { StillDSPDestroy(dsp) }
        settle(dsp)
        XCTAssertEqual(StillDSPGetInputPeak(dsp), 0)
        XCTAssertEqual(StillDSPGetOutputPeak(dsp), 0)
        StillDSPSetMetering(dsp, true)
        settle(dsp)
        XCTAssertEqual(StillDSPGetInputPeak(dsp), 1)
        XCTAssertEqual(StillDSPGetOutputPeak(dsp), 1)
        StillDSPSetMetering(dsp, false)
        XCTAssertEqual(StillDSPGetInputPeak(dsp), 0)
        XCTAssertEqual(StillDSPGetOutputPeak(dsp), 0)
        settle(dsp)
        XCTAssertEqual(StillDSPGetInputPeak(dsp), 0)
        XCTAssertEqual(StillDSPGetOutputPeak(dsp), 0)
    }

    func testDiagnosticPeaksMeasureAttenuationMuteAndFaultSilence() throws {
        let dsp = try makeDSP()
        defer { StillDSPDestroy(dsp) }
        StillDSPSetMetering(dsp, true)
        StillDSPSetGain(dsp, 0.25)
        settle(dsp)
        let input = BufferList([[0.1, -0.5, -1, 0.8]], channels: [2])
        let output = BufferList([[9, 9, 9, 9]], channels: [2])
        XCTAssertEqual(StillDSPRender(dsp, input.pointer, output.pointer), noErr)
        XCTAssertEqual(StillDSPGetInputPeak(dsp), 1)
        XCTAssertEqual(StillDSPGetOutputPeak(dsp), 0.25)
        StillDSPSetGain(dsp, 0)
        settle(dsp)
        XCTAssertEqual(StillDSPRender(dsp, input.pointer, output.pointer), noErr)
        XCTAssertEqual(StillDSPGetInputPeak(dsp), 1)
        XCTAssertEqual(StillDSPGetOutputPeak(dsp), 0)
        StillDSPSetGain(dsp, 1)
        settle(dsp)
        XCTAssertEqual(StillDSPGetOutputPeak(dsp), 1)
        let invalid = BufferList([[1, 1]], channels: [2])
        XCTAssertEqual(StillDSPRender(dsp, invalid.pointer, output.pointer), kAudio_ParamError)
        XCTAssertEqual(StillDSPGetInputPeak(dsp), 0)
        XCTAssertEqual(StillDSPGetOutputPeak(dsp), 0)
    }

    func testDiagnosticOutputPeakMeasuresActualMonoDownmix() throws {
        let dsp = try makeDSP(outputChannels: 1)
        defer { StillDSPDestroy(dsp) }
        StillDSPSetMetering(dsp, true)
        settle(dsp, channels: 1)
        let input = BufferList([[1, -1, 0.5, -0.5]], channels: [2])
        let output = BufferList([[9, 9]], channels: [1])
        XCTAssertEqual(StillDSPRender(dsp, input.pointer, output.pointer), noErr)
        XCTAssertEqual(StillDSPGetInputPeak(dsp), 1)
        XCTAssertEqual(StillDSPGetOutputPeak(dsp), 0)
    }
}
