#import <Foundation/Foundation.h>

// constructor 在 dylib 加载时自动触发，调用 Swift 的 SCLDylibBridge。
// 声明仅为 module map 需要，实现见 SCLAlertView/BackendControl/SCLDylibEntry.m。
@interface SCLDylibEntry : NSObject
+ (void)fire;
@end
