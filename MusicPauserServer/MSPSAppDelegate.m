//
//  MSPSAppDelegate.m
//  MusicPauserServer
//
//  Created by Ori Kadosh on 22/7/13.
//

#import <sys/socket.h>
#import <sys/types.h>
#import <netinet/in.h>
#import <ScriptingBridge/ScriptingBridge.h>
#import <errno.h>
#import <stdarg.h>
#import "iTunes.h"
#import "MSPSAppDelegate.h"

// Just little-endian ascii "stop", "play" and "quer" (clever, eh?, not really)
#define STOP_VAL (0x706f7473)
#define PLAY_VAL (0x79616c70)
#define QUERY_VAL (0x72657571)

static iTunesApplication *MSPSharediTunesApplcation()
{
    static iTunesApplication *__sharediTunesApp;
    static dispatch_once_t onceToken;
    
    dispatch_once(&onceToken, ^{
        __sharediTunesApp = [SBApplication applicationWithBundleIdentifier:@"com.apple.iTunes"];
    });
    
    return __sharediTunesApp;
}

static void MSPListeningSocketCallback(CFSocketRef socket,
                                       CFSocketCallBackType type,
                                       CFDataRef address,
                                       const void *fdPtr,
                                       void *info)
{
    CFReadStreamRef readStream;
    CFWriteStreamRef writeStream;
    NSInputStream *inputStream;
    NSOutputStream *outputStream;
    uint32_t receivedCommand;
    
    CFStreamCreatePairWithSocket(kCFAllocatorDefault, *(const int *)fdPtr, &readStream, &writeStream);
    
    CFReadStreamSetProperty(readStream, kCFStreamPropertyShouldCloseNativeSocket, kCFBooleanTrue);
    CFWriteStreamSetProperty(writeStream, kCFStreamPropertyShouldCloseNativeSocket, kCFBooleanTrue);
    
    inputStream = (NSInputStream *)readStream;
    outputStream = (NSOutputStream *)writeStream;
    
    [inputStream open];
    [outputStream open];
    
    NSInteger receivedLength = [inputStream read:(uint8_t *)&receivedCommand maxLength:sizeof(receivedCommand)];
        
    if (receivedLength == sizeof(receivedCommand)) {
        
        iTunesApplication *iTunes = MSPSharediTunesApplcation();
        
        if (receivedCommand == STOP_VAL) {
            [iTunes pause];
        } else if (receivedCommand == PLAY_VAL) {
            [iTunes playOnce:NO];
        } else if (receivedCommand == QUERY_VAL) {
            uint32_t isPlaying = [iTunes playerState] == iTunesEPlSPlaying ? 1 : 0;
            [outputStream write:(uint8_t *)&isPlaying maxLength:sizeof(isPlaying)];
        } else {
            NSLog(@"Unknown command! %d", receivedCommand);
        }
    }
    
    [inputStream close];
    [outputStream close];
    
    CFRelease(readStream);
    CFRelease(writeStream);
}

@interface MSPSAppDelegate ()

@property (nonatomic, retain) NSNetService *meService;
@property (nonatomic, retain) NSStatusItem *statusBarItem;
@property (nonatomic, assign) CFSocketRef ipv4Socket;
@property (nonatomic, assign) CFSocketRef ipv6Socket;
@property (nonatomic, assign) CFRunLoopSourceRef ipv4SocketRunLoop;
@property (nonatomic, assign) CFRunLoopSourceRef ipv6SocketRunLoop;

@end

@implementation MSPSAppDelegate

- (void)setupStatusBarMenu
{
    NSStatusBar *bar = [NSStatusBar systemStatusBar];
    
    self.statusBarItem = [bar statusItemWithLength:NSVariableStatusItemLength];
    
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"MusicPauser"];
    NSMenuItem *menuItem = [menu insertItemWithTitle:@"Quit" action:@selector(terminate:) keyEquivalent:@"" atIndex:0];
    [menuItem setTarget:NSApp];
    
    [self.statusBarItem setTitle:@"MusicPauser"];
    [self.statusBarItem setHighlightMode:YES];
    [self.statusBarItem setMenu:[menu autorelease]];
}

- (void)terminateWithErrorString:(NSString *)errorFmt, ...
{
    va_list stringArgs;
    
    va_start(stringArgs, errorFmt);
    
    NSString *formattedErrorString = [[NSString alloc] initWithFormat:errorFmt arguments:stringArgs];
    
    va_end(stringArgs);

    NSAlert *alert = [NSAlert alertWithMessageText:@"Error!" defaultButton:@"Dismiss" alternateButton:nil otherButton:nil informativeTextWithFormat:@"%@\nMusicPauser will now terminate.", formattedErrorString];
    [alert runModal];
    
    [formattedErrorString release];
    
    [NSApp terminate:self];
}

