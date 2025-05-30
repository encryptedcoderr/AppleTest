@import AVFAudio;
@import AudioToolbox;

int main() {
  //This is the actual number of channels
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

  NSURL* outUrl = [NSURL fileURLWithPath:@"output.mp4"];

  OSStatus status = 0;

  ExtAudioFileRef audioFile = nullptr;
  status =
      ExtAudioFileCreateWithURL((__bridge CFURLRef)outUrl, kAudioFileMPEG4Type, &outputDescription,
                                channelLayout.layout, kAudioFileFlags_EraseFile, &audioFile);
  if (status) {
    fprintf(stderr, "error creating file: %x\n", status);
    return 1;
  }

  status = ExtAudioFileSetProperty(audioFile, kExtAudioFileProperty_ClientDataFormat,
                                   sizeof(AudioStreamBasicDescription), formatIn.streamDescription);
  if (status) {
    fprintf(stderr, "error writing audiofile: %x\n", status);
    return 1;
  }
  status = ExtAudioFileSetProperty(audioFile, kExtAudioFileProperty_ClientChannelLayout,
                                   sizeof(AudioChannelLayout), formatIn.channelLayout.layout);
  if (status) {
    fprintf(stderr, "error writing audiofile: %x\n", status);
    return 1;
  }
  
  //This is actually unnecessary for just the PoC.
  float audioBuffer[44100];
  for (int i = 0; i < 44100; ++i) {
      audioBuffer[i] = 0.5f;
  }
  AudioBufferList audioBufferList{
      .mNumberBuffers = 1,
      .mBuffers =
          {
              {
                  .mNumberChannels = 1,
                  .mDataByteSize = sizeof(audioBuffer),
                  .mData = audioBuffer,
              },
          },
  };
  status =
      ExtAudioFileWrite(audioFile, sizeof(audioBuffer) / sizeof(audioBuffer[0]), &audioBufferList);
  if (status) {
    fprintf(stderr, "error writing audiofile: %x\n", status);
    return 1;
  }
  status = ExtAudioFileDispose(audioFile);
  if (status) {
    fprintf(stderr, "error closing audiofile: %x\n", status);
    return 1;
  }
  audioFile = nullptr;
  return 0;
}
