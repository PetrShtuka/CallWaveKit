#import "CallWaveIncomingCallDescriptor.h"

@implementation CallWaveIncomingCallDescriptor

- (instancetype)initWithUUID:(NSUUID *)uuid caller:(NSString *)caller {
    self = [super init];
    if (self) {
        _uuid = uuid;
        _caller = [caller copy];
    }
    return self;
}

+ (instancetype)descriptorWithUUID:(NSUUID *)uuid caller:(NSString *)caller {
    return [[self alloc] initWithUUID:uuid caller:caller];
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<%@: %@>",
            NSStringFromClass(self.class), self.uuid.UUIDString];
}

@end
