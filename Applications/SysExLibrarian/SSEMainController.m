#import "SSEMainController.h"

#import <OmniBase/OmniBase.h>
#import <OmniFoundation/OmniFoundation.h>

#import "SSEMainWindowController.h"


@interface SSEMainController (Private)

- (void)_midiSetupDidChange:(NSNotification *)notification;

- (void)_inputStreamEndpointWasRemoved:(NSNotification *)notification;
- (void)_outputStreamEndpointWasRemoved:(NSNotification *)notification;

- (void)_selectFirstAvailableSource;
- (void)_selectFirstAvailableDestination;

- (void)_startListening;
- (void)_readingSysEx:(NSNotification *)notification;
- (void)_mainThreadTakeMIDIMessages:(NSArray *)messagesToTake;

- (void)_willStartSendingSysEx:(NSNotification *)notification;
- (void)_doneSendingSysEx:(NSNotification *)notification;

@end


@implementation SSEMainController

- (id)init
{
    NSNotificationCenter *center;

    if (!(self = [super init]))
        return nil;

    center = [NSNotificationCenter defaultCenter];

    inputStream = [[SMPortOrVirtualInputStream alloc] init];
    [center addObserver:self selector:@selector(_inputStreamEndpointWasRemoved:) name:SMPortOrVirtualStreamEndpointWasRemovedNotification object:inputStream];
    [center addObserver:self selector:@selector(_readingSysEx:) name:SMInputStreamReadingSysExNotification object:inputStream];
    [center addObserver:self selector:@selector(_readingSysEx:) name:SMInputStreamDoneReadingSysExNotification object:inputStream];
    [inputStream setVirtualDisplayName:NSLocalizedStringFromTableInBundle(@"Act as a destination for other programs", @"SysExLibrarian", [self bundle], "title of popup menu item for virtual destination")];
    [inputStream setVirtualEndpointName:@"SysEx Librarian"];	// TODO get this from somewhere
    [inputStream setMessageDestination:self];

    outputStream = [[SMPortOrVirtualOutputStream alloc] init];
    [center addObserver:self selector:@selector(_outputStreamEndpointWasRemoved:) name:SMPortOrVirtualStreamEndpointWasRemovedNotification object:outputStream];
    [center addObserver:self selector:@selector(_willStartSendingSysEx:) name:SMPortOutputStreamWillStartSysExSendNotification object:outputStream];
    [center addObserver:self selector:@selector(_doneSendingSysEx:) name:SMPortOutputStreamFinishedSysExSendNotification object:outputStream];
    [outputStream setIgnoresTimeStamps:YES];
    [outputStream setSendsSysExAsynchronously:YES];
    [outputStream setVirtualDisplayName:NSLocalizedStringFromTableInBundle(@"Act as a source for other programs", @"SysExLibrarian", [self bundle], "title of popup menu item for virtual source")];
    [outputStream setVirtualEndpointName:@"SysEx Librarian"];	// TODO get this from somewhere
    
    listenToMIDISetupChanges = YES;

    messages = [[NSMutableArray alloc] init];    
    messageBytesRead = 0;
    totalBytesRead = 0;

    listeningToMessages = NO;
    listenToMultipleMessages = NO;

    [center addObserver:self selector:@selector(_midiSetupDidChange:) name:SMClientSetupChangedNotification object:[SMClient sharedClient]];

    // TODO should get selected source and dest from preferences
    [self _selectFirstAvailableSource];
    [self _selectFirstAvailableDestination];

    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];

    [inputStream release];
    inputStream = nil;
    [outputStream release];
    outputStream = nil;
    [messages release];
    messages = nil;

    [super dealloc];
}

//
// API for SSEMainWindowController
//

- (NSArray *)sourceDescriptions;
{
    return [inputStream endpointDescriptions];
}

- (NSDictionary *)sourceDescription;
{
    return [inputStream endpointDescription];
}

