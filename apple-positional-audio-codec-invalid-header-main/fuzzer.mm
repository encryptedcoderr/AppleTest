#import <Foundation/Foundation.h>
#import <AVFAudio/AVFAudio.h>
#import <AudioToolbox/AudioToolbox.h>
#import <os/log.h>
#include <vector>
#include <random>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <fcntl.h>
#include <unistd.h>

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
        config->remappingChannelLayout->mChannelLayoutTag = kAudioChannelLayoutTag_Mono;
    }
    config->mRemappingArray.resize(512, 0xff);
}

void handleCrash(int sig) {
    FILE* logFile = fopen("fuzzer_crash.log", "a");
    if (logFile) {
        time_t now = time(NULL);
        fprintf(logFile, "Crash detected: Signal %d at %s", sig, ctime(&now));
        fclose(logFile);
    }
    fprintf(stderr, "Crash detected: Signal %d\n", sig);
    exit(1);
}

NSString* generateFuzzedAudio(NSString* inputPath, bool isMP3) {
    FILE* logFile = fopen("fuzzer_detail.log", "a");
    if (logFile) {
        time_t now = time(NULL);
        fprintf(logFile, "Generating fuzzed audio at %s", ctime(&now));
    }
    std::vector<double> sampleRates = {44100};
    std::vector<AudioFormatID> formats = {kAudioFormatMPEG4AAC};
    std::random_device rd;
    std::mt19937 gen(rd());
    std::uniform_int_distribution<> formatDist(0, formats.size() - 1);
    std::uniform_int_distribution<> rateDist(0, sampleRates.size() - 1);

    double sampleRate = sampleRates[rateDist(gen)];
    AudioFormatID formatID = formats[formatDist(gen)];
    uint32_t channelNum = 1;

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
        .mFormatFlags = 0,
        .mBytesPerPacket = 0,
        .mFramesPerPacket = 1024,
        .mBytesPerFrame = 0,
        .mChannelsPerFrame = channelNum,
        .mBitsPerChannel = 0,
        .mReserved = 0
    };

    AVAudioChannelLayout* channelLayout = [[AVAudioChannelLayout alloc] initWithLayoutTag:kAudioChannelLayoutTag_Mono];
    CodecConfig config;
    AudioChannelLayout* layoutCopy = (AudioChannelLayout*)malloc(sizeof(AudioChannelLayout));
    if (!layoutCopy) {
        if (logFile) {
            fprintf(logFile, "Memory allocation failed for rate %.0f\n", sampleRate);
            fclose(logFile);
        }
        fprintf(stderr, "Memory allocation failed for rate %.0f\n", sampleRate);
        return nil;
    }
    memcpy(layoutCopy, channelLayout.layout, sizeof(AudioChannelLayout));
    config.remappingChannelLayout = layoutCopy;
    OverrideApac(&config);

    NSString* fileName = [NSString stringWithFormat:@"fuzzed_%.0f_%u.%@", sampleRate, formatID, isMP3 ? @"mp3" : @"m4a"];
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
            fclose(logFile);
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
            fclose(logFile);
        }
        fprintf(stderr, "Error setting format (rate %.0f, format %u): %x\n", sampleRate, formatID, status);
        ExtAudioFileDispose(audioFile);
        free(layoutCopy);
        return nil;
    }

    status = ExtAudioFileSetProperty(audioFile, kExtAudioFileProperty_ClientChannelLayout,
                                     sizeof(AudioChannelLayout), formatIn.channelLayout.layout);
    if (status) {
        if (logFile) {
            fprintf(logFile, "Error setting layout (rate %.0f, format %u): %x\n", sampleRate, formatID, status);
            fclose(logFile);
        }
        fprintf(stderr, "Error setting layout (rate %.0f, format %u): %x\n", sampleRate, formatID, status);
        ExtAudioFileDispose(audioFile);
        free(layoutCopy);
        return nil;
    }

    float audioBuffer[1024];
    std::uniform_real_distribution<float> dis(-1.0f, 1.0f);
    for (int i = 0; i < 1024; ++i) {
        audioBuffer[i] = dis(gen) * 0.5f;
    }
    AudioBufferList bufferList = {
        .mNumberBuffers = 1,
        .mBuffers = {{.mNumberChannels = channelNum, .mDataByteSize = sizeof(audioBuffer), .mData = audioBuffer}}
    };
    status = ExtAudioFileWrite(audioFile, sizeof(audioBuffer) / sizeof(audioBuffer[0]), &bufferList);
    if (status) {
        if (logFile) {
            fprintf(logFile, "Error writing audio (rate %.0f, format %u): %x\n", sampleRate, formatID, status);
            fclose(logFile);
        }
        fprintf(stderr, "Error writing audio (rate %.0f, format %u): %x\n", sampleRate, formatID, status);
    }

    ExtAudioFileDispose(audioFile);
    free(layoutCopy);
    if (logFile) {
        fclose(logFile);
    }
    return tempPath;
}

