import AVFoundation
import Foundation
import CoreMedia

func generateBaseM4A(filename: String, duration: Double, channels: Int, sampleRate: Double) throws {
    let outputURL = URL(fileURLWithPath: filename)

    // Create an INTERLEAVED audio format for PCM input
    // This simplifies creating the CMBlockBuffer later.
    guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                     sampleRate: sampleRate,
                                     channels: UInt32(channels),
                                     interleaved: true) else {
        throw NSError(domain: "AVAudioFormatError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create AVAudioFormat"])
    }
    
    let frameCount = UInt32(duration * sampleRate)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
        throw NSError(domain: "AVAudioPCMBufferError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create AVAudioPCMBuffer"])
    }
    buffer.frameLength = frameCount

    // Fill with silence (zeros)
    // For interleaved float data, floatChannelData![0] points to the start of the buffer.
    if let interleavedData = buffer.floatChannelData?[0] {
        let byteCount = Int(frameCount) * Int(format.channelCount) * MemoryLayout<Float>.size
        memset(interleavedData, 0, byteCount)
    } else {
         throw NSError(domain: "AVAudioPCMBufferError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to get floatChannelData"])
    }

    // Create AVAssetWriter
    let writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC, // Output format is AAC
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: channels,
        AVEncoderBitRateKey: 128000 // Example bitrate
    ]
    let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
    
    guard writer.canAdd(audioInput) else {
        throw NSError(domain: "AVAssetWriterError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Cannot add AVAssetWriterInput"])
    }
    writer.add(audioInput)

    // Start writing session
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)

    // --- Convert AVAudioPCMBuffer to CMSampleBuffer ---
    var formatDesc: CMAudioFormatDescription?
    guard let asbd = format.streamDescription else {
        throw NSError(domain: "AVAudioFormatError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to get stream description"])
    }
    CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                   asbd: asbd,
                                   layoutSize: 0,
                                   layout: nil,
                                   magicCookieSize: 0,
                                   magicCookie: nil,
                                   extensions: nil,
                                   formatDescriptionOut: &formatDesc)
    
    guard formatDesc != nil else {
        throw NSError(domain: "CMSampleBufferError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create CMAudioFormatDescription"])
    }

    var sampleBuffer: CMSampleBuffer?
    // Total length of the audio data in bytes for the interleaved buffer
    let blockBufferLength = Int(frameCount) * Int(format.channelCount) * MemoryLayout<Float>.size
    var blockBuffer: CMBlockBuffer?

    // Create CMBlockBuffer from the AVAudioPCMBuffer's data
    // For interleaved data, floatChannelData![0] points to the start of the single buffer.
    guard let memoryBlockPointer = buffer.floatChannelData?[0] else {
         throw NSError(domain: "AVAudioPCMBufferError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to access memory block from AVAudioPCMBuffer"])
    }

    CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
                                       memoryBlock: UnsafeMutableRawPointer(mutating: memoryBlockPointer), // Cast to UnsafeMutableRawPointer
                                       blockLength: blockBufferLength,
                                       blockAllocator: kCFAllocatorNull, // We are not using a custom allocator for the block
                                       customBlockSource: nil,
                                       offsetToData: 0,
                                       dataLength: blockBufferLength,
                                       flags: 0, // kCMBlockBufferAssureMemoryNowFlag can be useful
                                       blockBufferOut: &blockBuffer)

    guard blockBuffer != nil else {
        throw NSError(domain: "CMSampleBufferError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create CMBlockBuffer"])
    }
    
    // Frame duration: 1 / sampleRate
    // Number of samples per buffer: frameCount (which is total samples in this buffer)
    let sampleDuration = CMTime(value: 1, timescale: Int32(sampleRate))
    var timing = CMSampleTimingInfo(duration: sampleDuration,
                                    presentationTimeStamp: .zero, // First buffer starts at time zero
                                    decodeTimeStamp: .invalid) // Decode time is not relevant here

    CMSampleBufferCreate(allocator: kCFAllocatorDefault,
                         dataBuffer: blockBuffer, // The CMBlockBuffer containing our audio data
                         dataReady: true,
                         makeDataReadyCallback: nil,
                         refcon: nil,
                         formatDescription: formatDesc!, // The audio format description
                         sampleCount: CMItemCount(frameCount), // Number of samples in this buffer
                         sampleTimingEntryCount: 1,
                         sampleTimingArray: &timing, // Pointer to the timing info
                         sampleSizeEntryCount: 0,    // For uncompressed audio, sample sizes can be derived from formatDesc
                         sampleSizeArray: nil,
                         sampleBufferOut: &sampleBuffer)

    guard sampleBuffer != nil else {
        throw NSError(domain: "CMSampleBufferError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create CMSampleBuffer"])
    }
    // --- End of Conversion ---

    // Append the CMSampleBuffer
    // Wait until the input is ready for more media data
    while !audioInput.isReadyForMoreMediaData {
        Thread.sleep(forTimeInterval: 0.01) // Sleep briefly
    }
    audioInput.append(sampleBuffer!)
    
    audioInput.markAsFinished()
    
    let writingGroup = DispatchGroup()
    writingGroup.enter()
    writer.finishWriting {
        if writer.status == .failed {
            print("Error finishing writing: \(writer.error?.localizedDescription ?? "Unknown error")")
        } else if writer.status == .completed {
            print("Successfully generated \(filename)")
        }
        writingGroup.leave()
    }
    
    writingGroup.wait() // Wait for finishWriting to complete

    if writer.status == .failed {
        throw writer.error ?? NSError(domain: "AVAssetWriter", code: -2, userInfo: [NSLocalizedDescriptionKey: "Writer failed after finishWriting called"])
    }
}

func main() {
    print("Generating base M4A files at \(Date())")
    let sampleRate = 44100.0
    let duration = 1.0 // 1 second
    let channels = 2   // Stereo
    
    for i in 1...5 {
        let filename = "base_poc\(i).m4a"
        do {
            try generateBaseM4A(filename: filename, duration: duration, channels: channels, sampleRate: sampleRate)
        } catch {
            print("Error generating \(filename): \(error.localizedDescription)")
            // Decide if you want to exit(1) on first error or try all
            // exit(1) 
        }
    }
    print("Finished generating files.")
}

main()
