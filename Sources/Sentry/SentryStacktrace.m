#import "SentryStacktrace.h"
#import "NSMutableDictionary+Sentry.h"
#import "SentryFrame.h"
#import "SentryInternalDefines.h"
#import "SentryLogC.h"

NS_ASSUME_NONNULL_BEGIN

@implementation SentryStacktrace

- (instancetype)initWithFrames:(NSArray<SentryFrame *> *)frames
                     registers:(NSDictionary<NSString *, NSString *> *)registers
{
    self = [super init];
    if (self) {
        self.registers = registers;
        self.frames = frames;
    }
    return self;
}

/**
 * This function fixes duplicate frames and removes the first duplicate
 * https://github.com/kstenerud/KSCrash/blob/05cdc801cfc578d256f85de2e72ec7877cbe79f8/Source/KSCrash/Recording/Tools/KSStackCursor_MachineContext.c#L84
 */
- (void)fixDuplicateFrames
{
    if (self.frames.count < 3 || nil == self.registers) {
        return;
    }

    SentryFrame *beforeLastFrame = [self.frames objectAtIndex:self.frames.count - 2];
    SentryFrame *capturedCaller = [self.frames objectAtIndex:self.frames.count - 3];
    NSString *linkRegister = self.registers[@"lr"];
    NSString *candidateAddress = beforeLastFrame.instructionAddress;
    NSString *callerAddress = capturedCaller.instructionAddress;

    // The cursor emits PC, LR, then captured frame-pointer callers (reversed here).
    // LR alone is not deletion evidence: preserve short/incomplete stacks unless
    // that first captured caller independently repeats the synthetic LR entry.
    if (linkRegister != nil && candidateAddress != nil && callerAddress != nil &&
        [linkRegister isEqualToString:candidateAddress] &&
        [candidateAddress isEqualToString:callerAddress]) {
        NSMutableArray *copyFrames = self.frames.mutableCopy;
        [copyFrames removeObjectAtIndex:self.frames.count - 2];
        self.frames = copyFrames;
        SENTRY_LOG_DEBUG(@"Found duplicate frame, removing one with link register");
    }
}

- (NSDictionary<NSString *, id> *)serialize
{
    NSMutableDictionary *serializedData = [[NSMutableDictionary alloc] init];

    NSMutableArray *frames = [[NSMutableArray alloc] init];
    for (SentryFrame *frame in self.frames) {
        NSDictionary *serialized = [frame serialize];
        if (serialized.allKeys.count > 0) {
            [frames addObject:[frame serialize]];
        }
    }
    if (frames.count > 0) {
        [serializedData setValue:frames forKey:@"frames"];
    }
    // This is here because we wanted to be conform with the old json
    if (self.registers.count > 0) {
        [serializedData setValue:self.registers forKey:@"registers"];
    }

    [SentryDictionary setBoolValue:self.snapshot forKey:@"snapshot" intoDictionary:serializedData];
    return serializedData;
}

@end

NS_ASSUME_NONNULL_END
