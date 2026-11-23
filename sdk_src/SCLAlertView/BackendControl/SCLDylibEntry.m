//
//  SCLDylibEntry.m
//  SCLAlertView - dylib 构造入口
//
//  __attribute__((constructor)) 让 dylib 被 dlopen / 注入 (DYLD_INSERT_LIBRARIES /
//  fishhook / Frida) 时自动执行，调用 Swift 桥接开始后台对接。
//

#import <Foundation/Foundation.h>
#import <dlfcn.h>

__attribute__((constructor)) static void scl_dylib_entry(void) {
    @autoreleasepool {
        // 通过 NSClassFromString 调用 Swift 类，避免暴露 Swift 头文件给 OC 桥接
        Class bridge = NSClassFromString(@"SCLAlertView.SCLDylibBridge");
        if (!bridge) {
            bridge = NSClassFromString(@"SCLDylibBridge");
        }
        if (bridge) {
            id inst = [bridge performSelector:@selector(sharedInstance)];
            if (inst) {
                [inst performSelector:@selector(start)];
            }
        } else {
            NSLog(@"[SCLDylib] 未能加载 SCLDylibBridge，请确认 dylib 内包含该类");
        }
    }
}