NSMutableData* generateFuzzedBuffer(NSUInteger len) {
    NSMutableData *buffer = [NSMutableData dataWithLength:len];
    uint8_t *bytes = (uint8_t *)buffer.mutableBytes;

    for (NSUInteger i = 0; i < len; i++) {
        bytes[i] = rand() % 256;
    }

    int mutations = rand() % 5 + 3;
    for (int i = 0; i < mutations; i++) {
        NSUInteger offset = rand() % len;
        bytes[offset] = (rand() % 2) ? 0x00 : 0xFF;
    }

    return buffer;
}

void audioQueueCallback(void *userData, AudioQueueRef queue, AudioQueueBufferRef buffer) {
    FILE* logFile = fopen("fuzzer_detail.log", "a");
    if (logFile) {
        time_t now = time(NULL);
        fprintf(logFile, "AudioQueue callback at %s", ctime(&now));
    }
    NSMutableData *fuzzed = generateFuzzedBuffer(buffer->mAudioDataBytesCapacity);
    buffer->mAudioDataByteSize = fuzzed.length;
    memcpy(buffer->mAudioData, fuzzed.bytes, fuzzed.length);

    AudioStreamPacketDescription *packets = NULL;
    UInt32 numPackets = rand() % 5;
    if (numPackets) {
        packets = (AudioStreamPacketDescription*)malloc(numPackets * sizeof(AudioStreamPacketDescription));
        for (UInt32 i = 0; i < numPackets; i++) {
            packets[i].mStartOffset = rand() % buffer->mAudioDataByteSize;
            packets[i].mDataByteSize = rand() % (buffer->mAudioDataByteSize - packets[i].mStartOffset + 1);
            packets[i].mVariableFramesInPacket = rand() % 5;
        }
    }

    OSStatus status = AudioQueueEnqueueBuffer(queue, buffer, numPackets, packets);
    if (status != noErr) {
        if (logFile) {
            fprintf(logFile, "Enqueue failed: %d\n", (int)status);
            fclose(logFile);
        }
        fprintf(stderr, "Enqueue failed: %d\n", (int)status);
    }

    free(packets);
    if (logFile) {
        fclose(logFile);
    }
}

void fuzzAudioQueue(AudioQueueRef queue) {
    FILE* logFile = fopen("fuzzer_detail.log", "a");
    AudioQueueParameterID param = kAudioQueueParam_PlayRate;
    AudioQueueParameterValue rate = ((float)(rand() % 200 - 50) / 100.0f);
    if (logFile) {
        time_t now = time(NULL);
        fprintf(logFile, "Setting play rate: %f at %s", rate, ctime(&now));
        fclose(logFile);
    }
    AudioQueueSetParameter(queue, param, rate);
}

