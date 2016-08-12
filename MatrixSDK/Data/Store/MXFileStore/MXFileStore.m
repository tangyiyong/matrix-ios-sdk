/*
 Copyright 2014 OpenMarket Ltd

 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at

 http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
 */

#import "MXFileStore.h"

#import "MXFileRoomStore.h"

#import "MXFileStoreMetaData.h"

NSUInteger const kMXFileVersion = 29;

NSString *const kMXFileStoreFolder = @"MXFileStore";
NSString *const kMXFileStoreMedaDataFile = @"MXFileStore";

NSString *const kMXFileStoreSavingMarker = @"savingMarker";

NSString *const kMXFileStoreRoomsFolder = @"rooms";
NSString *const kMXFileStoreRoomMessagesFile = @"messages";
NSString *const kMXFileStoreRoomStateFile = @"state";
NSString *const kMXFileStoreRoomAccountDataFile = @"accountData";
NSString *const kMXFileStoreRoomReadReceiptsFile = @"readReceipts";

@interface MXFileStore ()
{
    // Meta data about the store. It is defined only if the passed MXCredentials contains all information.
    // When nil, nothing is stored on the file system.
    MXFileStoreMetaData *metaData;

    // List of rooms to save on [MXStore commit]
    NSMutableArray *roomsToCommitForMessages;

    NSMutableDictionary *roomsToCommitForState;

    NSMutableDictionary<NSString*, MXRoomAccountData*> *roomsToCommitForAccountData;
    
    NSMutableArray *roomsToCommitForReceipts;

    // The path of the MXFileStore folder
    NSString *storePath;

    // The path of the temporary file created during saving process.
    NSString *savingMarkerFile;

    // The path of the rooms folder
    NSString *storeRoomsPath;

    // Flag to indicate metaData needs to be store
    BOOL metaDataHasChanged;

    // Cache used to preload room states while the store is opening.
    // It is filled on the separate thread so that the UI thread will not be blocked
    // when it will read rooms states.
    NSMutableDictionary<NSString*, NSArray*> *preloadedRoomsStates;

    // Same kind of cache for room account data.
    NSMutableDictionary<NSString*, MXRoomAccountData*> *preloadedRoomAccountData;

    // File reading and writing operations are dispatched to a separated thread.
    // The queue invokes blocks serially in FIFO order.
    // This ensures that data is stored in the expected order: MXFileStore metadata
    // must be stored after messages and state events because of the event stream token it stores.
    dispatch_queue_t dispatchQueue;
}
@end

@implementation MXFileStore

