import AVFoundation
import Foundation
import CoreMedia

func generateBaseM4A(filename: String, duration: Double, channels: Int, sampleRate: Double) throws {
    let outputURL = URL(fileURLWithPath: filename)
    
    // Create audio format for PCM input
    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: UInt32(channels))!
    let frameCount = UInt32(duration * sampleRate)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
    buffer.frameLength = frameCount
    
    // Fill with silence (zeros)
    if let floatData = buffer.floatChannelData {
        for channel in 0..<Int(format.channelCount) {
            memset(floatData[channel], 0, Int(frameCount) * MemoryLayout<Float>.size)
        }
    }
    
    // Create AVAssetWriter
    let writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: channels,
        AVEncoderBitRateKey: 128000
    ]
    let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
    writer.add(audioInput)
    
    // Start writing
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)
    
    // Convert AVAudioPCMBuffer to CMSampleBuffer
    var formatDesc: CMAudioFormatDescription?
    let asbd = format.streamDescription
    CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                  asbd: asbd,
                                  layoutSize: 0,
                                  layout: nil,
                                  magicCookieSize: 0,
                                  magicCookie: nil,
                                  extensions: nil,
                                  formatDescriptionOut: &formatDesc)
    
    var sampleBuffer: CMSampleBuffer?
    let blockBufferLength = Int(frameCount) * Int(format.channelCount) * MemoryLayout<Float>.size
    var blockBuffer: CMBlockBuffer?
    CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
                                      memoryBlock: buffer.floatChannelData![0],
                                      blockLength: blockBufferLength,
                                      blockAllocator: kCFAllocatorNull,
                                      customBlockSource: nil,
                                      offsetToData: 0,
                                      dataLength: blockBufferLength,
                                      flags: 0,
                                      blockBufferOut: &blockBuffer)
    
    let timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(sampleRate)),
                                   presentationTimeStamp: .zero,
                                   decodeTimeStamp: .invalid)
    
    CMSampleBufferCreate(allocator: kCFAllocatorDefault,
                        dataBuffer: blockBuffer,
                        dataReady: true,
                        makeDataReadyCallback: nil,
                        refcon: nil,
                        formatDescription: formatDesc,
                        sampleCount: CMItemCount(frameCount),
                        sampleTimingEntryCount: 1,
                        sampleTimingArray: [timing],
                        sampleSizeEntryCount: 0,
                        sampleSizeArray: nil,
                        sampleBufferOut: &sampleBuffer)
    
    // Append to writer
    audioInput.append(sampleBuffer!)
    audioInput.markAsFinished()
    writer.finishWriting {
        print("Generated \(filename)")
    }
    
    // Wait for completion
    while writer.status == .writing {
        Thread.sleep(forTimeInterval: 0.1)
    }
    if writer.status == .failed {
        throw writer.error ?? NSError(domain: "AVAssetWriter", code: -1, userInfo: nil)
    }
}

func main() {
    let sampleRate = 44100.0
    let duration = 1.0 // 1 second
    let channels = 2
    
    for i in 1...5 {
        let filename = "base_poc\(i).m4a"
        do {
            try generateBaseM4A(filename: filename, duration: duration, channels: channels, sampleRate: sampleRate)
        } catch {
            print("Error generating \(filename): \(error)")
            exit(1)
        }
    }
}

main()
