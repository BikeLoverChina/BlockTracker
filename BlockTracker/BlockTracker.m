//
//  BlockTracker.m
//  BlockTrackerSample
//
//  Created by 杨萧玉 on 2018/3/28.
//  Copyright © 2018年 杨萧玉. All rights reserved.
//

#import "BlockTracker.h"
#import <BlockHookKit/BlockHookKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <pthread.h>

#if !__has_feature(objc_arc)
#error
#endif

struct BTInvocaton {
    void *isa;
    void *frame;
    void *retdata;
    void *signature;
    void *container;
    uint8_t retainedArgs;
    uint8_t reserved[15];
};

static inline BOOL mt_object_isClass(id _Nullable obj)
{
#if __IPHONE_OS_VERSION_MIN_REQUIRED >= __IPHONE_8_0 || __TV_OS_VERSION_MIN_REQUIRED >= __TVOS_9_0 || __WATCH_OS_VERSION_MIN_REQUIRED >= __WATCHOS_2_0 || __MAC_OS_X_VERSION_MIN_REQUIRED >= __MAC_10_10
    return object_isClass(obj);
#else
    if (!obj) return NO;
    return obj == [obj class];
#endif
}

Class mt_metaClass(Class cls)
{
    if (class_isMetaClass(cls)) {
        return cls;
    }
    return object_getClass(cls);
}

static NSString * mt_methodDescription(id target, SEL selector)
{
    NSString *selectorName = NSStringFromSelector(selector);
    if (mt_object_isClass(target)) {
        NSString *className = NSStringFromClass(target);
        return [NSString stringWithFormat:@"%@ [%@ %@]", class_isMetaClass(target) ? @"+" : @"-", className, selectorName];
    }
    else {
        return [NSString stringWithFormat:@"[%p %@]", target, selectorName];
    }
}

@interface MTDealloc : NSObject

@property (nonatomic, weak) MTRule *rule;
@property (nonatomic, copy) NSString *methodDescription;
@property (nonatomic) Class cls;

@end

@implementation MTDealloc

- (void)dealloc
{
    SEL selector = NSSelectorFromString(@"discardRule:whenTargetDealloc:");
    ((void (*)(id, SEL, MTRule *, MTDealloc *))[MTEngine.defaultEngine methodForSelector:selector])(MTEngine.defaultEngine, selector, self.rule, self);
}

@end

@interface MTRule ()

@property (nonatomic) BlockTrackerCallbackBlock callback;
@property (nonatomic) NSArray<NSNumber *> *blockArgIndex;

@end

@implementation MTRule

- (instancetype)initWithTarget:(id)target selector:(SEL)selector
{
    self = [super init];
    if (self) {
        _target = target;
        _selector = selector;
    }
    return self;
}

- (BOOL)apply
{
    return [MTEngine.defaultEngine applyRule:self];
}

- (BOOL)discard
{
    return [MTEngine.defaultEngine discardRule:self];
}

@end

@interface MTEngine ()

@property (nonatomic) NSMutableDictionary<NSString *, MTRule *> *rules;

- (void)discardRule:(MTRule *)rule whenTargetDealloc:(MTDealloc *)mtDealloc;

@end

@implementation MTEngine

static pthread_mutex_t mutex;

+ (instancetype)defaultEngine
{
    static dispatch_once_t onceToken;
    static MTEngine *instance;
    dispatch_once(&onceToken, ^{
        instance = [MTEngine new];
    });
    return instance;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _rules = [NSMutableDictionary dictionary];
        pthread_mutex_init(&mutex, NULL);
    }
    return self;
}

- (NSArray<MTRule *> *)allRules
{
    return [self.rules allValues];
}

- (BOOL)applyRule:(MTRule *)rule
{
    pthread_mutex_lock(&mutex);
    __block BOOL shouldApply = YES;
    if (mt_checkRuleValid(rule)) {
        [self.rules enumerateKeysAndObjectsUsingBlock:^(NSString * _Nonnull key, MTRule * _Nonnull obj, BOOL * _Nonnull stop) {
            if (sel_isEqual(rule.selector, obj.selector)) {
                
                Class clsA = mt_classOfTarget(rule.target);
                Class clsB = mt_classOfTarget(obj.target);
                
                shouldApply = !([clsA isSubclassOfClass:clsB] || [clsB isSubclassOfClass:clsA]);
                *stop = shouldApply;
                NSCAssert(shouldApply, @"Error: %@ already apply rule in %@. A message can only have one rule per class hierarchy.", NSStringFromSelector(obj.selector), NSStringFromClass(clsB));
            }
        }];
        
        if (shouldApply) {
            self.rules[mt_methodDescription(rule.target, rule.selector)] = rule;
            mt_overrideMethod(rule.target, rule.selector);
            mt_configureTargetDealloc(rule);
        }
    }
    else {
        shouldApply = NO;
    }
    pthread_mutex_unlock(&mutex);
    return shouldApply;
}