- (instancetype)init;
{
    self = [super init];
    if (self)
    {
        roomsToCommitForMessages = [NSMutableArray array];
        roomsToCommitForState = [NSMutableDictionary dictionary];
        roomsToCommitForAccountData = [NSMutableDictionary dictionary];
        roomsToCommitForReceipts = [NSMutableArray array];
        preloadedRoomsStates = [NSMutableDictionary dictionary];
        preloadedRoomAccountData = [NSMutableDictionary dictionary];

        metaDataHasChanged = NO;

        dispatchQueue = dispatch_queue_create("MXFileStoreDispatchQueue", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)openWithCredentials:(MXCredentials*)someCredentials onComplete:(void (^)())onComplete failure:(void (^)(NSError *))failure
{
    // Create the file path where data will be stored for the user id passed in credentials
    NSArray *cacheDirList = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    NSString *cachePath  = [cacheDirList objectAtIndex:0];

    credentials = someCredentials;
    storePath = [[cachePath stringByAppendingPathComponent:kMXFileStoreFolder] stringByAppendingPathComponent:credentials.userId];
    savingMarkerFile = [storePath stringByAppendingPathComponent:kMXFileStoreSavingMarker];
    storeRoomsPath = [storePath stringByAppendingPathComponent:kMXFileStoreRoomsFolder];

    /*
    Mount data corresponding to the account credentials.

    The MXFileStore needs to prepopulate its MXMemoryStore parent data from the file system before being used.
    */
    
    // Load data from the file system on a separate thread
    dispatch_async(dispatchQueue, ^(void){

        //NSLog(@"[MXFileStore] diskUsage: %@", [NSByteCountFormatter stringFromByteCount:self.diskUsage countStyle:NSByteCountFormatterCountStyleFile]);

        @autoreleasepool
        {
            [self loadMetaData];

            // Do some validations

            // Check if
            if (nil == metaData)
            {
                [self deleteAllData];
            }
            // Check store version
            else if (kMXFileVersion != metaData.version)
            {
                NSLog(@"[MXFileStore] New MXFileStore version detected");
                [self deleteAllData];
            }
            // Check credentials
            else if (nil == credentials)
            {
                [self deleteAllData];
            }
            // Check credentials
            else if (NO == [metaData.homeServer isEqualToString:credentials.homeServer]
                     || NO == [metaData.userId isEqualToString:credentials.userId]
                     || NO == [metaData.accessToken isEqualToString:credentials.accessToken])

            {
                NSLog(@"[MXFileStore] Credentials do not match");
                [self deleteAllData];
            }

            // If metaData is still defined, we can load rooms data
            if (metaData && [self checkStorageValidity])
            {
                [self loadRoomsMessages];
                [self preloadRoomsStates];
                [self preloadRoomsAccountData];
                [self loadReceipts];
            }
            
            // Else, if credentials is valid, create and store it
            if (nil == metaData && credentials.homeServer && credentials.userId && credentials.accessToken)
            {
                metaData = [[MXFileStoreMetaData alloc] init];
                metaData.homeServer = [credentials.homeServer copy];
                metaData.userId = [credentials.userId copy];
                metaData.accessToken = [credentials.accessToken copy];
                metaData.version = kMXFileVersion;
                metaDataHasChanged = YES;
                [self saveMetaData];
            }
        }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            onComplete();
        });

    });
}

- (void)diskUsageWithBlock:(void (^)(NSUInteger))block
{
    // The operation can take hundreds of milliseconds. Do it on a sepearate thread
    dispatch_async(dispatchQueue, ^(void){

        NSUInteger diskUsage = 0;

        NSArray *contents = [[NSFileManager defaultManager] subpathsOfDirectoryAtPath:storePath error:nil];
        NSEnumerator *contentsEnumurator = [contents objectEnumerator];

        NSString *file;
        while (file = [contentsEnumurator nextObject])
        {
            NSDictionary *fileAttributes = [[NSFileManager defaultManager] attributesOfItemAtPath:[storePath stringByAppendingPathComponent:file] error:nil];
            diskUsage += [[fileAttributes objectForKey:NSFileSize] intValue];
        }

        // Return the result on the main thread
        dispatch_async(dispatch_get_main_queue(), ^(void){
            block(diskUsage);
        });
    });
}


#pragma mark - MXStore
- (void)storeEventForRoom:(NSString*)roomId event:(MXEvent*)event direction:(MXTimelineDirection)direction
{
    [super storeEventForRoom:roomId event:event direction:direction];

    if (NSNotFound == [roomsToCommitForMessages indexOfObject:roomId])
    {
        [roomsToCommitForMessages addObject:roomId];
    }
}

- (void)replaceEvent:(MXEvent*)event inRoom:(NSString*)roomId
{
    [super replaceEvent:event inRoom:roomId];
    
    if (NSNotFound == [roomsToCommitForMessages indexOfObject:roomId])
    {
        [roomsToCommitForMessages addObject:roomId];
    }
}

- (void)deleteAllMessagesInRoom:(NSString *)roomId
{
    [super deleteAllMessagesInRoom:roomId];

    NSError *error;

    // Remove room messages and read receipts from file system. Keep room state
    [[NSFileManager defaultManager] removeItemAtPath:[self messagesFileForRoom:roomId] error:&error];

    // Remove Read receipts
    [[NSFileManager defaultManager] removeItemAtPath:[self readReceiptsFileForRoom:roomId] error:&error];
    
    if (NSNotFound == [roomsToCommitForMessages indexOfObject:roomId])
    {
        [roomsToCommitForMessages addObject:roomId];
    }
}

