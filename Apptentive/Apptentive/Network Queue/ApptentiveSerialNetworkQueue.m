//
//  ApptentiveSerialNetworkQueue.m
//  Apptentive
//
//  Created by Frank Schmitt on 12/14/16.
//  Copyright © 2016 Apptentive, Inc. All rights reserved.
//

#import "ApptentiveSerialNetworkQueue.h"
#import "ApptentiveSerialRequest.h"
#import "ApptentiveMessageManager.h"
#import "ApptentiveBackend.h"
#import "Apptentive_Private.h"
#import "ApptentiveConversationManager.h"
#import "ApptentiveMessageSendRequest.h"
#import "ApptentiveRequestOperation.h"


@interface ApptentiveSerialNetworkQueue ()

@property (strong, readonly, nonatomic) NSManagedObjectContext *parentManagedObjectContext;
@property (assign, atomic) BOOL isResuming;
@property (strong, nonatomic) NSMutableDictionary *activeTaskProgress;

@end


@implementation ApptentiveSerialNetworkQueue

- (instancetype)initWithBaseURL:(NSURL *)baseURL SDKVersion:(NSString *)SDKVersion platform:(NSString *)platform parentManagedObjectContext:(NSManagedObjectContext *)parentManagedObjectContext {
	self = [super initWithBaseURL:baseURL SDKVersion:SDKVersion platform:platform];

	if (self) {
		_parentManagedObjectContext = parentManagedObjectContext;
		_activeTaskProgress = [NSMutableDictionary dictionary];

		self.maxConcurrentOperationCount = 1;
		_backgroundTaskIdentifier = UIBackgroundTaskInvalid;

		[self registerNotifications];
	}

	return self;
}

- (void)dealloc {
	[self unregisterNotifications];
}

- (void)resume {
	if (self.isResuming) {
		return;
	}

	self.isResuming = YES;

	NSBlockOperation *resumeBlock = [NSBlockOperation blockOperationWithBlock:^{
		NSManagedObjectContext *moc = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
		[moc setParentContext:self.parentManagedObjectContext];

		__block NSArray *queuedRequests;
		[moc performBlockAndWait:^{
			NSFetchRequest *fetchRequest = [NSFetchRequest fetchRequestWithEntityName:@"QueuedRequest"];
			fetchRequest.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:@"date" ascending:YES] ];
            fetchRequest.predicate = [NSPredicate predicateWithFormat:@"conversationIdentifier != nil"]; // make sure we don't include "anonymous" conversation here

			NSError *error;
			queuedRequests = [moc executeFetchRequest:fetchRequest error:&error];

			if (queuedRequests == nil) {
				ApptentiveLogError(@"Unable to fetch waiting network payloads.");
			}

			ApptentiveLogDebug(@"Adding %d record operations", queuedRequests.count);

			// Add an operation for every record in the queue
			for (ApptentiveSerialRequest *requestInfo in [queuedRequests copy]) {
				id<ApptentiveRequest> request;

				if ([requestInfo.path isEqualToString:@"messages"]) {
					request = [[ApptentiveMessageSendRequest alloc] initWithRequest:requestInfo];
				} else {
					request = requestInfo;
				}

				ApptentiveRequestOperation *operation = [[ApptentiveRequestOperation alloc] initWithRequest:request authToken:requestInfo.authToken delegate:self dataSource:self];

				[self addOperation:operation];
			}
		}];

		if (queuedRequests.count) {
			// Save the context after all enqueued records have been sent
			NSBlockOperation *saveBlock = [NSBlockOperation blockOperationWithBlock:^{
				[moc performBlockAndWait:^{
					NSError *saveError;
					if (![moc save:&saveError]) {
						ApptentiveLogError(@"Unable to save temporary managed object context: %@", saveError);
					}
				}];

				dispatch_async(dispatch_get_main_queue(), ^{
					NSError *parentSaveError;
					if (![moc.parentContext save:&parentSaveError]) {
						ApptentiveLogError(@"Unable to save parent managed object context: %@", parentSaveError);
					}

					if (self.backgroundTaskIdentifier != UIBackgroundTaskInvalid) {
						[[UIApplication sharedApplication] endBackgroundTask:self.backgroundTaskIdentifier];
						self.backgroundTaskIdentifier = UIBackgroundTaskInvalid;
					}
				});
			}];

			[self addOperation:saveBlock];
		}
		
		self.isResuming = NO;
	}];

	[self addOperation:resumeBlock];
}