- (void)setSourceDescription:(NSDictionary *)description;
{
    NSDictionary *oldDescription;
    BOOL savedListenFlag;

    oldDescription = [self sourceDescription];
    if (oldDescription == description || [oldDescription isEqual:description])
        return;

    savedListenFlag = listenToMIDISetupChanges;
    listenToMIDISetupChanges = NO;

    [inputStream setEndpointDescription:description];
    // TODO we don't have an undo manager yet
//    [[[self undoManager] prepareWithInvocationTarget:self] setSourceDescription:oldDescription];
//    [[self undoManager] setActionName:NSLocalizedStringFromTableInBundle(@"Change Source", @"SysExLibrarian", [self bundle], "change source undo action")];

    listenToMIDISetupChanges = savedListenFlag;

    [windowController synchronizeSources];
}

- (NSArray *)destinationDescriptions;
{
    return [outputStream endpointDescriptions];
}

- (NSDictionary *)destinationDescription;
{
    return [outputStream endpointDescription];
}

- (void)setDestinationDescription:(NSDictionary *)description;
{
    NSDictionary *oldDescription;
    BOOL savedListenFlag;

    oldDescription = [self destinationDescription];
    if (oldDescription == description || [oldDescription isEqual:description])
        return;

    savedListenFlag = listenToMIDISetupChanges;
    listenToMIDISetupChanges = NO;

    [outputStream setEndpointDescription:description];
    // TODO we don't have an undo manager yet
    //    [[[self undoManager] prepareWithInvocationTarget:self] setSourceDescription:oldDescription];
    //    [[self undoManager] setActionName:NSLocalizedStringFromTableInBundle(@"Change Source", @"SysExLibrarian", [self bundle], "change source undo action")];

    listenToMIDISetupChanges = savedListenFlag;

    [windowController synchronizeDestinations];
}

//
// Listening to sysex messages
//

- (void)listenForOneMessage;
{
    listenToMultipleMessages = NO;
    [self _startListening];
}

- (void)listenForMultipleMessages;
{
    listenToMultipleMessages = YES;
    [self _startListening];
}

- (void)cancelMessageListen;
{
    listeningToMessages = NO;
    [inputStream cancelReceivingSysExMessage];

    [messages removeAllObjects];
    messageBytesRead = 0;
    totalBytesRead = 0;
}

- (void)doneWithMultipleMessageListen;
{
    listeningToMessages = NO;
    [inputStream cancelReceivingSysExMessage];
}

- (void)getMessageCount:(unsigned int *)messageCountPtr bytesRead:(unsigned int *)bytesReadPtr totalBytesRead:(unsigned int *)totalBytesReadPtr;
{
    // There is no need to put a lock around these things, assuming that we are in the main thread.
    // messageBytesRead gets changed in a different thread, but it gets changed atomically.
    // messages and totalBytesRead are only modified in the main thread.
    OBASSERT([NSThread inMainThread])    

    if (messageCountPtr)
        *messageCountPtr = [messages count];
    if (bytesReadPtr)
        *bytesReadPtr = messageBytesRead;
    if (totalBytesReadPtr)
        *totalBytesReadPtr = totalBytesRead;
}

//
// Sending sysex messages
//

- (void)sendMessages;
{
    if (!messages || [messages count] == 0)
        return;

    sendingMessageCount = 0;
    sendingMessageIndex = 0;
    bytesToSend = 0;
    bytesSent = 0;
    
    [outputStream takeMIDIMessages:messages];

    if (sendingMessageCount > 0) {
        unsigned int messageIndex;

        bytesToSend = 0;
        for (messageIndex = 0; messageIndex < sendingMessageCount; messageIndex++)
            bytesToSend += [[messages objectAtIndex:messageIndex] fullMessageDataLength];

        [windowController showSysExSendStatus];
    }
}

- (void)cancelSendingMessages;
{
    [outputStream cancelPendingSysExSendRequests];
}

- (void)getMessageCount:(unsigned int *)messageCountPtr messageIndex:(unsigned int *)messageIndexPtr bytesToSend:(unsigned int *)bytesToSendPtr bytesSent:(unsigned int *)bytesSentPtr;
{
    OBASSERT([NSThread inMainThread])

    if (messageCountPtr)
        *messageCountPtr = sendingMessageCount;
    if (messageIndexPtr)
        *messageIndexPtr = sendingMessageIndex;
    if (bytesToSendPtr)
        *bytesToSendPtr = bytesToSend;
    if (bytesSentPtr) {
        SMSysExSendRequest *currentRequest;
        
        *bytesSentPtr = bytesSent;
        if ((currentRequest = [outputStream currentSysExSendRequest]))
            *bytesSentPtr += [currentRequest bytesSent];
    }
}


