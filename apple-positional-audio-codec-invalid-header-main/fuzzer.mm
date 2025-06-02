// Fuzzer.mm
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#include <vector>
#include <random>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <fcntl.h>
#include <unistd.h>

// Hypothetical MediaToolbox imports (requires reverse-engineered headers)
// #import <MediaToolbox/FigFilePlayer.h>
// #import <MediaToolbox/FigAudioQueue.h>

// CodecConfig structure
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

// Override channel layout
void OverrideApac(CodecConfig* config) {
    if (config->remappingChannelLayout) {
        config->remappingChannelLayout->mChannelLayoutTag = kAudioChannelLayoutTag_HOA_ACN_SN3D | 0x8;
    }
    config->mRemappingArray.resize(0x10000, 0xff);
}

// Crash handler
void handleCrash(int sig) {
    fprintf(stderr, "Crash detected: Signal %d\n", sig);
    exit(1);
}

// Generate fuzzed audio file (M4A or MP3)
NSString* generateFuzzedAudio(NSString* inputPath, bool isMP3) {
    std::vector<double> sampleRates = {8000, 16000, 44100, 48000, 96000};
    std::vector<AudioFormatID> formats = {kAudioFormatMPEG4AAC, kAudioFormatLinearPCM, kAudioFormatMPEG4AAC};
    std::random_device rd;
    std::mt19937 gen(rd());
    std::uniform_int_distribution<> formatDist(0, formats.size() - 1);
    std::uniform_int_distribution<> rateDist(0, sampleRates.size() - 1);

    double sampleRate = sampleRates[rateDist(gen)];
    AudioFormatID formatID = formats[formatDist(gen)];
    uint32_t channelNum = 1 + (rand() % 2); // 1 or 2 channels

    // Input format
    AVAudioFormat* formatIn = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:sampleRate channels:channelNum];
    AudioStreamBasicDescription outputDesc = {
        .mSampleRate = sampleRate,
        .mFormatID = formatID,
        .mFormatFlags = (formatID == kAudioFormatLinearPCM) ? kAudioFormatFlagIsFloat : 0,
        .mBytesPerPacket = 0,
        .mFramesPerPacket = 0,
        .mBytesPerFrame = 0,
        .mChannelsPerFrame = channelNum,
        .mBitsPerChannel = 0,
        .mReserved = 0
    };

    // Channel layout
    AVAudioChannelLayout* channelLayout = [[AVAudioChannelLayout alloc] initWithLayoutTag:kAudioChannelLayoutTag_HOA_ACN_SN3D | (rand() % 8)];
    CodecConfig config;
    AudioChannelLayout* layoutCopy = (AudioChannelLayout*)malloc(sizeof(AudioChannelLayout));
    if (!layoutCopy) {
        fprintf(stderr, "Memory allocation failed for rate %.0f\n", sampleRate);
        return nil;
    }
    memcpy(layoutCopy, channelLayout.layout, sizeof(AudioChannelLayout));
    config.remappingChannelLayout = layoutCopy;
    OverrideApac(&config);

    // Output file
    NSString* fileName = [NSString stringWithFormat:@"fuzzed_%.0f_%u.%@", sampleRate, formatID, isMP3 ? @"mp3" : @"m4a"];
    NSString* tempPath = [NSTemporaryDirectory() stringByAppendingPathComponent:fileName];
    NSURL* outUrl = [NSURL fileURLWithPath:tempPath];

    ExtAudioFileRef audioFile = nullptr;
    OSStatus status = ExtAudioFileCreateWithURL((__bridge CFURLRef)outUrl,
                                               isMP3 ? kAudioFileMP3Type : kAudioFileMPEG4Type,
                                               &outputDesc, config.remappingChannelLayout,
                                               kAudioFileFlags_EraseFile, &audioFile);
    if (status) {
        fprintf(stderr, "Error creating file (rate %.0f, format %u): %x\n", sampleRate, formatID, status);
        free(layoutCopy);
        return nil;
    }

    // Set client format
    status = ExtAudioFileSetProperty(audioFile, kExtAudioFileProperty_ClientDataFormat,
                                     sizeof(AudioStreamBasicDescription), formatIn.streamDescription);
    if (status) {
        fprintf(stderr, "Error setting format (rate %.0f, format %u): %x\n", sampleRate, formatID, status);
        ExtAudioFileDispose(audioFile);
        free(layoutCopy);
        return nil;
    }

    // Set client layout
    status = ExtAudioFileSetProperty(audioFile, kExtAudioFileProperty_ClientChannelLayout,
                                     sizeof(AudioChannelLayout), formatIn.channelLayout.layout);
    if (status) {
        fprintf(stderr, "Error setting layout (rate %.0f, format %u): %x\n", sampleRate, formatID, status);
        ExtAudioFileDispose(audioFile);
        free(layoutCopy);
        return nil;
    }

    // Write random audio
    float audioBuffer[44100];
    std::uniform_real_distribution<float> dis(-1.0f, 1.0f);
    for (int i = 0; i < 44100; ++i) {
        audioBuffer[i] = dis(gen) * (rand() % 2 ? 1.0f : 10.0f); // Random scaling
    }
    AudioBufferList bufferList = {
        .mNumberBuffers = 1,
        .mBuffers = {{.mNumberChannels = channelNum, .mDataByteSize = sizeof(audioBuffer), .mData = audioBuffer}}
    };
    status = ExtAudioFileWrite(audioFile, sizeof(audioBuffer) / sizeof(audioBuffer[0]), &bufferList);
    if (status) {
        fprintf(stderr, "Error writing audio (rate %.0f, format %u): %x\n", sampleRate, formatID, status);
    }

    ExtAudioFileDispose(audioFile);
    free(layoutCopy);
    return tempPath;
}

