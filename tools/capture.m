// capture <seconds> [deviceUID]: per-channel RMS of a Loopback device's pass-through input.
#import <Foundation/Foundation.h>
#include "cap.h"
int main(int argc, char **argv) { @autoreleasepool {
    NSString *uid = argc > 2 ? @(argv[2]) : @"com.rogueamoeba.Loopback:39FEBD16-3F2D-4064-9FAE-B105143B9734";
    capStart(uid, 12); [NSThread sleepForTimeInterval:atof(argv[1])]; capReport();
}}
