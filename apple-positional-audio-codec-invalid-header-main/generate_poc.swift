import AVFoundation
import Foundation

func generateBaseM4A(filename: String, duration: Double, channels: Int, sampleRate: Double) throws {
    let outputURL = URL(fileURLWithPath: filename)
    
    // Create a silent audio buffer
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
    
    // Create an AVAssetWriter
    let writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: channels,
        AVEncoderBitRateKey: 128000
    ]
    let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
    writer.add(audioInput)
    
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)
    
    audioInput.append(buffer)
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