// Generate fuzzed audio buffer
NSMutableData* generateFuzzedBuffer(NSUInteger len) {
    NSMutableData *buffer = [NSMutableData dataWithLength:len];
    uint8_t *bytes = (uint8_t *)buffer.mutableBytes;

    for (NSUInteger i = 0; i < len; i++) {
        bytes[i] = rand() % 256;
    }

    int mutations = rand() % 10 + 5;
    for (int i = 0; i < mutations; i++) {
        NSUInteger offset = rand() % len;
        bytes[offset] = (rand() % 2) ? 0x00 : 0xFF;
    }

    return buffer;
}

// AudioQueue callback
void audioQueueCallback(void *userData, AudioQueueRef queue, AudioQueueBufferRef buffer) {
    NSMutableData *fuzzed = generateFuzzedBuffer(buffer->mAudioDataBytesCapacity);
    buffer->mAudioDataByteSize = fuzzed.length;
    memcpy(buffer->mAudioData, fuzzed.bytes, fuzzed.length);

    AudioStreamPacketDescription *packets = NULL;
    UInt32 numPackets = rand() % 10;
    if (numPackets) {
        packets = (AudioStreamPacketDescription*)malloc(numPackets * sizeof(AudioStreamPacketDescription));
        for (UInt32 i = 0; i < numPackets; i++) {
            packets[i].mStartOffset = rand() % buffer->mAudioDataByteSize;
            packets[i].mDataByteSize = rand() % (buffer->mAudioDataByteSize - packets[i].mStartOffset + 1);
            packets[i].mVariableFramesInPacket = rand() % 10;
        }
    }

    OSStatus status = AudioQueueEnqueueBuffer(queue, buffer, numPackets, packets);
    if (status != noErr) {
        fprintf(stderr, "Enqueue failed: %d\n", (int)status);
    }

    free(packets);
}

// Fuzz AudioQueue
void fuzzAudioQueue(AudioQueueRef queue) {
    AudioQueueTimelineRef timeline;
    if (AudioQueueCreateTimeline(queue, &timeline) == noErr) {
        AudioTimeStamp time = { .mSampleTime = (Float64)(rand() % 100000), .mFlags = kAudioTimeStampSampleTimeValid };
        AudioQueueSetTimelineDiscontinuity(queue, timeline, &time);
        AudioQueueDisposeTimeline(queue, timeline);
    }

    AudioQueueParameterID param = kAudioQueueParam_PlayRate;
    AudioQueueParameterValue rate = ((float)(rand() % 400 - 100) / 100.0f);
    AudioQueueSetParameter(queue, param, rate);
}

