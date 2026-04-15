#import "PJSIPThreadManager.h"
#import <pthread.h>
#import <pjsua.h>

@implementation PJSIPThreadManager

static NSMutableDictionary<NSString *, NSValue *> *threadDescriptors = nil;
static NSLock *threadLock = nil;

+ (void)initialize {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        threadDescriptors = [NSMutableDictionary new];
        threadLock = [NSLock new];
    });
}

+ (BOOL)ensureRegistered:(NSString *)name {
    if (pj_thread_is_registered()) {
        return YES;
    }

    [threadLock lock];

    NSString *key = [NSString stringWithFormat:@"%p", (void *)pthread_self()];

    // Already registered for this thread
    if ([threadDescriptors objectForKey:key]) {
        [threadLock unlock];
        return YES;
    }

    // Allocate and zero-fill the thread descriptor
    pj_thread_desc *desc = (pj_thread_desc *)malloc(sizeof(pj_thread_desc));
    if (!desc) {
        NSLog(@"[CallWaveSIP] Failed to allocate thread descriptor for '%@'", name);
        [threadLock unlock];
        return NO;
    }
    memset(desc, 0, sizeof(pj_thread_desc));

    pj_thread_t *thread = NULL;
    NSString *threadName = [NSString stringWithFormat:@"%@-%@", name, key];
    pj_status_t status = pj_thread_register([threadName UTF8String], *desc, &thread);

    if (status != PJ_SUCCESS) {
        NSLog(@"[CallWaveSIP] Thread registration failed for '%@': %d", threadName, status);
        free(desc);
        [threadLock unlock];
        return NO;
    }

    [threadDescriptors setObject:[NSValue valueWithPointer:desc] forKey:key];
    [threadLock unlock];
    return YES;
}

+ (void)cleanup {
    [threadLock lock];

    for (NSString *key in threadDescriptors) {
        NSValue *value = [threadDescriptors objectForKey:key];
        pj_thread_desc *desc = (pj_thread_desc *)[value pointerValue];
        if (desc) {
            free(desc);
        }
    }
    [threadDescriptors removeAllObjects];

    [threadLock unlock];
}

@end
