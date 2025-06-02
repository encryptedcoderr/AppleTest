#import <Foundation/Foundation.h>
#import <AVFAudio/AVFAudio.h>
#import <AudioToolbox/AudioToolbox.h>
#include <vector>
#include <random>
#include <stdio.h>
#include <stdlib.h>
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
    config->remappingChannelLayout->mChannelLayoutTag = kAudioChannelLayoutTag_HOA_ACN_SN3D | (rand() % 0x20);
    fprintf(stderr, "Fuzzer: Set channel layout tag to 0x%x\n", config->remappingChannelLayout->mChannelLayoutTag);
  }
  config->mRemappingArray.resize(2048 + (rand() % 2048), static_cast<char>(rand() % 256));
}

NSString* generateFuzzedAudio(NSString* inputPath, bool isMP3, FILE* logFile) {
  if (logFile) {
    time_t now = time(NULL);
    fprintf(logFile, "Fuzzing audio at %s", ctime(&now));
  }
  std::vector<double> sampleRates = {8000, 16000, 44100, 48000, 96000, 192000}; // Extreme rates
  std::vector<AudioFormatID> formats = {kAudioFormatMPEG4AAC, kAudioFormatLinearPCM, kAudioFormatMPEG4AAC_HE};
  std::random_device rd;
  std::mt19937 gen(rd());
  std::uniform_int_distribution<> formatDist(0, formats.size() - 1);
  std::uniform_int_distribution<> rateDist(0, sampleRates.size() - 1);
  std::uniform_real_distribution<float> volumeDis(-10.0f, 10.0f);
  std::uniform_int_distribution<> channelFuzz(1, 16); // Wide channel range

  double sampleRate = sampleRates[rateDist(gen)];
  AudioFormatID formatID = formats[formatDist(gen)];
  uint32_t channelNum = channelFuzz(gen);

  if (logFile) {
    fprintf(logFile, "Params: sampleRate=%.0f, formatID=%u, channels=%u, isMP3=%d\n", 
            sampleRate, formatID, channelNum, isMP3);
  }
  fprintf(stderr, "Fuzzing: sampleRate=%.0f, formatID=%u, channels=%u, isMP3=%d\n", 
          sampleRate, formatID, channelNum, isMP3);

  AVAudioFormat* formatIn = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:sampleRate channels:channelNum];
  if (!formatIn) {
    if (logFile) fprintf(logFile, "Failed AVAudioFormat for rate %.0f\n", sampleRate);
    fprintf(stderr, "Failed AVAudioFormat for rate %.0f\n", sampleRate);
    return nil;
  }

  AudioStreamBasicDescription outputDesc = {
      .mSampleRate = sampleRate,
      .mFormatID = formatID,
      .mFormatFlags = (formatID == kAudioFormatLinearPCM) ? kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked : (rand() % 0xFF), // Random flags
      .mBytesPerPacket = (formatID == kAudioFormatLinearPCM) ? 4 * channelNum : (rand() % 100),
      .mFramesPerPacket = static_cast<UInt32>((formatID == kAudioFormatMPEG4AAC) ? 1024 : (rand() % 2048)),
      .mBytesPerFrame = (formatID == kAudioFormatLinearPCM) ? 4 * channelNum : (rand() % 100),
      .mChannelsPerFrame = channelNum,
      .mBitsPerChannel = static_cast<UInt32>((formatID == kAudioFormatLinearPCM) ? 32 : (rand() % 64)),
      .mReserved = rand()
  };

  AVAudioChannelLayout* channelLayout = [[AVAudioChannelLayout alloc] initWithLayoutTag:kAudioChannelLayoutTag_HOA_ACN_SN3D | (rand() % 0x20)];
  if (!channelLayout || !channelLayout.layout) {
    if (logFile) fprintf(logFile, "Failed channel layout for rate %.0f\n", sampleRate);
    fprintf(stderr, "Failed channel layout for rate %.0f\n", sampleRate);
    return nil;
  }

  CodecConfig config;
  size_t layoutSize = sizeof(AudioChannelLayout) + sizeof(AudioChannelDescription) * (channelNum + (rand() % 20));
  AudioChannelLayout* layoutCopy = (AudioChannelLayout*)calloc(1, layoutSize);
  if (!layoutCopy) {
    if (logFile) fprintf(logFile, "Memory allocation failed for rate %.0f\n", sampleRate);
    fprintf(stderr, "Memory allocation failed for rate %.0f\n", sampleRate);
    return nil;
  }
  memcpy(layoutCopy, channelLayout.layout, layoutSize);
  config.remappingChannelLayout = layoutCopy;
  fprintf(stderr, "Fuzzer: Allocated channel layout for rate %.0f\n", sampleRate);

  OverrideApac(&config);

  NSString* fileName = [NSString stringWithFormat:@"fuzzed_%.0f_%u_%u.%@", sampleRate, formatID, channelNum, isMP3 ? @"mp3" : @"m4a"];
  NSString* tempPath = [NSTemporaryDirectory() stringByAppendingPathComponent:fileName];
  NSURL* outUrl = [NSURL fileURLWithPath:tempPath];

  if (logFile) {
    fprintf(logFile, "Creating file: %s\n", tempPath.UTF8String);
  }
  fprintf(stderr, "Fuzzer: Creating file: %s\n", tempPath.UTF8String);

  ExtAudioFileRef audioFile = nullptr;
  OSStatus status = ExtAudioFileCreateWithURL((__bridge CFURLRef)outUrl,
                                             isMP3 ? kAudioFileMP3Type : kAudioFileM4AType,
                                             &outputDesc, config.remappingChannelLayout,
                                             kAudioFileFlags_EraseFile, &audioFile);
  if (status != noErr) {
    if (logFile) fprintf(logFile, "Error creating file (rate %.0f, format %u): %x\n", sampleRate, formatID, status);
    fprintf(stderr, "Error creating file (rate %.0f, format %u): %x\n", sampleRate, formatID, status);
    free(layoutCopy);
    return nil;
  }

  // Malformed metadata
  NSDictionary *metadata = @{
    @"com.apple.metadata.spatial" : @(rand() % 0xFFFF),
    @"channel_layout" : @(rand() % 0xFFFF)
  };
  AudioFileSetProperty(audioFile, kAudioFilePropertyInfoDictionary, sizeof(metadata), &metadata);

  status = ExtAudioFileSetProperty(audioFile, kExtAudioFileProperty_ClientDataFormat,
                                   sizeof(AudioStreamBasicDescription), formatIn.streamDescription);
  if (status != noErr) {
    if (logFile) fprintf(logFile, "Error setting format (rate %.0f, format %u): %x\n", sampleRate, formatID, status);
    fprintf(stderr, "Error setting format (rate %.0f, format %u): %x\n", sampleRate, formatID, status);
    ExtAudioFileDispose(audioFile);
    free(layoutCopy);
    return nil;
  }

  status = ExtAudioFileSetProperty(audioFile, kExtAudioFileProperty_ClientChannelLayout,
                                   layoutSize, formatIn.channelLayout.layout);
  if (status != noErr) {
    if (logFile) fprintf(logFile, "Error setting layout (rate %.0f, format %u): %x\n", sampleRate, formatID, status);
    fprintf(stderr, "Error setting layout (rate %.0f, format %u): %x\n", sampleRate, formatID, status);
    ExtAudioFileDispose(audioFile);
    free(layoutCopy);
    return nil;
  }

  float* audioBuffer = new float[1024 * channelNum];
  if (!audioBuffer) {
    if (logFile) fprintf(logFile, "Failed to allocate audio buffer for rate %.0f\n", sampleRate);
    fprintf(stderr, "Failed to allocate audio buffer for rate %.0f\n", sampleRate);
    ExtAudioFileDispose(audioFile);
    free(layoutCopy);
    return nil;
  }
  std::uniform_real_distribution<float> dis(-100.0f, 100.0f);
  for (size_t i = 0; i < 1024 * channelNum; ++i) {
    audioBuffer[i] = dis(gen);
    if (rand() % 100 < 20) {
      audioBuffer[i] = (rand() % 2) ? std::numeric_limits<float>::infinity() : std::numeric_limits<float>::quiet_NaN();
    }
  }
  float volumeFactor = volumeDis(gen);
  for (size_t i = 0; i < 1024 * channelNum; ++i) {
    audioBuffer[i] *= volumeFactor;
  }
  fprintf(stderr, "Fuzzer: Filled audio buffer for rate %.0f\n", sampleRate);

  AudioBufferList bufferList = {
      .mNumberBuffers = 1 + (rand() % 3), // Multiple buffers
      .mBuffers = {{.mNumberChannels = channelNum, .mDataByteSize = static_cast<UInt32>(1024 * channelNum * sizeof(float) + (rand() % 2000)), .mData = audioBuffer}}
  };
  status = ExtAudioFileWrite(audioFile, 1024 + (rand() % 1000), &bufferList);
  if (status != noErr) {
    if (logFile) fprintf(logFile, "Error writing audio (rate %.0f, format %u): %x\n", sampleRate, formatID, status);
    fprintf(stderr, "Error writing audio (rate %.0f, format %u): %x\n", sampleRate, formatID, status);
  }

  ExtAudioFileDispose(audioFile);
  delete[] audioBuffer;
  free(layoutCopy);
  fprintf(stderr, "Fuzzer: Completed processing for rate %.0f\n", sampleRate);
  return tempPath;
}