// Fuzz AVAudioPlayer
void fuzzAVAudioPlayer(AVAudioPlayer *player) {
    float rate = ((float)(rand() % 400 - 100) / 100.0f);
    player.rate = rate;
    fprintf(stderr, "-> Fuzzed rate: %f\n", rate);

    NSTimeInterval time = ((double)(rand() % 1000) / 100.0);
    player.currentTime = time;
    fprintf(stderr, "-> Fuzzed time: %f\n", time);

    if (rand() % 2) {
        [player play];
        usleep(rand() % 50000);
        [player stop];
    }
}

// Hypothetical MediaToolbox fuzzing
void fuzzMediaToolbox(NSString *path, NSError **err) {
    // Placeholder for FigFilePlayer (0x0bd653*)
    // FigFilePlayerRef player;
    // FigFilePlayerCreate(&player);
    // FigFilePlayerSetURL(player, (__bridge CFURLRef)[NSURL fileURLWithPath:path]);
    
    float rate = ((float)(rand() % 400 - 100) / 100.0f);
    // FigFilePlayerSetRate(player, rate, nan, nan);
    
    for (int i = 0; i < 20; i++) {
        // FigFilePlayerRef temp;
        // FigFilePlayerCreate(&temp);
        // FigFilePlayerSetURL(temp, (__bridge CFURLRef)[NSURL fileURLWithPath:path]);
        // FigFilePlayerStart(temp);
        // FigFilePlayerDispose(temp);
    }
    
    // FigAudioQueueRef queue;
    // FigAudioQueueCreate(&queue);
    // FigAudioQueueBufferRef buffer;
    // FigAudioQueueAllocateBuffer(queue, rand() % 1000000, &buffer);
    // FigAudioQueueEnqueueBuffer(queue, buffer, /* fuzzed */, nan);
    
    fprintf(stderr, "MediaToolbox fuzzing requires headers\n");
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        // Crash handlers
        signal(SIGSEGV, handleCrash);
        signal(SIGABRT, handleCrash);
        signal(SIGILL, handleCrash);

        // Input MP3
        NSString *inputPath = @"/path/to/sample.mp3";
        if (argc > 1) {
            inputPath = @(argv[1]);
        }

        // Iterations
        int iterations = 100;
        if (argc > 2) {
            iterations = atoi(argv[2]);
        }

        // Audio session
        NSError *error;
        AVAudioSession *session = [AVAudioSession sharedInstance];
        [session setCategory:AVAudioSessionCategoryPlayback error:&error];
        if (error) {
            fprintf(stderr, "Session category error: %s\n", error.localizedDescription.UTF8String);
            return 1;
        }
        [session setActive:YES error:&error];
        if (error) {
            fprintf(stderr, "Session activation failed: %s\n", error.localizedDescription.UTF8String);
            return 1;
        }

        // Fuzzing loop
        for (int i = 0; i < iterations; i++) {
            fprintf(stderr, "Iteration %d/%d\n", i + 1, iterations);

            // Generate fuzzed M4A or MP3
            bool isMP3 = rand() % 2;
            NSString *tempPath = generateFuzzedAudio(inputPath, isMP3);
            if (!tempPath) {
                continue;
            }

            // AVAudioPlayer
            AVAudioPlayer *player = [[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:tempPath] error:&error];
            if (player) {
                player.enableRate = YES;
                fuzzAVAudioPlayer(player);
                [player play];
                usleep(rand() % 100000);
                [player stop];
            } else {
                fprintf(stderr, "Player init failed: %s\n", error.localizedDescription.UTF8String);
            }

            // AudioQueue
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
                fprintf(stderr, "Queue creation failed: %d\n", (int)status);
                continue;
            }

            for (int j = 0; j < 5; j++) {
                AudioQueueBufferRef buffer;
                UInt32 size = rand() % 200000 + 1000;
                if (AudioQueueAllocateBuffer(queue, size, &buffer) == noErr) {
                    audioQueueCallback(NULL, queue, buffer);
                }
            }

            fuzzAudioQueue(queue);
            AudioQueueStart(queue, NULL);
            usleep(rand() % 100000);
            AudioQueueStop(queue, true);
            AudioQueueDispose(queue, true);

            // MediaToolbox
            fuzzMediaToolbox(tempPath, &error);

            // Cleanup
            [[NSFileManager defaultManager] removeItemAtPath:tempPath error:nil];

            fprintf(stderr, "Completed iteration %d\n", i + 1);
        }

        [session setActive:NO error:nil];
        fprintf(stderr, "Fuzzing completed\n");
    }
    return 0;
}