- (void)deleteRoom:(NSString *)roomId
{
    [super deleteRoom:roomId];

    NSError *error;

    // Remove the room folder from file system
    [[NSFileManager defaultManager] removeItemAtPath:[self folderForRoom:roomId] error:&error];
}

- (void)deleteAllData
{
    NSLog(@"[MXFileStore] Delete all data");

    [super deleteAllData];

    // Remove the MXFileStore and all its content
    NSError *error;
    [[NSFileManager defaultManager] removeItemAtPath:storePath error:&error];

    // And create folders back
    [[NSFileManager defaultManager] createDirectoryAtPath:storePath withIntermediateDirectories:YES attributes:nil error:nil];
    [[NSFileManager defaultManager] createDirectoryAtPath:storeRoomsPath withIntermediateDirectories:YES attributes:nil error:nil];

    // Reset data
    metaData = nil;
    [roomStores removeAllObjects];
    self.eventStreamToken = nil;
}

- (void)storePaginationTokenOfRoom:(NSString *)roomId andToken:(NSString *)token
{
    [super storePaginationTokenOfRoom:roomId andToken:token];

    if (NSNotFound == [roomsToCommitForMessages indexOfObject:roomId])
    {
        [roomsToCommitForMessages addObject:roomId];
    }
}

- (void)storeNotificationCountOfRoom:(NSString *)roomId count:(NSUInteger)notificationCount
{
    [super storeNotificationCountOfRoom:roomId count:notificationCount];
    
    if (NSNotFound == [roomsToCommitForMessages indexOfObject:roomId])
    {
        [roomsToCommitForMessages addObject:roomId];
    }
}

- (void)storeHighlightCountOfRoom:(NSString *)roomId count:(NSUInteger)highlightCount
{
    [super storeHighlightCountOfRoom:roomId count:highlightCount];
    
    if (NSNotFound == [roomsToCommitForMessages indexOfObject:roomId])
    {
        [roomsToCommitForMessages addObject:roomId];
    }
}

- (void)storeHasReachedHomeServerPaginationEndForRoom:(NSString *)roomId andValue:(BOOL)value
{
    [super storeHasReachedHomeServerPaginationEndForRoom:roomId andValue:value];

    if (NSNotFound == [roomsToCommitForMessages indexOfObject:roomId])
    {
        [roomsToCommitForMessages addObject:roomId];
    }
}

- (void)storePartialTextMessageForRoom:(NSString *)roomId partialTextMessage:(NSString *)partialTextMessage
{
    [super storePartialTextMessageForRoom:roomId partialTextMessage:partialTextMessage];
    
    if (NSNotFound == [roomsToCommitForMessages indexOfObject:roomId])
    {
        [roomsToCommitForMessages addObject:roomId];
    }
}

- (BOOL)isPermanent
{
    return YES;
}

 -(void)setEventStreamToken:(NSString *)eventStreamToken
{
    [super setEventStreamToken:eventStreamToken];
    if (metaData)
    {
        metaData.eventStreamToken = eventStreamToken;
        metaDataHasChanged = YES;
    }
}

- (NSArray *)rooms
{
    return roomStores.allKeys;
}

- (void)storeStateForRoom:(NSString*)roomId stateEvents:(NSArray*)stateEvents
{
    roomsToCommitForState[roomId] = stateEvents;
}

- (NSArray*)stateOfRoom:(NSString *)roomId
{
    // First, try to get the state from the cache
    NSArray *stateEvents = preloadedRoomsStates[roomId];

    if (!stateEvents)
    {
        stateEvents =[NSKeyedUnarchiver unarchiveObjectWithFile:[self stateFileForRoom:roomId]];

        if (NO == [NSThread isMainThread])
        {
            // If this method is called from the `dispatchQueue` thread, it means MXFileStore is preloading
            // rooms states. So, fill the cache.
            preloadedRoomsStates[roomId] = stateEvents;
        }
    }
    else
    {
        // The cache information is valid only once
        [preloadedRoomsStates removeObjectForKey:roomId];
    }

    return stateEvents;
}