- (BOOL)discardRule:(MTRule *)rule
{
    pthread_mutex_lock(&mutex);
    BOOL shouldDiscard = NO;
    if (mt_checkRuleValid(rule)) {
        NSString *description = mt_methodDescription(rule.target, rule.selector);
        shouldDiscard = self.rules[description] != nil;
        if (shouldDiscard) {
            self.rules[description] = nil;
            mt_recoverMethod(rule.target, rule.selector);
        }
    }
    pthread_mutex_unlock(&mutex);
    return shouldDiscard;
}

- (void)discardRule:(MTRule *)rule whenTargetDealloc:(MTDealloc *)mtDealloc
{
    pthread_mutex_lock(&mutex);
    
    NSString *description = mtDealloc.methodDescription;
    if (self.rules[description] != nil) {
        self.rules[description] = nil;
        if (MTEngine.defaultEngine.rules[mt_methodDescription(mtDealloc.cls, rule.selector)]) {
            return;
        }
        mt_revertHook(mtDealloc.cls, rule.selector);
    }
    pthread_mutex_unlock(&mutex);
}

#pragma mark - Private Helper

static BOOL mt_checkRuleValid(MTRule *rule)
{
    if (rule.target && rule.selector && rule.callback) {
        NSString *selectorName = NSStringFromSelector(rule.selector);
        if ([selectorName isEqualToString:@"forwardInvocation:"]) {
            return NO;
        }
        Class cls = mt_classOfTarget(rule.target);
        NSString *className = NSStringFromClass(cls);
        if ([className isEqualToString:@"MTRule"] || [className isEqualToString:@"MTEngine"]) {
            return NO;
        }
        return YES;
    }
    return NO;
}

static SEL mt_aliasForSelector(Class cls, SEL selector)
{
    NSString *fixedOriginalSelectorName = [NSString stringWithFormat:@"__mt_%@", NSStringFromSelector(selector)];
    SEL fixedOriginalSelector = NSSelectorFromString(fixedOriginalSelectorName);
    return fixedOriginalSelector;
}



/**
 处理执行 NSInvocation
 
 @param invocation NSInvocation 对象
 @param fixedSelector 修正后的 SEL
 */
static void mt_handleInvocation(NSInvocation *invocation, SEL fixedSelector)
{
    NSString *methodDescriptionForInstance = mt_methodDescription(invocation.target, invocation.selector);
    NSString *methodDescriptionForClass = mt_methodDescription(object_getClass(invocation.target), invocation.selector);
    
    MTRule *rule = MTEngine.defaultEngine.rules[methodDescriptionForInstance];
    if (!rule) {
        rule = MTEngine.defaultEngine.rules[methodDescriptionForClass];
    }
    [invocation retainArguments];
//    void **invocationFrame = ((__bridge struct BTInvocaton *)invocation)->frame;
//    void *blockArg = invocationFrame[2];
    
    for (NSNumber *index in rule.blockArgIndex) {
        if (index.integerValue < invocation.methodSignature.numberOfArguments) {
            __unsafe_unretained id block;
            [invocation getArgument:&block atIndex:index.integerValue];
            __weak typeof(block) weakBlock = block;
            __weak typeof(rule) weakRule = rule;
            [block block_hookWithMode:BlockHookModeAfter usingBlock:^(BHToken *token) {
                __strong typeof(weakBlock) strongBlock = weakBlock;
                __strong typeof(weakRule) strongRule = weakRule;
                strongRule.callback(strongBlock, BlockTrackerCallBackTypeInvoke, token.retValue, [NSThread callStackSymbols]);
            }];

            [block block_hookWithMode:BlockHookModeDead usingBlock:^(BHToken *token) {
                __strong typeof(weakBlock) strongBlock = weakBlock;
                __strong typeof(weakRule) strongRule = weakRule;
                strongRule.callback(strongBlock, BlockTrackerCallBackTypeDead, token.retValue, [NSThread callStackSymbols]);
            }];
        }
    }
    invocation.selector = fixedSelector;
    [invocation invoke];
}