void fuzzAVAudioPlayer(AVAudioPlayer *player) {
    FILE* logFile = fopen("fuzzer_detail.log", "a");
    float rate = ((float)(rand() % 200 - 50) / 100.0f);
    if (logFile) {
        time_t now = time(NULL);
        fprintf(logFile, "Fuzzed rate: %f at %s", rate, ctime(&now));
    }
    fprintf(stderr, "-> Fuzzed rate: %f\n", rate);
    player.rate = rate;

    NSTimeInterval time = ((double)(rand() % 500) / 100.0);
    if (logFile) {
        fprintf(logFile, "Fuzzed time: %f\n", time);
    }
    fprintf(stderr, "-> Fuzzed time: %f\n", time);
    player.currentTime = time;

    if (rand() % 2) {
        if (logFile) {
            fprintf(logFile, "Playing and stopping player\n");
            fclose(logFile);
        }
        [player play];
        usleep(rand() % 20000);
        [player stop];
    } else if (logFile) {
        fclose(logFile);
    }
}

void fuzzMediaToolbox(NSString *path, NSError **err) {
    FILE* logFile = fopen("fuzzer_detail.log", "a");
    if (logFile) {
        time_t now = time(NULL);
        fprintf(logFile, "MediaToolbox fuzzing requires headers at %s", ctime(&now));
        fclose(logFile);
    }
    fprintf(stderr, "MediaToolbox fuzzing requires headers\n");
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        FILE* logFile = fopen("fuzzer_detail.log", "a");
        if (logFile) {
            time_t now = time(NULL);
            fprintf(logFile, "Starting fuzzing at %s", ctime(&now));
        }
        signal(SIGSEGV, handleCrash);
        signal(SIGABRT, handleCrash);
        signal(SIGILL, handleCrash);

        NSString *inputPath = @"output.m4a";
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

            bool isMP3 = false;
            NSString *tempPath = generateFuzzedAudio(inputPath, isMP3);
            if (!tempPath) {
                if (logFile) {
                    fprintf(logFile, "Failed to generate fuzzed audio\n");
                }
                fprintf(stderr, "Failed to generate fuzzed audio\n");
                continue;
            }

            AVAudioPlayer *player = [[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:tempPath] error:nil];
            if (player) {
                player.enableRate = YES;
                fuzzAVAudioPlayer(player);
                [player play];
                usleep(rand() % 50000);
                [player stop];
            } else {
                if (logFile) {
                    fprintf(logFile, "Player init failed for %s\n", tempPath.UTF8String);
                }
                fprintf(stderr, "Player init failed for %s\n", tempPath.UTF8String);
            }

            AudioStreamBasicDescription desc = {
                .mSampleRate = 44100,
                .mFormatID = kAudioFormatLinearPCM,
                .mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                .mBitsPerChannel = 16,
                .mChannelsPerFrame = 1,
                .mFramesPerPacket = 1,
                .mBytesPerFrame = 2,
                .mBytesPerPacket = 2
            };
            AudioQueueRef queue;
            OSStatus status = AudioQueueNewOutput(&desc, audioQueueCallback, NULL, CFRunLoopGetCurrent(), kCFRunLoopCommonModes, 0, &queue);
            if (status != noErr) {
                if (logFile) {
                    fprintf(logFile, "Queue creation failed: %d\n", (int)status);
                }
                fprintf(stderr, "Queue creation failed: %d\n", (int)status);
                continue;
            }

            for (int j = 0; j < 3; j++) {
                AudioQueueBufferRef buffer;
                UInt32 size = rand() % 100000 + 500;
                if (AudioQueueAllocateBuffer(queue, size, &buffer) == noErr) {
                    audioQueueCallback(NULL, queue, buffer);
                }
            }

            fuzzAudioQueue(queue);
            AudioQueueStart(queue, NULL);
            usleep(rand() % 50000);
            AudioQueueStop(queue, true);
            AudioQueueDispose(queue, true);

            fuzzMediaToolbox(tempPath, nil);

            [[NSFileManager defaultManager] removeItemAtPath:tempPath error:nil];

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
