//
//  ApptentiveCount.m
//  ApptentiveConnect
//
//  Created by Frank Schmitt on 11/16/16.
//  Copyright © 2016 Apptentive, Inc. All rights reserved.
//

#import "ApptentiveCount.h"

static NSString * const TotalCountKey = @"totalCount";
static NSString * const VersionCountKey = @"versionCount";
static NSString * const BuildCountKey = @"buildCount";
static NSString * const LastInvokedKey = @"lastInvoked";

@implementation ApptentiveCount

- (instancetype)init
{
	return [self initWithTotalCount:0 versionCount:0 buildCount:0 lastInvoked:nil];
}

- (instancetype)initWithTotalCount:(NSInteger)totalCount versionCount:(NSInteger)versionCount buildCount:(NSInteger)buildCount lastInvoked:(NSDate *)date {
	self = [super init];
	if (self) {
		_totalCount = totalCount;
		_versionCount = versionCount;
		_buildCount = buildCount;
		_lastInvoked = date;
	}
	return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
	self = [super initWithCoder:coder];
	if (self) {
		_totalCount = [coder decodeIntegerForKey:TotalCountKey];
		_versionCount = [coder decodeIntegerForKey:VersionCountKey];
		_buildCount = [coder decodeIntegerForKey:BuildCountKey];
		_lastInvoked = [coder decodeObjectOfClass:[NSDate class] forKey:LastInvokedKey];
	}
	return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
	[super encodeWithCoder:coder];
	[coder encodeInteger:self.totalCount forKey:TotalCountKey];
	[coder encodeInteger:self.versionCount forKey:VersionCountKey];
	[coder encodeInteger:self.buildCount forKey:BuildCountKey];
	[coder encodeObject:self.lastInvoked forKey:LastInvokedKey];
}

- (void)resetAll {
	@synchronized (self) {
		_totalCount = 0;
		_versionCount = 0;
		_buildCount = 0;
		_lastInvoked = nil;
	}
}

- (void)resetVersion {
	_versionCount = 0;
}

- (void)resetBuild {
	_buildCount = 0;
}

- (void)invoke {
	@synchronized (self) {
		_versionCount ++;
		_buildCount ++;
		_totalCount ++;
		_lastInvoked = [NSDate date]; // TODO: inject as dependency?
	}
}

@end

@implementation ApptentiveCount (JSON)

- (NSNumber *)boxedTotalCount {
	return @(self.totalCount);
}

- (NSNumber *)boxedVersionCount {
	return @(self.versionCount);
}

- (NSNumber *)boxedBuildCount {
	return @(self.buildCount);
}

- (NSNumber *)lastInvokedTimestamp {
	return @(self.lastInvoked.timeIntervalSince1970); // TODO: Is this the right format?
}

+ (NSDictionary *)JSONKeyPathMapping {
	return @{
		 @"totalCount": NSStringFromSelector(@selector(boxedTotalCount)),
		 @"versionCount": NSStringFromSelector(@selector(boxedVersionCount)),
		 @"buildCount": NSStringFromSelector(@selector(boxedBuildCount)),
		 @"lastInvoked": NSStringFromSelector(@selector(lastInvokedTimestamp))
	};
}

@end