- (void)cancelAllOperations {
	[super cancelAllOperations];

	self.isResuming = NO;
}

- (void)requestOperationDidStart:(ApptentiveRequestOperation *)operation {
	[self addActiveOperation:operation];
}

- (void)requestOperationWillRetry:(ApptentiveRequestOperation *)operation withError:(NSError *)error {
	if (error) {
		_status = ApptentiveQueueStatusError;

		[self updateMessageStatusForOperation:operation];

		ApptentiveLogError(@"%@ %@ failed with error: %@", operation.URLRequest.HTTPMethod, operation.URLRequest.URL.absoluteString, error);
	}

	ApptentiveLogInfo(@"%@ %@ will retry in %f seconds.", operation.URLRequest.HTTPMethod, operation.URLRequest.URL.absoluteString, self.backoffDelay);

	[self removeActiveOperation:operation];
}

- (void)requestOperationDidFinish:(ApptentiveRequestOperation *)operation {
	_status = ApptentiveQueueStatusGroovy;

	[self updateMessageStatusForOperation:operation];

	ApptentiveLogDebug(@"%@ %@ finished successfully.", operation.URLRequest.HTTPMethod, operation.URLRequest.URL.absoluteString);

	[self removeActiveOperation:operation];
}

- (void)requestOperation:(ApptentiveRequestOperation *)operation didFailWithError:(NSError *)error {
	_status = ApptentiveQueueStatusError;

	[self updateMessageStatusForOperation:operation];

	ApptentiveLogError(@"%@ %@ failed with error: %@. Not retrying.", operation.URLRequest.HTTPMethod, operation.URLRequest.URL.absoluteString, error);

	[self removeActiveOperation:operation];
}

#pragma mark - URL Session Data Delegate

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didSendBodyData:(int64_t)bytesSent totalBytesSent:(int64_t)totalBytesSent totalBytesExpectedToSend:(int64_t)totalBytesExpectedToSend {
	if (self.activeTaskProgress[@(task.taskIdentifier)]) {
		self.activeTaskProgress[@(task.taskIdentifier)] = [NSNumber numberWithDouble:(double)totalBytesSent / (double)totalBytesExpectedToSend];
		dispatch_async(dispatch_get_main_queue(), ^{
			[self updateProgress];
		});
	}
}

- (void)updateProgress {
	[self willChangeValueForKey:@"messageSendProgress"];

	if (self.activeTaskProgress.count == 0) {
		_messageSendProgress = nil;
	} else {
		_messageSendProgress = [self.activeTaskProgress.allValues valueForKeyPath:@"@avg.self"];
	}
	[self didChangeValueForKey:@"messageSendProgress"];
}

- (void)addActiveOperation:(ApptentiveRequestOperation *)operation {
	if ([operation.request isKindOfClass:[ApptentiveMessageSendRequest class]]) {
		dispatch_async(dispatch_get_main_queue(), ^{
			[self willChangeValueForKey:@"messageTaskCount"];
			[self.activeTaskProgress setObject:@0 forKey:@(operation.task.taskIdentifier)];
			[self didChangeValueForKey:@"messageTaskCount"];
		});
	}
}

- (void)removeActiveOperation:(ApptentiveRequestOperation *)operation {
	NSNumber *identifier = @(operation.task.taskIdentifier);

	if (self.activeTaskProgress[identifier]) {
		dispatch_async(dispatch_get_main_queue(), ^{
			[self willChangeValueForKey:@"messageTaskCount"];
			[self.activeTaskProgress removeObjectForKey:identifier];
			[self didChangeValueForKey:@"messageTaskCount"];
		});
	}
}

