#import <AVFoundation/AVFoundation.h>
#include "../tools/cap.h"
// mode 0: asset fd; 1: ASBD + dec3 cookie; 2: bare ASBD no cookie
int main(int argc,char**argv){@autoreleasepool{
  NSString*uid=@"com.rogueamoeba.Loopback:39FEBD16-3F2D-4064-9FAE-B105143B9734"; int mode=atoi(argv[2]);
  AVURLAsset*asset=[AVURLAsset assetWithURL:[NSURL fileURLWithPath:@(argv[1])]];
  AVAssetTrack*t=[[asset tracksWithMediaType:AVMediaTypeAudio] firstObject];
  CMAudioFormatDescriptionRef afd=(__bridge CMAudioFormatDescriptionRef)t.formatDescriptions[0];
  AudioStreamBasicDescription asbd=*CMAudioFormatDescriptionGetStreamBasicDescription(afd); size_t cs; const void*ck=CMAudioFormatDescriptionGetMagicCookie(afd,&cs);
  CMAudioFormatDescriptionRef fd=afd;
  if(mode==1){ AudioChannelLayout l={0}; l.mChannelLayoutTag=kAudioChannelLayoutTag_MPEG_5_1_D; CMAudioFormatDescriptionCreate(NULL,&asbd,sizeof l,&l,cs,ck,NULL,&fd);}
  if(mode==3||mode==4){ AudioStreamBasicDescription b=asbd; b.mFormatID='ec+3'; b.mChannelsPerFrame=mode==3?12:16; AudioChannelLayout l={0}; l.mChannelLayoutTag=mode==3?kAudioChannelLayoutTag_Atmos_7_1_4:kAudioChannelLayoutTag_Atmos_9_1_6; OSStatus st=CMAudioFormatDescriptionCreate(NULL,&b,sizeof l,&l,cs,ck,NULL,&fd); fprintf(stderr,"create st %d\n",(int)st);}
  if(mode==2){ CMAudioFormatDescriptionCreate(NULL,&asbd,0,NULL,0,NULL,NULL,&fd);}
  size_t n=0; CMAudioFormatDescriptionGetFormatList(fd,&n); fprintf(stderr,"mode %d formatList items %zu\n",mode,n/sizeof(AudioFormatListItem));
  AVAssetReader*r=[AVAssetReader assetReaderWithAsset:asset error:nil];
  AVAssetReaderTrackOutput*o=[AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:t outputSettings:nil]; [r addOutput:o]; [r startReading];
  AVSampleBufferAudioRenderer*ar=[AVSampleBufferAudioRenderer new]; ar.audioOutputDeviceUniqueID=uid; ar.volume=0.03;
  AVSampleBufferRenderSynchronizer*sync=[AVSampleBufferRenderSynchronizer new]; [sync addRenderer:ar];
  dispatch_queue_t q=dispatch_queue_create("feed",0);
  [ar requestMediaDataWhenReadyOnQueue:q usingBlock:^{ while(ar.readyForMoreMediaData){ CMSampleBufferRef sb=[o copyNextSampleBuffer]; if(!sb){[ar stopRequestingMediaData];return;}
      CMSampleBufferRef out=sb;
      if(mode){ // rewrap with new format description
        CMBlockBufferRef bb=CMSampleBufferGetDataBuffer(sb); const AudioStreamPacketDescription*pd; size_t pds; CMSampleBufferGetAudioStreamPacketDescriptionsPtr(sb,&pd,&pds);
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(NULL,bb,fd,CMSampleBufferGetNumSamples(sb),CMSampleBufferGetPresentationTimeStamp(sb),pd,&out); CFRelease(sb);}
      [ar enqueueSampleBuffer:out]; CFRelease(out);} }];
  capStart(uid,12); [NSThread sleepForTimeInterval:1.0];
  [sync setRate:1 time:CMTimeMakeWithSeconds(2,48000)];
  [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:8]];
  fprintf(stderr,"renderer status %ld err %s\n",(long)ar.status,[[ar.error description]UTF8String]); capReport();
}}
