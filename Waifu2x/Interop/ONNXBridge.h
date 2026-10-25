#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSString *W2XRuntimeVersion(void);
@interface W2XTensor : NSObject
@property(nonatomic, readonly) NSData *data;
@property(nonatomic, readonly) NSArray<NSNumber *> *shape;
@property(nonatomic, readonly) BOOL integer;
- (instancetype)initWithData:(NSData *)data shape:(NSArray<NSNumber *> *)shape integer:(BOOL)integer;
@end
@interface W2XSession : NSObject
- (nullable instancetype)initWithPath:(NSString *)path provider:(NSString *)provider inputShape:(NSArray<NSNumber *> *)inputShape error:(NSError **)error;
- (nullable instancetype)initWithPath:(NSString *)path provider:(NSString *)provider inputShape:(NSArray<NSNumber *> *)inputShape threadCount:(NSInteger)threadCount error:(NSError **)error;
- (nullable NSDictionary<NSString *, W2XTensor *> *)run:(NSDictionary<NSString *, W2XTensor *> *)inputs error:(NSError **)error;
- (void)cancel;
+ (NSArray<NSString *> *)availableProviders;
@end
NS_ASSUME_NONNULL_END