static void mt_forwardInvocation(__unsafe_unretained id assignSlf, SEL selector, NSInvocation *invocation)
{
    SEL originalSelector = invocation.selector;
    SEL fixedOriginalSelector = mt_aliasForSelector(object_getClass(assignSlf), originalSelector);
    if (![assignSlf respondsToSelector:fixedOriginalSelector]) {
        mt_executeOrigForwardInvocation(assignSlf, selector, invocation);
        return;
    }
    mt_handleInvocation(invocation, fixedOriginalSelector);
}

static NSString *const MTForwardInvocationSelectorName = @"__mt_forwardInvocation:";

static Class mt_classOfTarget(id target)
{
    Class cls;
    if (mt_object_isClass(target)) {
        cls = target;
    }
    else {
        cls = object_getClass(target);
    }
    return cls;
}

static void mt_overrideMethod(id target, SEL selector)
{
    Class cls = mt_classOfTarget(target);
    
    Method originMethod = class_getInstanceMethod(cls, selector);
    if (!originMethod) {
        NSCAssert(NO, @"unrecognized selector -%@ for class %@", NSStringFromSelector(selector), NSStringFromClass(cls));
        return;
    }
    const char *originType = (char *)method_getTypeEncoding(originMethod);
    
    IMP originalImp = class_respondsToSelector(cls, selector) ? class_getMethodImplementation(cls, selector) : NULL;
    
    IMP msgForwardIMP = _objc_msgForward;
#if !defined(__arm64__)
    if (originType[0] == _C_STRUCT_B) {
        //In some cases that returns struct, we should use the '_stret' API:
        //http://sealiesoftware.com/blog/archive/2008/10/30/objc_explain_objc_msgSend_stret.html
        // As an ugly internal runtime implementation detail in the 32bit runtime, we need to determine of the method we hook returns a struct or anything larger than id.
        // https://developer.apple.com/library/mac/documentation/DeveloperTools/Conceptual/LowLevelABI/000-Introduction/introduction.html
        // https://github.com/ReactiveCocoa/ReactiveCocoa/issues/783
        // http://infocenter.arm.com/help/topic/com.arm.doc.ihi0042e/IHI0042E_aapcs.pdf (Section 5.4)
        //NSMethodSignature knows the detail but has no API to return, we can only get the info from debugDescription.
        NSMethodSignature *methodSignature = [NSMethodSignature signatureWithObjCTypes:originType];
        if ([methodSignature.debugDescription rangeOfString:@"is special struct return? YES"].location != NSNotFound) {
            msgForwardIMP = (IMP)_objc_msgForward_stret;
        }
    }
#endif
    
    if (originalImp == msgForwardIMP) {
        return;
    }
    
    if (class_getMethodImplementation(cls, @selector(forwardInvocation:)) != (IMP)mt_forwardInvocation) {
        IMP originalForwardImp = class_replaceMethod(cls, @selector(forwardInvocation:), (IMP)mt_forwardInvocation, "v@:@");
        if (originalForwardImp) {
            class_addMethod(cls, NSSelectorFromString(MTForwardInvocationSelectorName), originalForwardImp, "v@:@");
        }
    }
    
    if (class_respondsToSelector(cls, selector)) {
        SEL fixedOriginalSelector = mt_aliasForSelector(cls, selector);
        if(!class_respondsToSelector(cls, fixedOriginalSelector)) {
            class_addMethod(cls, fixedOriginalSelector, originalImp, originType);
        }
    }
    
    // Replace the original selector at last, preventing threading issus when
    // the selector get called during the execution of `overrideMethod`
    class_replaceMethod(cls, selector, msgForwardIMP, originType);
}

static void mt_revertHook(Class cls, SEL selector)
{
    if (class_getMethodImplementation(cls, @selector(forwardInvocation:)) == (IMP)mt_forwardInvocation) {
        IMP originalForwardImp = class_getMethodImplementation(cls, NSSelectorFromString(MTForwardInvocationSelectorName));
        if (originalForwardImp) {
            class_replaceMethod(cls, @selector(forwardInvocation:), originalForwardImp, "v@:@");
        }
    }
    else {
        return;
    }
    
    Method originMethod = class_getInstanceMethod(cls, selector);
    if (!originMethod) {
        NSCAssert(NO, @"unrecognized selector -%@ for class %@", NSStringFromSelector(selector), NSStringFromClass(cls));
        return;
    }
    const char *originType = (char *)method_getTypeEncoding(originMethod);
    
    SEL fixedOriginalSelector = mt_aliasForSelector(cls, selector);
    if (class_respondsToSelector(cls, fixedOriginalSelector)) {
        IMP originalImp = class_getMethodImplementation(cls, fixedOriginalSelector);
        class_replaceMethod(cls, selector, originalImp, originType);
    }
}

