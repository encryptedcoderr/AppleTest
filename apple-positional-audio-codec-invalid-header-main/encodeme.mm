@import AVFAudio;
@import AudioToolbox;
#include <cmath>

int main() {
    uint32_t channelNum = 1;
    AVAudioFormat* formatIn = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:44100
                                                                             channels:channelNum];
    AVAudioChannelLayout* channelLayout =
        [AVAudioChannelLayout layoutWithLayoutTag:kAudioChannelLayoutTag_Mono];

    const int sampleRate = 44100;
    const int durationSeconds = 10;
    const int totalSamples = sampleRate * durationSeconds; // 441,000 samples
    const int samplesPerBuffer = 1024; // Frame size for AAC
    float* audioBuffer = (float*)malloc(samplesPerBuffer * sizeof(float));

    // --- M4A Output (AAC) ---
    AudioStreamBasicDescription m4aDescription{
        .mSampleRate = 44100,
        .mFormatID = kAudioFormatMPEG4AAC,
        .mFormatFlags = 0,
        .mBytesPerPacket = 0,
        .mFramesPerPacket = 1024,
        .mBytesPerFrame = 0,
        .mChannelsPerFrame = channelNum,
        .mBitsPerChannel = 0,
        .mReserved = 0
    };

    NSURL* m4aUrl = [NSURL fileURLWithPath:@"output.m4a"];
    ExtAudioFileRef m4aFile = nullptr;
    OSStatus status = ExtAudioFileCreateWithURL((__bridge CFURLRef)m4aUrl, kAudioFileM4AType,
                                                &m4aDescription, channelLayout.layout,
                                                kAudioFileFlags_EraseFile, &m4aFile);
    if (status) {
        fprintf(stderr, "error creating M4A file: %x\n", status);
        free(audioBuffer);
        return 1;
    }

    status = ExtAudioFileSetProperty(m4aFile, kExtAudioFileProperty_ClientDataFormat,
                                     sizeof(AudioStreamBasicDescription), formatIn.streamDescription);
    if (status) {
        fprintf(stderr, "error setting M4A client format: %x\n", status);
        ExtAudioFileDispose(m4aFile);
        free(audioBuffer);
        return 1;
    }
    status = ExtAudioFileSetProperty(m4aFile, kExtAudioFileProperty_ClientChannelLayout,
                                     sizeof(AudioChannelLayout), formatIn.channelLayout.layout);
    if (status) {
        fprintf(stderr, "error setting M4A channel layout: %x\n", status);
        ExtAudioFileDispose(m4aFile);
        free(audioBuffer);
        return 1;
    }

    // Write audio to M4A
    for (int i = 0; i < totalSamples; i += samplesPerBuffer) {
        int samplesToWrite = (i + samplesPerBuffer <= totalSamples) ? samplesPerBuffer : (totalSamples - i);

        // Generate 440 Hz sine wave
        for (int j = 0; j < samplesToWrite; j++) {
            audioBuffer[j] = sin(2 * M_PI * 440 * (i + j) / sampleRate) * 0.5f;
        }

        AudioBufferList audioBufferList{
            .mNumberBuffers = 1,
            .mBuffers = {
                {
                    .mNumberChannels = 1,
                    .mDataByteSize = static_cast<UInt32>(samplesToWrite * sizeof(float)),
                    .mData = audioBuffer,
                },
            },
        };

        status = ExtAudioFileWrite(m4aFile, samplesToWrite, &audioBufferList);
        if (status) {
            fprintf(stderr, "error writing M4A audio: %x\n", status);
            ExtAudioFileDispose(m4aFile);
            free(audioBuffer);
            return 1;
        }
    }

    free(audioBuffer);

    // Close M4A file
    status = ExtAudioFileDispose(m4aFile);
    if (status) {
        fprintf(stderr, "error closing M4A file: %x\n", status);
        return 1;
    }

    return 0;
}