- (void)storeAccountDataForRoom:(NSString *)roomId userData:(MXRoomAccountData *)accountData
{
    roomsToCommitForAccountData[roomId] = accountData;
}

- (MXRoomAccountData *)accountDataOfRoom:(NSString *)roomId
{
    // First, try to get the data from the cache
    MXRoomAccountData *roomUserdData = preloadedRoomAccountData[roomId];

    if (!roomUserdData)
    {
        roomUserdData =[NSKeyedUnarchiver unarchiveObjectWithFile:[self accountDataFileForRoom:roomId]];

        if (NO == [NSThread isMainThread])
        {
            // If this method is called from the `dispatchQueue` thread, it means MXFileStore is preloading
            // data. So, fill the cache.
            preloadedRoomAccountData[roomId] = roomUserdData;
        }
    }
    else
    {
        // The cache information is valid only once
        [preloadedRoomAccountData removeObjectForKey:roomId];
    }

    return roomUserdData;
}

- (void)setUserDisplayname:(NSString *)userDisplayname
{
    if (metaData && NO == [metaData.userDisplayName isEqualToString:userDisplayname])
    {
        metaData.userDisplayName = userDisplayname;
        metaDataHasChanged = YES;
    }
}

- (NSString *)userDisplayname
{
    return metaData.userDisplayName;
}

- (void)setUserAvatarUrl:(NSString *)userAvatarUrl
{
    if (metaData && NO == [metaData.userAvatarUrl isEqualToString:userAvatarUrl])
    {
        metaData.userAvatarUrl = userAvatarUrl;
        metaDataHasChanged = YES;
    }
}

- (NSString *)userAvatarUrl
{
    return metaData.userAvatarUrl;
}

- (void)setUserAccountData:(NSDictionary *)userAccountData
{
    if (metaData)
    {
        metaData.userAccountData = userAccountData;
        metaDataHasChanged = YES;
    }
}

- (NSDictionary *)userAccountData
{
    return metaData.userAccountData;
}

- (void)commit
{
    // Save data only if metaData exists
    if (metaData)
    {
        // Create a temporary file which will live during all the data saving
        [[NSFileManager defaultManager] createFileAtPath:savingMarkerFile contents:nil attributes:nil];
        
        [self saveRoomsMessages];
        [self saveRoomsState];
        [self saveRoomsAccountData];
        [self saveReceipts];

        // Save meta data only at the end because it is critical to save the eventStreamToken
        // after everything else.
        // If there is a crash during the commit operation, we will be able to retrieve non
        // stored data thanks to the old eventStreamToken stored at the previous commit.
        [self saveMetaData];
        
        // The data saving is completed: remove the temporary file.
        // Do it on the same GCD queue
        dispatch_async(dispatchQueue, ^(void){
            [[NSFileManager defaultManager] removeItemAtPath:savingMarkerFile error:nil];
        });
    }
}

- (void)close
{
    // Do a dummy sync dispatch on the queue
    // Once done, we are sure pending operations blocks are complete
    dispatch_sync(dispatchQueue, ^(void){
    });
}


#pragma mark - protected operations
- (MXMemoryRoomStore*)getOrCreateRoomStore:(NSString*)roomId
{
    MXFileRoomStore *roomStore = roomStores[roomId];
    if (nil == roomStore)
    {
        // MXFileStore requires MXFileRoomStore objets
        roomStore = [[MXFileRoomStore alloc] init];
        roomStores[roomId] = roomStore;
    }
    return roomStore;
}


#pragma mark - Private methods
- (NSString*)folderForRoom:(NSString*)roomId
{
    return [storeRoomsPath stringByAppendingPathComponent:roomId];
}

- (void)checkFolderExistenceForRoom:(NSString*)roomId
{
    NSString *roomFolder = [self folderForRoom:roomId];
    if (![NSFileManager.defaultManager fileExistsAtPath:roomFolder])
    {
        [[NSFileManager defaultManager] createDirectoryAtPath:roomFolder withIntermediateDirectories:YES attributes:nil error:nil];
    }
}

