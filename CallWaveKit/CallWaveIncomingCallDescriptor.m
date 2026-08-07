#import "CallWaveIncomingCallDescriptor.h"

@implementation CallWaveIncomingCallDescriptor

- (instancetype)initWithUUID:(NSUUID *)uuid caller:(NSString *)caller {
    return [self initWithUUID:uuid caller:caller cancellation:NO];
}

- (instancetype)initWithUUID:(NSUUID *)uuid
                      caller:(NSString *)caller
                cancellation:(BOOL)cancellation {
    self = [super init];
    if (self) {
        _uuid = uuid;
        _caller = [caller copy];
        _cancellation = cancellation;
    }
    return self;
}

+ (instancetype)descriptorWithUUID:(NSUUID *)uuid caller:(NSString *)caller {
    return [[self alloc] initWithUUID:uuid caller:caller];
}

+ (instancetype)cancellationDescriptorWithUUID:(NSUUID *)uuid {
    return [[self alloc] initWithUUID:uuid caller:nil cancellation:YES];
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<%@: %@>",
            NSStringFromClass(self.class), self.uuid.UUIDString];
}

@end