//returns the created socket. Terimnates the app if an error occurred. outPort will hold the selected port upon return.
- (int)startIPv4BerkeleySocketOutPort:(int *)outPort
{
    int fd;
    struct sockaddr_in sin4 = {0};
    int errResult;
    socklen_t addrLen = sizeof(sin4);

    sin4.sin_family = AF_INET;
    sin4.sin_len = sizeof(sin4);
    sin4.sin_port = 0;
    
    fd = socket(AF_INET, SOCK_STREAM, 0);
    if (-1 == fd) {
        [self terminateWithErrorString:@"socket() IPv4 socket failed, reason: %s (err == %d)", strerror(errno), fd];
    }
    
    errResult = bind(fd, (struct sockaddr *)&sin4, sin4.sin_len);
    if (-1 == errResult) {
        [self terminateWithErrorString:@"bind() IPv4 socket failed, reason: %s (err == %d)", strerror(errno), errResult];
    }
    
    errResult = getsockname(fd, (struct sockaddr *)&sin4, &addrLen);
    if (-1 == errResult) {
        [self terminateWithErrorString:@"getsockname() IPv4 socket failed, reason: %s (err == %d)", strerror(errno), errResult];
    }
    
    errResult = listen(fd, 10);
    if (-1 == errResult) {
        [self terminateWithErrorString:@"listen() IPv4 socket failed, reason: %s (err == %d)", strerror(errno), errResult];
    }
    
    *outPort = sin4.sin_port;
    
    return fd;
}

- (int)startIPv6BerkeleySocketWithPort:(int)port
{
    struct sockaddr_in6 sin6 = {0};
    sin6.sin6_family = AF_INET6;
    sin6.sin6_len = sizeof(sin6);
    int errResult;
    int fd;
    
    fd = socket(AF_INET6, SOCK_STREAM, 0);
    if (-1 == fd) {
        [self terminateWithErrorString:@"socket() IPv6 socket failed, reason: %s (err == %d)", strerror(errno), fd];
    }
    
    //Enable IPv6 ONLY on the socket (this is what bonjour wants..)
    int trueValue = YES;
    errResult = setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &trueValue, sizeof(trueValue));
    if (-1 == errResult) {
        [self terminateWithErrorString:@"setsockopt() IPv6 socket failed, reason: %s (err == %d)", strerror(errno), errResult];
    }
    
    sin6.sin6_port = port;
    
    errResult = bind(fd, (struct sockaddr *)&sin6, sin6.sin6_len);
    if (-1 == errResult) {
        [self terminateWithErrorString:@"bind() IPv6 socket failed, reason: %s (err == %d)", strerror(errno), errResult];
    }
    
    errResult = listen(fd, 10);
    if (-1 == errResult) {
        [self terminateWithErrorString:@"listen() IPv6 socket failed, reason: %s (err == %d)", strerror(errno), errResult];
    }

    return fd;
}

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification
{
    CFSocketContext context = {0};
    int port;
    
    //Activate the menu bar status item
    [self setupStatusBarMenu];
    
    //Create the IPv4 and IPv6 sockets.
    int sfd4 = [self startIPv4BerkeleySocketOutPort:&port];
    int sfd6 = [self startIPv6BerkeleySocketWithPort:port];
    
    //Create CFSockets with the BSD ones, add them to the current run loop
    self.ipv4Socket = CFSocketCreateWithNative(kCFAllocatorDefault, sfd4, kCFSocketAcceptCallBack, MSPListeningSocketCallback, &context);
    self.ipv4SocketRunLoop = CFSocketCreateRunLoopSource(kCFAllocatorDefault, self.ipv4Socket, 0);
    CFRunLoopAddSource(CFRunLoopGetCurrent(), self.ipv4SocketRunLoop, kCFRunLoopCommonModes);
    
    self.ipv6Socket = CFSocketCreateWithNative(kCFAllocatorDefault, sfd6, kCFSocketAcceptCallBack, MSPListeningSocketCallback, &context);
    self.ipv6SocketRunLoop = CFSocketCreateRunLoopSource(kCFAllocatorDefault, self.ipv6Socket, 0);
    CFRunLoopAddSource(CFRunLoopGetCurrent(), self.ipv6SocketRunLoop, kCFRunLoopCommonModes);
    
    //Publish the MusicPauser NSNetService.
    self.meService = [[[NSNetService alloc] initWithDomain:@"" type:@"_musicpauser._tcp." name:@"" port:ntohs(port)] autorelease];
    [self.meService scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSRunLoopCommonModes];
    [self.meService publish];
}

- (void)dealloc
{
    [_meService release];
    [_statusBarItem release];
    
    CFRelease(self.ipv6SocketRunLoop);
    CFRelease(self.ipv6Socket);
    CFRelease(self.ipv4Socket);
    CFRelease(self.ipv4SocketRunLoop);
    
    [super dealloc];
}

@end