- (NSString*)messagesFileForRoom:(NSString*)roomId
{
    return [[storeRoomsPath stringByAppendingPathComponent:roomId] stringByAppendingPathComponent:kMXFileStoreRoomMessagesFile];
}

- (NSString*)stateFileForRoom:(NSString*)roomId
{
    return [[storeRoomsPath stringByAppendingPathComponent:roomId] stringByAppendingPathComponent:kMXFileStoreRoomStateFile];
}

- (NSString*)accountDataFileForRoom:(NSString*)roomId
{
    return [[storeRoomsPath stringByAppendingPathComponent:roomId] stringByAppendingPathComponent:kMXFileStoreRoomAccountDataFile];
}

- (NSString*)readReceiptsFileForRoom:(NSString*)roomId
{
    return [[storeRoomsPath stringByAppendingPathComponent:roomId] stringByAppendingPathComponent:kMXFileStoreRoomReadReceiptsFile];
}


#pragma mark - Storage validity
- (BOOL)checkStorageValidity
{
    // Check whether the previous saving was interrupted or not.
    if ([[NSFileManager defaultManager] fileExistsAtPath:savingMarkerFile])
    {
        NSLog(@"[MXFileStore] Warning: The previous saving was interrupted. MXFileStore has been reset to prevent file corruption.");
        [self deleteAllData];
        
        return NO;
    }
    
    return YES;
}

#pragma mark - Rooms messages
// Load the data store in files
- (void)loadRoomsMessages
{
    NSArray *roomIDArray = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:storeRoomsPath error:nil];

    NSDate *startDate = [NSDate date];
    NSLog(@"[MXFileStore] loadRoomsData:");

    for (NSString *roomId in roomIDArray)  {

        NSString *roomFile = [self messagesFileForRoom:roomId];

        MXFileRoomStore *roomStore;
        @try
        {
            roomStore =[NSKeyedUnarchiver unarchiveObjectWithFile:roomFile];
        }
        @catch (NSException *exception)
        {
            NSLog(@"[MXFileStore] Warning: MXFileRoomStore file for room %@ has been corrupted", roomId);
        }

        if (roomStore)
        {
            NSLog(@"   - %@: %@", roomId, roomStore);
            roomStores[roomId] = roomStore;

            // @TODO: Check the state file  of this room exists
        }
        else
        {
            NSLog(@"[MXFileStore] Warning: MXFileStore has been reset due to room file corruption. Room id: %@", roomId);
            [self deleteAllData];
            break;
        }
    }

    NSLog(@"[MXFileStore] Loaded room messages of %tu rooms in %.0fms", roomStores.allKeys.count, [[NSDate date] timeIntervalSinceDate:startDate] * 1000);
}

- (void)saveRoomsMessages
{
    if (roomsToCommitForMessages.count)
    {
        NSArray *roomsToCommit = [[NSArray alloc] initWithArray:roomsToCommitForMessages copyItems:YES];
        [roomsToCommitForMessages removeAllObjects];

        dispatch_async(dispatchQueue, ^(void){

            //NSDate *startDate = [NSDate date];

            // Save rooms where there was changes
            for (NSString *roomId in roomsToCommit)
            {
                MXFileRoomStore *roomStore = roomStores[roomId];
                if (roomStore)
                {
                    [self checkFolderExistenceForRoom:roomId];
                    [NSKeyedArchiver archiveRootObject:roomStore toFile:[self messagesFileForRoom:roomId]];
                }
            }

            //NSLog(@"[MXFileStore commit] lasted %.0fms for rooms:\n%@", [[NSDate date] timeIntervalSinceDate:startDate] * 1000, roomsToCommit);
        });
    }
}


#pragma mark - Rooms state
/**
 Preload states of all rooms.

 This operation must be called on the `dispatchQueue` thread to avoid blocking the main thread.
 */
- (void)preloadRoomsStates
{
    NSDate *startDate = [NSDate date];

    for (NSString *roomId in roomStores)
    {
        preloadedRoomsStates[roomId] = [self stateOfRoom:roomId];
    }

    NSLog(@"[MXFileStore] Loaded room states of %tu rooms in %.0fms", roomStores.allKeys.count, [[NSDate date] timeIntervalSinceDate:startDate] * 1000);
}