//
// SMMessageDestination protocol
//

- (void)takeMIDIMessages:(NSArray *)messagesToTake;
{
    [self queueSelector:@selector(_mainThreadTakeMIDIMessages:) withObject:messagesToTake];
}

@end


@implementation SSEMainController (Private)

- (void)_midiSetupDidChange:(NSNotification *)notification;
{
    if (listenToMIDISetupChanges) {
        [windowController synchronizeSources];
        [windowController synchronizeDestinations];
    }
}

- (void)_inputStreamEndpointWasRemoved:(NSNotification *)notification;
{
    // TODO should print a message?
    [self _selectFirstAvailableSource];
}

- (void)_outputStreamEndpointWasRemoved:(NSNotification *)notification;
{
    // TODO should print a message?
    [self _selectFirstAvailableDestination];
}

- (void)_selectFirstAvailableSource;
{
    NSArray *descriptions;

    descriptions = [inputStream endpointDescriptions];
    if ([descriptions count] > 0)
        [inputStream setEndpointDescription:[descriptions objectAtIndex:0]];
}

- (void)_selectFirstAvailableDestination;
{
    NSArray *descriptions;

    descriptions = [outputStream endpointDescriptions];
    if ([descriptions count] > 0)
        [outputStream setEndpointDescription:[descriptions objectAtIndex:0]];
}


//
// Listening to sysex messages
//

- (void)_startListening;
{
    OBASSERT(listeningToMessages == NO);
    
    [inputStream cancelReceivingSysExMessage];
        // In case a sysex message is currently being received

    [messages removeAllObjects];
    messageBytesRead = 0;
    totalBytesRead = 0;

    listeningToMessages = YES;
}

- (void)_readingSysEx:(NSNotification *)notification;
{
    // NOTE This is happening in the MIDI thread

    messageBytesRead = [[[notification userInfo] objectForKey:@"length"] unsignedIntValue];
    [windowController queueSelectorOnce:@selector(updateSysExReadIndicator)];
        // We want multiple updates to get coalesced, so only queue it once
}

- (void)_mainThreadTakeMIDIMessages:(NSArray *)messagesToTake;
{
    unsigned int messageCount, messageIndex;

    if (!listeningToMessages)
        return;

    messageCount = [messagesToTake count];
    for (messageIndex = 0; messageIndex < messageCount; messageIndex++) {
        SMMessage *message;

        message = [messagesToTake objectAtIndex:messageIndex];
        if ([message isKindOfClass:[SMSystemExclusiveMessage class]]) {
            [messages addObject:message];
            totalBytesRead += messageBytesRead;
            messageBytesRead = 0;

            [windowController updateSysExReadIndicator];
            if (listenToMultipleMessages == NO)  {
                listeningToMessages = NO;
                [windowController stopSysExReadIndicator];
                break;
            }
        }
    }
}


//
// Sending sysex messages
//

- (void)_willStartSendingSysEx:(NSNotification *)notification;
{
    sendingMessageCount++;
}

- (void)_doneSendingSysEx:(NSNotification *)notification;
{
    // NOTE This is happening in the MIDI thread, probably.
    // The request may or may not have finished successfully.
    SMSysExSendRequest *sendRequest;

    sendRequest = [[notification userInfo] objectForKey:@"sendRequest"];
    [self mainThreadPerformSelector:@selector(_mainThreadDoneSendingSysExWithBytesSent:) withInt:[sendRequest bytesSent]];
}

- (void)_mainThreadDoneSendingSysExWithBytesSent:(unsigned int)requestBytesSent;
{
    bytesSent += requestBytesSent;

    if (sendingMessageIndex + 1 >= sendingMessageCount) {
        // We're done.
        [windowController hideSysExSendStatus];
    } else {
        sendingMessageIndex++;
    }
}

@end