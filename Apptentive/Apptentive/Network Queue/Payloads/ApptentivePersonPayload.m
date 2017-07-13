//
//  ApptentivePersonPayload.m
//  Apptentive
//
//  Created by Frank Schmitt on 4/20/17.
//  Copyright © 2017 Apptentive, Inc. All rights reserved.
//

#import "ApptentivePersonPayload.h"


@implementation ApptentivePersonPayload

- (instancetype)initWithPersonDiffs:(NSDictionary *)personDiffs {
	self = [super init];

	if (self) {
		_personDiffs = personDiffs;
	}

	return self;
}

- (NSString *)type {
	return @"person";
}

- (NSString *)path {
	return @"conversations/<cid>/person";
}

- (NSString *)method {
	return @"PUT";
}

- (NSString *)containerName {
	return @"person";
}

- (NSDictionary *)contents {
	NSMutableDictionary *contents = [super.contents mutableCopy];
	[contents addEntriesFromDictionary:self.personDiffs];

	return contents;
}

@end