- (void)saveRoomsState
{
    if (roomsToCommitForState.count)
    {
        // Take a snapshot of room ids to store to process them on the other thread
        NSDictionary *roomsToCommit = [NSDictionary dictionaryWithDictionary:roomsToCommitForState];
        [roomsToCommitForState removeAllObjects];

        dispatch_async(dispatchQueue, ^(void){

            for (NSString *roomId in roomsToCommit)
            {
                NSArray *stateEvents = roomsToCommit[roomId];

                [self checkFolderExistenceForRoom:roomId];
                [NSKeyedArchiver archiveRootObject:stateEvents toFile:[self stateFileForRoom:roomId]];
            }
        });
    }
}


#pragma mark - Rooms account data
/**
 Preload account data of all rooms.

 This operation must be called on the `dispatchQueue` thread to avoid blocking the main thread.
 */
- (void)preloadRoomsAccountData
{
    NSDate *startDate = [NSDate date];

    for (NSString *roomId in roomStores)
    {
        preloadedRoomAccountData[roomId] = [self accountDataOfRoom:roomId];
    }

    NSLog(@"[MXFileStore] Loaded rooms account data of %tu rooms in %.0fms", roomStores.allKeys.count, [[NSDate date] timeIntervalSinceDate:startDate] * 1000);
}

- (void)saveRoomsAccountData
{
    if (roomsToCommitForAccountData.count)
    {
        // Take a snapshot of room ids to store to process them on the other thread
        NSDictionary *roomsToCommit = [NSDictionary dictionaryWithDictionary:roomsToCommitForAccountData];
        [roomsToCommitForAccountData removeAllObjects];

        dispatch_async(dispatchQueue, ^(void){

            for (NSString *roomId in roomsToCommit)
            {
                MXRoomAccountData *roomAccountData = roomsToCommit[roomId];

                [self checkFolderExistenceForRoom:roomId];
                [NSKeyedArchiver archiveRootObject:roomAccountData toFile:[self accountDataFileForRoom:roomId]];
            }
        });
    }
}


#pragma mark - Outgoing events
- (void)storeOutgoingMessageForRoom:(NSString*)roomId outgoingMessage:(MXEvent*)outgoingMessage
{
    [super storeOutgoingMessageForRoom:roomId outgoingMessage:outgoingMessage];

    if (NSNotFound == [roomsToCommitForMessages indexOfObject:roomId])
    {
        [roomsToCommitForMessages addObject:roomId];
    }
}

- (void)removeAllOutgoingMessagesFromRoom:(NSString*)roomId
{
    [super removeAllOutgoingMessagesFromRoom:roomId];

    if (NSNotFound == [roomsToCommitForMessages indexOfObject:roomId])
    {
        [roomsToCommitForMessages addObject:roomId];
    }
}

- (void)removeOutgoingMessageFromRoom:(NSString*)roomId outgoingMessage:(NSString*)outgoingMessageEventId
{
    [super removeOutgoingMessageFromRoom:roomId outgoingMessage:outgoingMessageEventId];

    if (NSNotFound == [roomsToCommitForMessages indexOfObject:roomId])
    {
        [roomsToCommitForMessages addObject:roomId];
    }
}


#pragma mark - MXFileStore metadata
- (void)loadMetaData
{
    NSString *metaDataFile = [storePath stringByAppendingPathComponent:kMXFileStoreMedaDataFile];

    @try
    {
        metaData = [NSKeyedUnarchiver unarchiveObjectWithFile:metaDataFile];
    }
    @catch (NSException *exception)
    {
        NSLog(@"[MXFileStore] Warning: MXFileStore metadata has been corrupted");
    }

    if (metaData)
    {
        self.eventStreamToken = metaData.eventStreamToken;
    }
}

- (void)saveMetaData
{
    // Save only in case of change
    if (metaDataHasChanged)
    {
        metaDataHasChanged = NO;

        // Take a snapshot of metadata to store it on the other thread
        MXFileStoreMetaData *metaData2 = [metaData copy];

        dispatch_async(dispatchQueue, ^(void){
    
            NSString *metaDataFile = [storePath stringByAppendingPathComponent:kMXFileStoreMedaDataFile];
            [NSKeyedArchiver archiveRootObject:metaData2 toFile:metaDataFile];
        });
    }
}