- (void)updateMessageStatusForOperation:(ApptentiveRequestOperation *)operation {
	ApptentiveMessageManager *manager = Apptentive.shared.backend.conversationManager.messageManager;

	for (NSOperation *operation in self.operations) {
		if ([operation isKindOfClass:[ApptentiveRequestOperation class]] && [((ApptentiveRequestOperation *)operation).request isKindOfClass:[ApptentiveMessageSendRequest class]]) {
			ApptentiveRequestOperation *messageOperation = (ApptentiveRequestOperation *)operation;
			ApptentiveMessageSendRequest *messageSendRequest = messageOperation.request;

			if (self.status == ApptentiveQueueStatusError) {
				[manager setState:ApptentiveMessageStateFailedToSend forMessageWithLocalIdentifier:messageSendRequest.messageIdentifier];
			} else if (messageOperation != operation) {
				[manager setState:ApptentiveMessageStateSending forMessageWithLocalIdentifier:messageSendRequest.messageIdentifier];
			} else {
				[manager setState:ApptentiveMessageStateSent forMessageWithLocalIdentifier:messageSendRequest.messageIdentifier];
			}
		}
	}
}

- (NSInteger)messageTaskCount {
	return self.activeTaskProgress.count;
}

#pragma mark -
#pragma mark Update missing conversation IDs

- (void)updateMissingConversationId:(NSString *)conversationId {
	// create a child context on a private concurrent queue
	NSManagedObjectContext *childContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];

	// set parent context
	[childContext setParentContext:self.parentManagedObjectContext];

	// execute the block on a background thread (this call returns immediatelly)
	[childContext performBlock:^{
        
        // fetch all the requests without a conversation id (no sorting needed)
        NSFetchRequest *fetchRequest = [NSFetchRequest fetchRequestWithEntityName:@"QueuedRequest"];
        fetchRequest.predicate = [NSPredicate predicateWithFormat:@"conversationIdentifier = nil"];
        
        NSError *fetchError;
        NSArray *queuedRequests = [childContext executeFetchRequest:fetchRequest error:&fetchError];
        if (fetchError != nil) {
            ApptentiveLogError(@"Error while fetching requests without a conversation id: %@", fetchError);
            return;
        }
        
        ApptentiveLogDebug(@"Fetched %d requests without a conversation id", queuedRequests.count);
        
        if (queuedRequests.count > 0) {
            
            // Set a new conversation identifier
            for (ApptentiveSerialRequest *requestInfo in queuedRequests) {
                requestInfo.conversationIdentifier = conversationId;
            }
            
            // save child context
            [childContext performBlockAndWait:^{
                NSError *saveError;
                if (![childContext save:&saveError]) {
                    ApptentiveLogError(@"Unable to save temporary managed object context: %@", saveError);
                }
            }];
            
            // save parent context on the main thread
            dispatch_async(dispatch_get_main_queue(), ^{
                NSError *parentSaveError;
                if (![childContext.parentContext save:&parentSaveError]) {
                    ApptentiveLogError(@"Unable to save parent managed object context: %@", parentSaveError);
                }
                
                // we call 'resume' to send everything
                [self resume];
            });
        }
	}];
}

#pragma mark -
#pragma mark Notifications

- (void)registerNotifications {
	[[NSNotificationCenter defaultCenter] addObserver:self
											 selector:@selector(conversationStateDidChangeNotification:)
												 name:ApptentiveConversationStateDidChangeNotification
											   object:nil];
}

- (void)unregisterNotifications {
	[[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)conversationStateDidChangeNotification:(NSNotification *)notification {
	ApptentiveConversation *conversation = notification.userInfo[ApptentiveConversationStateDidChangeNotificationKeyConversation];
	ApptentiveAssertNotNil(conversation);

	if (conversation.state == ApptentiveConversationStateAnonymous) {
		NSString *conversationId = conversation.identifier;
		ApptentiveAssertNotNil(conversationId);

		if (conversationId != nil) {
			[self updateMissingConversationId:conversationId];
		}
	}
}

@end
