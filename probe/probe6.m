#import <AVFoundation/AVFoundation.h>
#include "../tools/cap.h"
int main(int argc,char**argv){@autoreleasepool{
  NSString*uid=@"com.rogueamoeba.Loopback:39FEBD16-3F2D-4064-9FAE-B105143B9734";
  double t0=argc>2?atof(argv[2]):60, dur=argc>3?atof(argv[3]):10; float vol=argc>4?atof(argv[4]):0.03;
  AVPlayer*p=[AVPlayer playerWithURL:(strncmp(argv[1],"http",4)?[NSURL fileURLWithPath:@(argv[1])]:[NSURL URLWithString:@(argv[1])])]; p.audioOutputDeviceUniqueID=uid; p.volume=vol;
  [p seekToTime:CMTimeMakeWithSeconds(t0,600)];
  capStart(uid,12);
  [NSThread sleepForTimeInterval:1]; [p play]; [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:dur]];
  [p pause]; fprintf(stderr,"item status %ld err %s\n",(long)p.currentItem.status,[[p.currentItem.error description] UTF8String]); capReport();
}}