int main(int argc, char *argv[]) {
  @autoreleasepool {
    FILE* logFile = fopen("fuzzer_detail.log", "a");
    if (logFile) {
      time_t now = time(NULL);
      fprintf(logFile, "Starting fuzzing at %s", ctime(&now));
    }

    NSString *inputPath = @"output_44100_1635013121.m4a";
    if (argc > 1) {
      inputPath = @(argv[1]);
      if (logFile) fprintf(logFile, "Input path: %s\n", inputPath.UTF8String);
    }

    int iterations = 20; // More iterations
    if (argc > 2) {
      iterations = atoi(argv[2]);
      if (logFile) fprintf(logFile, "Iterations: %d\n", iterations);
    }

    for (int i = 0; i < iterations; i++) {
      if (logFile) fprintf(logFile, "Iteration %d/%d\n", i + 1, iterations);
      fprintf(stderr, "Fuzzer: Iteration %d/%d\n", i + 1, iterations);

      NSString *tempPathM4A = generateFuzzedAudio(inputPath, false, logFile);
      NSString *tempPathMP3 = generateFuzzedAudio(inputPath, true, logFile);

      if (logFile) fprintf(logFile, "Completed iteration %d\n", i + 1);
    }

    if (logFile) {
      time_t now = time(NULL);
      fprintf(logFile, "Fuzzing completed at %s", ctime(&now));
      fclose(logFile);
    }
    fprintf(stderr, "Fuzzing completed\n");
  }
  return 0;
}