#pragma mark - Room receipts

/**
 * Store the receipt for an user in a room
 * @param receipt The event
 * @param roomId The roomId
 */
- (BOOL)storeReceipt:(MXReceiptData*)receipt inRoom:(NSString*)roomId
{
    if ([super storeReceipt:receipt inRoom:roomId])
    {
        if (NSNotFound == [roomsToCommitForReceipts indexOfObject:roomId])
        {
            [roomsToCommitForReceipts addObject:roomId];
        }
        return YES;
    }
    
    return NO;
}


// Load the data store in files
- (void)loadReceipts
{
    NSArray *roomIDArray = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:storeRoomsPath error:nil];
    
    NSDate *startDate = [NSDate date];
    NSLog(@"[MXFileStore] loadReceipts:");
    
    // Sanity check: check whether there are as much receipts files as room data files.
    if (roomIDArray.count != roomStores.allKeys.count)
    {
        NSLog(@"[MXFileStore] Error: MXFileStore has been reset due to file corruption (%tu read receipts files vs %tu rooms)", roomIDArray.count, roomStores.allKeys.count);

        // Log the faulty rooms
        NSMutableArray *roomDiff;
        if (roomIDArray.count > roomStores.allKeys.count)
        {
            roomDiff = [NSMutableArray arrayWithArray:roomIDArray];
            [roomDiff removeObjectsInArray:roomStores.allKeys];
        }
        else
        {
            roomDiff = [NSMutableArray arrayWithArray:roomStores.allKeys];
            [roomDiff removeObjectsInArray:roomIDArray];
        }
        NSLog(@"Rooms that are missing: %@", roomDiff);

        [self deleteAllData];
    }
    else
    {
        for (NSString *roomId in roomIDArray)
        {
            NSString *roomFile = [self readReceiptsFileForRoom:roomId];
            
            NSMutableDictionary *receiptsDict = NULL;
            @try
            {
                receiptsDict =[NSKeyedUnarchiver unarchiveObjectWithFile:roomFile];
            }
            @catch (NSException *exception)
            {
                NSLog(@"[loadReceipts] Warning: loadReceipts file for room %@ has been corrupted", roomId);
            }
            
            if (receiptsDict)
            {
                NSLog(@"   - %@: %tu", roomId, receiptsDict.count);
                
                [receiptsByRoomId setObject:receiptsDict forKey:roomId];
            }
            else
            {
                NSLog(@"[MXFileStore] Warning: MXFileStore has been reset due to receipts file corruption. Room id: %@", roomId);
                [self deleteAllData];
                break;
            }
        }
    }
    
    NSLog(@"[MXFileStore] Loaded read receipts of %lu rooms in %.0fms", (unsigned long)roomStores.allKeys.count, [[NSDate date] timeIntervalSinceDate:startDate] * 1000);
}

- (void)saveReceipts
{
    if (roomsToCommitForReceipts.count)
    {
        NSArray *roomsToCommit = [[NSArray alloc] initWithArray:roomsToCommitForReceipts copyItems:YES];
        [roomsToCommitForReceipts removeAllObjects];

        dispatch_async(dispatchQueue, ^(void){

            // Save rooms where there was changes
            for (NSString *roomId in roomsToCommit)
            {
                NSMutableDictionary* receiptsByUserId = receiptsByRoomId[roomId];
                if (receiptsByUserId)
                {
                    @synchronized (receiptsByUserId)
                    {
                        [self checkFolderExistenceForRoom:roomId];
                        BOOL success = [NSKeyedArchiver archiveRootObject:receiptsByUserId toFile:[self readReceiptsFileForRoom:roomId]];
                        if (!success)
                        {
                             NSLog(@"[MXFileStore] Error: Failed to store read receipts for room %@", roomId);
                        }
                    }
                }
            }
        });
    }
}

@end
