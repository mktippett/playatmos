#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#include <math.h>
int main(int argc, char**argv){ @autoreleasepool {
  NSURL *url=[NSURL fileURLWithPath:@(argv[1])]; int nch=argc>2?atoi(argv[2]):12;
  AVURLAsset *asset=[AVURLAsset assetWithURL:url];
  AVAssetTrack *t=[[asset tracksWithMediaType:AVMediaTypeAudio] firstObject];
  for(id o in t.formatDescriptions){ CMAudioFormatDescriptionRef fd=(__bridge CMAudioFormatDescriptionRef)o;
    const AudioStreamBasicDescription *a=CMAudioFormatDescriptionGetStreamBasicDescription(fd);
    printf("fmt %.4s ch %u sr %.0f fpp %u\n",(char*)&(UInt32){CFSwapInt32HostToBig(a->mFormatID)},a->mChannelsPerFrame,a->mSampleRate,a->mFramesPerPacket);
    size_t sz=0; const AudioChannelLayout*l=CMAudioFormatDescriptionGetChannelLayout(fd,&sz); if(l) printf("layout tag 0x%x\n",l->mChannelLayoutTag);
    size_t cnt=0; const AudioFormatListItem*fl=CMAudioFormatDescriptionGetFormatList(fd,&cnt);
    for(size_t i=0;i<cnt/sizeof(AudioFormatListItem);i++) printf("formatList %zu: %.4s ch %u tag 0x%x\n",i,(char*)&(UInt32){CFSwapInt32HostToBig(fl[i].mASBD.mFormatID)},fl[i].mASBD.mChannelsPerFrame,fl[i].mChannelLayoutTag);
    NSLog(@"ext %@",(__bridge NSDictionary*)CMFormatDescriptionGetExtensions(fd));
  }
  NSError*err; AVAssetReader*r=[AVAssetReader assetReaderWithAsset:asset error:&err];
  AudioChannelLayout lay={0}; lay.mChannelLayoutTag= nch==12?kAudioChannelLayoutTag_Atmos_7_1_4: nch==16?kAudioChannelLayoutTag_Atmos_9_1_6: kAudioChannelLayoutTag_MPEG_5_1_D;
  NSDictionary*s=@{AVFormatIDKey:@(kAudioFormatLinearPCM),AVLinearPCMBitDepthKey:@32,AVLinearPCMIsFloatKey:@YES,AVLinearPCMIsNonInterleaved:@NO,AVLinearPCMIsBigEndianKey:@NO,AVSampleRateKey:@48000,AVNumberOfChannelsKey:@(nch),AVChannelLayoutKey:[NSData dataWithBytes:&lay length:sizeof lay]};
  AVAssetReaderTrackOutput*o=[AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:t outputSettings:s]; [r addOutput:o];
  r.timeRange=CMTimeRangeMake(CMTimeMakeWithSeconds(argc>3?atof(argv[3]):30,48000),CMTimeMakeWithSeconds(60,48000));
  [r startReading]; double sum[32]={0}; long frames=0; CMSampleBufferRef sb;
  while((sb=[o copyNextSampleBuffer])){ CMBlockBufferRef bb=CMSampleBufferGetDataBuffer(sb); size_t len; char*p;
    CMBlockBufferGetDataPointer(bb,0,NULL,&len,&p); float*f=(float*)p; long n=len/4/nch;
    for(long i=0;i<n;i++)for(int c=0;c<nch;c++){double v=f[i*nch+c];sum[c]+=v*v;} frames+=n; CFRelease(sb);}
  printf("status %ld err %s frames %ld\nRMS dB:",(long)r.status,[[r.error description]UTF8String],frames);
  for(int c=0;c<nch;c++) printf(" %.1f",10*log10(sum[c]/(frames?frames:1)+1e-20)); printf("\n");
}}