static void mt_recoverMethod(id target, SEL selector)
{
    Class cls;
    if (mt_object_isClass(target)) {
        cls = target;
    }
    else {
        cls = object_getClass(target);
        if (MTEngine.defaultEngine.rules[mt_methodDescription(cls, selector)]) {
            return;
        }
    }
    mt_revertHook(cls, selector);
}

static void mt_executeOrigForwardInvocation(id slf, SEL selector, NSInvocation *invocation)
{
    SEL origForwardSelector = NSSelectorFromString(MTForwardInvocationSelectorName);
    
    if ([slf respondsToSelector:origForwardSelector]) {
        NSMethodSignature *methodSignature = [slf methodSignatureForSelector:origForwardSelector];
        if (!methodSignature) {
            NSCAssert(NO, @"unrecognized selector -%@ for instance %@", NSStringFromSelector(origForwardSelector), slf);
            return;
        }
        NSInvocation *forwardInv= [NSInvocation invocationWithMethodSignature:methodSignature];
        [forwardInv setTarget:slf];
        [forwardInv setSelector:origForwardSelector];
        [forwardInv setArgument:&invocation atIndex:2];
        [forwardInv invoke];
    } else {
        Class superCls = [[slf class] superclass];
        Method superForwardMethod = class_getInstanceMethod(superCls, @selector(forwardInvocation:));
        void (*superForwardIMP)(id, SEL, NSInvocation *);
        superForwardIMP = (void (*)(id, SEL, NSInvocation *))method_getImplementation(superForwardMethod);
        superForwardIMP(slf, @selector(forwardInvocation:), invocation);
    }
}

static void mt_configureTargetDealloc(MTRule *rule)
{
    if (mt_object_isClass(rule.target)) {
        return;
    }
    else {
        Class cls = object_getClass(rule.target);
        MTDealloc *mtDealloc = objc_getAssociatedObject(rule.target, rule.selector);
        if (!mtDealloc) {
            mtDealloc = [MTDealloc new];
            mtDealloc.rule = rule;
            mtDealloc.methodDescription = mt_methodDescription(rule.target, rule.selector);
            mtDealloc.cls = cls;
            objc_setAssociatedObject(rule.target, rule.selector, mtDealloc, OBJC_ASSOCIATION_RETAIN);
        }
    }
}

@end

static const char *BHSizeAndAlignment(const char *str, NSUInteger *sizep, NSUInteger *alignp, long *len)
{
    const char *out = NSGetSizeAndAlignment(str, sizep, alignp);
    if(len)
        *len = out - str;
    while(isdigit(*out))
        out++;
    return out;
}

@implementation NSObject (BlockTracker)

- (NSArray<MTRule *> *)mt_allRules
{
    NSMutableArray<MTRule *> *result = [NSMutableArray array];
    for (MTRule *rule in MTEngine.defaultEngine.allRules) {
        if (rule.target == self || object_getClass(self) == rule.target) {
            [result addObject:rule];
        }
    }
    return [result copy];
}

- (nullable MTRule *)bt_trackBlockArgOfSelector:(SEL)selector callback:(BlockTrackerCallbackBlock)callback
{
    Class cls = mt_classOfTarget(self);
    
    Method originMethod = class_getInstanceMethod(cls, selector);
    if (!originMethod) {
        return nil;
    }
    const char *originType = (char *)method_getTypeEncoding(originMethod);
    if (![[NSString stringWithUTF8String:originType] containsString:@"@?"]) {
        return nil;
    }
    NSMutableArray *blockArgIndex = [NSMutableArray array];
    int argIndex = 0; // return type is the first one
    while(originType && *originType)
    {
        originType = BHSizeAndAlignment(originType, NULL, NULL, NULL);
        if ([[NSString stringWithUTF8String:originType] hasPrefix:@"@?"]) {
            [blockArgIndex addObject:@(argIndex)];
        }
        argIndex++;
    }

    MTRule *rule = MTEngine.defaultEngine.rules[mt_methodDescription(self, selector)];
    if (!rule) {
        rule = [[MTRule alloc] initWithTarget:self selector:selector];
        rule.callback = callback;
        rule.blockArgIndex = [blockArgIndex copy];
    }
    return [rule apply] ? rule : nil;
}

@end
