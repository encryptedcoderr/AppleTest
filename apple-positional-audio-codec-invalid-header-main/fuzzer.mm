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
    config->remappingChannelLayout->mChannelLayoutTag = kAudioChannelLayoutTag_HOA_ACN_SN3D | 0x3; // Order 1, 4 channels
  }
  config->mRemappingArray.resize(1024, 0xff);
}

NSString* generateFuzzedAudio(NSString* inputPath, bool isMP3, FILE* logFile) {
  if (logFile) {
    time_t now = time(NULL);
    fprintf(logFile, "Generating fuzzed audio at %s", ctime(&now));
  }
  std::vector<double> sampleRates = {16000, 44100, 48000, 96000};
  std::vector<AudioFormatID> formats = {kAudioFormatMPEG4AAC, kAudioFormatLinearPCM};
  std::random_device rd;
  std::mt19937 gen(rd());
  std::uniform_int_distribution<> formatDist(0, formats.size() - 1);
  std::uniform_int_distribution<> rateDist(0, sampleRates.size() - 1);
  std::uniform_real_distribution<float> volumeDis(0.0f, 2.0f); // Fuzz volume for SoftwareVolume
  std::uniform_int_distribution<> channelFuzz(3, 5); // Fuzz channel count around 4

  double sampleRate = sampleRates[rateDist(gen)];
  AudioFormatID formatID = formats[formatDist(gen)];
  uint32_t channelNum = channelFuzz(gen); // Fuzz channel count to stress layout handling

  if (logFile) {
    fprintf(logFile, "Params: sampleRate=%.0f, formatID=%u, channels=%u, isMP3=%d\n", 
            sampleRate, formatID, channelNum, isMP3);
  }
  fprintf(stderr, "Generating fuzzed audio: sampleRate=%.0f, formatID=%u, channels=%u, isMP3=%d\n", 
          sampleRate, formatID, channelNum, isMP3);

  AVAudioFormat* formatIn = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:sampleRate channels:channelNum];
  AudioStreamBasicDescription outputDesc = {
      .mSampleRate = sampleRate,
      .mFormatID = formatID,
      .mFormatFlags = (formatID == kAudioFormatLinearPCM) ? kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked : 0,
      .mBytesPerPacket = (formatID == kAudioFormatLinearPCM) ? 4 * channelNum : 0,
      .mFramesPerPacket = (formatID == kAudioFormatMPEG4AAC) ? 1024 : 1,
      .mBytesPerFrame = (formatID == kAudioFormatLinearPCM) ? 4 * channelNum : 0,
      .mChannelsPerFrame = channelNum,
      .mBitsPerChannel = (formatID == kAudioFormatLinearPCM) ? 32 : 0,
      .mReserved = 0
  };

  AVAudioChannelLayout* channelLayout = [[AVAudioChannelLayout alloc] initWithLayoutTag:kAudioChannelLayoutTag_HOA_ACN_SN3D | 0x3];
  CodecConfig config;
  AudioChannelLayout* layoutCopy = (AudioChannelLayout*)malloc(sizeof(AudioChannelLayout) + sizeof(AudioChannelDescription) * channelNum);
  if (!layoutCopy) {
    if (logFile) {
      fprintf(logFile, "Memory allocation failed for rate %.0f\n", sampleRate);
    }
    fprintf(stderr, "Memory allocation failed for rate %.0f\n", sampleRate);
    return nil;
  }
  memcpy(layoutCopy, channelLayout.layout, sizeof(AudioChannelLayout) + sizeof(AudioChannelDescription) * channelNum);
  config.remappingChannelLayout = layoutCopy;
  OverrideApac(&config);

  NSString* fileName = [NSString stringWithFormat:@"fuzzed_%.0f_%u_%u.%@", sampleRate, formatID, channelNum, isMP3 ? @"mp3" : @"m4a"];
  NSString* tempPath = [NSTemporaryDirectory() stringByAppendingPathComponent:fileName];
  NSURL* outUrl = [NSURL fileURLWithPath:tempPath];

  if (logFile) {
    fprintf(logFile, "Creating file at path: %s\n", tempPath.UTF8String);
  }
  fprintf(stderr, "Creating file at path: %s\n", tempPath.UTF8String);

  ExtAudioFileRef audioFile = nullptr;
  OSStatus status = ExtAudioFileCreateWithURL((__bridge CFURLRef)outUrl,
                                             isMP3 ? kAudioFileMP3Type : kAudioFileM4AType,
                                             &outputDesc, config.remappingChannelLayout,
                                             kAudioFileFlags_EraseFile, &audioFile);
  if (status) {
    if (logFile) {
      fprintf(logFile, "Error creating file (rate %.0f, format %u): %x\n", sampleRate, formatID, status);
    }
    fprintf(stderr, "Error creating file (rate %.0f, format %u): %x\n", sampleRate, formatID, status);
    free(layoutCopy);
    return nil;
  }

  status = ExtAudioFileSetProperty(audioFile, kExtAudioFileProperty_ClientDataFormat,
                                   sizeof(AudioStreamBasicDescription), formatIn.streamDescription);
  if (status) {
    if (logFile) {
      fprintf(logFile, "Error setting format (rate %.0f, format %u): %x\n", sampleRate, formatID, status);
    }
    fprintf(stderr, "Error setting format (rate %.0f, format %u): %x\n", sampleRate, formatID, status);
    ExtAudioFileDispose(audioFile);
    free(layoutCopy);
    return nil;
  }

  status = ExtAudioFileSetProperty(audioFile, kExtAudioFileProperty_ClientChannelLayout,
                                   sizeof(AudioChannelLayout) + sizeof(AudioChannelDescription) * channelNum, formatIn.channelLayout.layout);
  if (status) {
    if (logFile) {
      fprintf(logFile, "Error setting layout (rate %.0f, format %u): %x\n", sampleRate, formatID, status);
    }
    fprintf(stderr, "Error setting layout (rate %.0f, format %u): %x\n", sampleRate, formatID, status);
    ExtAudioFileDispose(audioFile);
    free(layoutCopy);
    return nil;
  }

  // Fuzz audio buffer with extreme values to stress FigRenderPipeline
  float audioBuffer[1024 * channelNum];
  std::uniform_real_distribution<float> dis(-2.0f, 2.0f); // Exceed normal range
  for (int i = 0; i < 1024 * channelNum; ++i) {
    audioBuffer[i] = dis(gen);
    if (rand() % 100 < 5) { // 5% chance of extreme values
      audioBuffer[i] = (rand() % 2) ? std::numeric_limits<float>::infinity() : -std::numeric_limits<float>::infinity();
    }
  }
  // Apply fuzzed volume scaling
  float volumeFactor = volumeDis(gen);
  for (int i = 0; i < 1024 * channelNum; ++i) {
    audioBuffer[i] *= volumeFactor;
  }

  AudioBufferList bufferList = {
      .mNumberBuffers = 1,
      .mBuffers = {{.mNumberChannels = channelNum, .mDataByteSize = sizeof(audioBuffer), .mData = audioBuffer}}
  };
  status = ExtAudioFileWrite(audioFile, 1024, &bufferList);
  if (status) {
    if (logFile) {
      fprintf(logFile, "Error writing audio (rate %.0f, format %u): %x\n", sampleRate, formatID, status);
    }
    fprintf(stderr, "Error writing audio (rate %.0f, format %u): %x\n", sampleRate, formatID, status);
  }

  ExtAudioFileDispose(audioFile);
  free(layoutCopy);
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
      if (logFile) {
        fprintf(logFile, "Using input path: %s\n", inputPath.UTF8String);
      }
    }

    int iterations = 5;
    if (argc > 2) {
      iterations = atoi(argv[2]);
      if (logFile) {
        fprintf(logFile, "Setting iterations: %d\n", iterations);
      }
    }

    for (int i = 0; i < iterations; i++) {
      if (logFile) {
        time_t now = time(NULL);
        fprintf(logFile, "Iteration %d/%d at %s", i + 1, iterations, ctime(&now));
      }
      fprintf(stderr, "Iteration %d/%d\n", i + 1, iterations);

      // Generate fuzzed .m4a
      NSString *tempPathM4A = generateFuzzedAudio(inputPath, false, logFile);
      if (!tempPathM4A) {
        if (logFile) {
          fprintf(logFile, "Failed to generate fuzzed .m4a\n");
        }
        fprintf(stderr, "Failed to generate fuzzed .m4a\n");
      }

      // Generate fuzzed .mp3
      NSString *tempPathMP3 = generateFuzzedAudio(inputPath, true, logFile);
      if (!tempPathMP3) {
        if (logFile) {
          fprintf(logFile, "Failed to generate fuzzed .mp3\n");
        }
        fprintf(stderr, "Failed to generate fuzzed .mp3\n");
      }

      if (logFile) {
        fprintf(logFile, "Completed iteration %d\n", i + 1);
      }
      fprintf(stderr, "Completed iteration %d\n", i + 1);
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
