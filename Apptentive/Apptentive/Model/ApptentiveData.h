//
//  ApptentiveData.h
//  Apptentive
//
//  Created by Andrew Wooster on 10/29/12.
//  Copyright (c) 2012 Apptentive, Inc. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <CoreData/CoreData.h>


@interface ApptentiveData : NSObject
+ (NSManagedObject *)newEntityNamed:(NSString *)entityName;
+ (NSArray *)findEntityNamed:(NSString *)entityName withPredicate:(NSPredicate *)predicate;
+ (NSArray *)findEntityNamed:(NSString *)entityName withPredicate:(NSPredicate *)predicate inContext:(NSManagedObjectContext *)context;
+ (NSManagedObject *)findEntityWithURI:(NSURL *)URL;
+ (NSUInteger)countEntityNamed:(NSString *)entityName withPredicate:(NSPredicate *)predicate;
+ (void)removeEntitiesNamed:(NSString *)entityName withPredicate:(NSPredicate *)predicate;
+ (void)deleteManagedObject:(NSManagedObject *)object;
+ (BOOL)save;
@end