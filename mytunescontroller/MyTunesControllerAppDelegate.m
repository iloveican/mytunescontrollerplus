//
//  MyTunesControllerAppDelegate.m
//  MyTunesController
//
//  Created by Toomas Vahter on 26.12.09.
//  Copyright (c) 2010 Toomas Vahter
//   * Contributor(s):
//          LRC support, zhili hu <huzhili@gmail.com>
//  This content is released under the MIT License (http://www.opensource.org/licenses/mit-license.php).
//  
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//  
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//  
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.



#import "MyTunesControllerAppDelegate.h"
#import "LyricsWindowController.h"
#import "NotificationWindowController.h"
#import "PreferencesController.h"
#import "LRCManagerController.h"
#import "iTunesController.h"
#import "StatusView.h"
#import "UserDefaults.h"
#import "basictypes.h"
#import "ImageScaler.h"


const NSTimeInterval kRefetchInterval = 0.5;

@interface MyTunesControllerAppDelegate()

- (void)_setupStatusItem;
- (void)_updateStatusItemButtons;
- (void)setLyricsForTrack:(iTunesTrack *)track;
- (void)startLRCTimer;
- (void)stopLRCTimer;
- (void)freeLRCPool;
- (void)resetLRCPoll:(NSString*)lrcFilePath;
- (void)setLrcWindowStatus:(NSString*)statusText;

@end


@implementation MyTunesControllerAppDelegate

@synthesize window;

+ (void)initialize
{
	[[NSUserDefaults standardUserDefaults] registerDefaults:[NSDictionary dictionaryWithObjectsAndKeys:
															 [NSNumber numberWithUnsignedInteger:3], CONotificationCorner,
															 [NSNumber numberWithUnsignedInteger:2], COLRCEngine, 
															 [NSNumber numberWithBool:YES], COEnableNotification,
															 nil]];
}

- (void)dealloc 
{
	[[NSDistributedNotificationCenter defaultCenter] removeObserver:self];
	[[NSUserDefaultsController sharedUserDefaultsController] removeObserver:self forKeyPath:@"values.NotificationCorner"];
	[[NSUserDefaultsController sharedUserDefaultsController] removeObserver:self forKeyPath:@"values.LRCEngine"];
	[[NSUserDefaultsController sharedUserDefaultsController] removeObserver:self forKeyPath:@"values.EnableNotification"];
	[store release];

	[self freeLRCPool];
	[lyricsController release];
	[statusItem release];
	[controllerItem release];
	if (enableNotification && notificationController) {
		[notificationController setDelegate:nil];
		[notificationController close];
		[notificationController release];
		notificationController = nil;
	}
	[preferencesController release];
	[super dealloc];
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender 
{
	return NSTerminateNow;
}

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification 
{
	[[NSUserDefaultsController sharedUserDefaultsController] addObserver:self
															  forKeyPath:@"values.NotificationCorner"
																 options:NSKeyValueObservingOptionInitial
																 context:nil];
	[[NSUserDefaultsController sharedUserDefaultsController] addObserver:self
															  forKeyPath:@"values.LRCEngine"
																 options:NSKeyValueObservingOptionInitial
																 context:nil];
	[[NSUserDefaultsController sharedUserDefaultsController] addObserver:self
															  forKeyPath:@"values.EnableNotification"
																 options:NSKeyValueObservingOptionInitial
																 context:nil];
	[[iTunesController sharedInstance] setDelegate:self];
	[self _setupStatusItem];
	[self _updateStatusItemButtons];
	fetcher = nil;
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context 
{
	if ([keyPath isEqualToString:@"values.NotificationCorner"]) {
		positionCorner = [[[NSUserDefaults standardUserDefaults] objectForKey:CONotificationCorner] unsignedIntValue];
		DeLog(@"%d", positionCorner);
		if (enableNotification && notificationController)
			[notificationController setPositionCorner:positionCorner];
	} else if ([keyPath isEqualToString:@"values.LRCEngine"]) {
		lrcEngine = [[[NSUserDefaults standardUserDefaults] objectForKey:COLRCEngine] unsignedIntValue];
		DeLog(@"%d", lrcEngine);
	} else if ([keyPath isEqualToString:@"values.EnableNotification"]) {
		enableNotification = [[[NSUserDefaults standardUserDefaults] objectForKey:COEnableNotification] boolValue];
		DeLog(@"%d", enableNotification);
	}

	else 
		[super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
}

#pragma mark Delegates

- (void)lrcPageLoadDidFinish:(NSError *)error
{
	DeLog(@"%d", [NSThread isMainThread]);
	if (error != nil) {
		NSString *pageError = @"Network error or page not exit";
		[self setLrcWindowStatus:pageError];
	}
}

- (void)lrcPageParseDidFinish:(NSError *)error
{
	DeLog(@"%@", [NSThread currentThread]);
	if (error != nil) {
		NSString *parseError = @"No lyrics available";
		[self performSelectorOnMainThread:@selector(setLrcWindowStatus:) withObject:parseError waitUntilDone:NO];
	}
}

- (void)lrcDownloadDidFinishWithArtist:(NSString *)artist Title:(NSString *)title
{
	iTunesTrack *track = [[iTunesController sharedInstance] currentTrack]; // playing track
	if ([title isEqualToString:[track name]] && [artist isEqualToString:[track artist]]) {
		// compose the lrc file key.
		NSString *lrcFileName = [NSString stringWithFormat:@"%@-%@", artist, title];
		[self stopLRCTimer];
		[self resetLRCPoll:[store getLocalLRCFile:lrcFileName]];
		[self startLRCTimer];
		DeLog(@"Starting lyrics:..");
	}
}

- (void)iTunesTrackDidChange:(iTunesTrack *)newTrack
{
	[self _updateStatusItemButtons];
	
	
	if (newTrack == nil) {
		DeLog(@"nil track.");
		// nil track either the itunes is quiting or something else happend.
		// so we stop the timer and empty the lyrics.
		[self stopLRCTimer];
		// the lyrics windows may not yet opened.
		if (lyricsController) {
			lyricsController.statusText = @"";
			lyricsController.track = nil;
			lyricsController.lyricsPool = nil;
		}
		return;
	}
	
	if ([[iTunesController sharedInstance] isPlaying] == NO) {
		if (notificationController) {
			[notificationController disappear];
		}
		[self stopLRCTimer];
		return;
	}
	
	if (lyricsController) {
		lyricsController.track = newTrack;
		[self setLyricsForTrack:newTrack];
	}
	
	// if I reused the window then text got blurred
	if (enableNotification && notificationController) {
		[notificationController setDelegate:nil];
		[notificationController close];
		[notificationController release];
		notificationController = nil;
	}
	if (enableNotification) {
		notificationController = [[NotificationWindowController alloc] init];
		[notificationController setDelegate:self];
		[notificationController.window setAlphaValue:0.0];
		[notificationController setTrack:newTrack];
		[notificationController resize];
		[notificationController setPositionCorner:positionCorner];
		[notificationController showWindow:self];
	}
}

- (void)notificationCanBeRemoved 
{
	[notificationController close];
	[notificationController release];
	notificationController = nil;
}

- (void)windowWillClose:(NSNotification *)notification
{
	NSWindow *w = [notification object];
	
	if ([w isEqualTo:lyricsController.window]) {
		
		[self stopLRCTimer];
		
		if (fetcher != nil) {
			[fetcher stop];
			[fetcher release]; 
			fetcher = nil;
		}
//		
		[store release]; store = nil;
		[lyricsController release]; lyricsController = nil;
	}
	else if ([w isEqualTo:preferencesController.window]) {
		[preferencesController release]; preferencesController = nil;
	}
	else if ([w isEqualTo:lrcManagerController.window]) {
		[lrcManagerController release]; lrcManagerController = nil;
	}
}

- (void)windowDidResize:(NSNotification*)notification 
{
	NSWindow *w = [notification object];
	
	if ([w isEqualTo:lyricsController.window]) {
		// update lyrics location.
		DeLog("window resize update lyrics.");
		NSUInteger currentLyricsId;
		NSInteger currentPosition = [[iTunesController sharedInstance] playerPosition];
		//NSString *currentLyrics = 
		// lrcpoll will be ni if there are no lyrics avaiable.
		if (lrcPool != nil) {
			[lrcPool getLyricsByTime:currentPosition lyricsID: &currentLyricsId];
			if (prevLrcItemId != currentLyricsId) {
				//lyricsController.lyricsText = currentLyrics;
				lyricsController.lyricsID = currentLyricsId;
				prevLrcItemId = currentLyricsId;
			}
		}
	}
	
}

#pragma mark Actions

- (IBAction)playPrevious:(id)sender 
{
	[[iTunesController sharedInstance] playPrevious];
}

- (IBAction)playPause:(id)sender 
{
	[[iTunesController sharedInstance] playPause];

}

- (IBAction)playNext:(id)sender 
{
	[[iTunesController sharedInstance] playNext];
}

#pragma mark Private

- (void)_aboutApp 
{
	[NSApp orderFrontStandardAboutPanel:self];
	[NSApp activateIgnoringOtherApps:YES];
}

// set the lyrics for a new track.
// try find them from local storage.
// if not exit, go download them by spide a new thread,
// then retain, for the purpose of
// non-blocking the windows notification.

- (void)setLyricsForTrack:(iTunesTrack *)track
{
	[self stopLRCTimer];
		//[self cancelLoad];
	if (track == nil) {
		return;
	}
	NSString *lrcFileName = [NSString stringWithFormat:@"%@-%@", [track artist], [track name]];
	NSString *desired_lrc;
	assert(store != nil);
	
	prevLrcItemId = NSUIntegerMax;
	desired_lrc = [store getLocalLRCFile:lrcFileName];
	if ([desired_lrc length] <= 0) {
		lyricsController.statusText = @"Trying to download lyrics";
		if (fetcher != nil) {
			[fetcher stop];
			[fetcher release];
			fetcher = nil;
		}

		fetcher = [[lrcFetcher alloc] initWithArtist:[track artist]
										  Title:[track name]
									 LRCStorage:store];
		[fetcher setDelegate:self];
		[fetcher setLrcEngine:lrcEngine];
		[fetcher start];
		
	} else {
		//lyricsController.statusText = @"";
		[self resetLRCPoll:desired_lrc];
		[self startLRCTimer];
		DeLog(@"Starting lyrics:..");	
	}

}


- (void)freeLRCPool
{
	if (lrcPool != nil) {
		[lrcPool release];
		lrcPool = nil;
	}
}

- (void)resetLRCPoll:(NSString*)lrcFilePath
{
	if (lrcPool != nil) {
		[lrcPool release];
		lrcPool = nil;
	}
	lrcPool = [[LrcTokensPool alloc] initWithFilePathAndParseLyrics:lrcFilePath];
	lyricsController.lyricsPool = [lrcPool lyrics];
}

// Create and start the timer that triggers a refetch every few seconds
- (void)startLRCTimer {
	lyricsController.statusText = @"";
	//[self stopLRCTimer];
	lrcTimer = [NSTimer scheduledTimerWithTimeInterval:kRefetchInterval target:self selector:@selector(lrcRoller:) userInfo:nil repeats:YES];
	//[lrcTimer retain];
}


// Stop the timer; prevent future loads until startTimer is called again
- (void)stopLRCTimer {
    if (lrcTimer) {
        [lrcTimer invalidate];
        [lrcTimer release];
        lrcTimer = nil;
    }
}


- (void)_openLyrics
{
	if (lyricsController == nil) {
		lyricsController = [[LyricsWindowController alloc] init];
		lyricsController.window.delegate = self;
	}
	
	if ( store == nil ) {
		store = [[LrcStorage alloc] init];
	}


	iTunesTrack *track = [[iTunesController sharedInstance] currentTrack]; // playing track
	
	lyricsController.track = track;
	[lyricsController showWindow:self];
	
	if (track != nil && [[iTunesController sharedInstance] isPlaying]) 
		// this could be nil when itunes is not running.
		[self setLyricsForTrack:track];
	
	
	[NSApp activateIgnoringOtherApps:YES];
}

- (void)lrcRoller:(NSTimer *)aTimer
{
	DeLog(@"insight timer");
	NSUInteger currentLyricsId;
	NSInteger currentPosition = [[iTunesController sharedInstance] playerPosition];
	//NSString *currentLyrics = 
	[lrcPool getLyricsByTime:currentPosition lyricsID: &currentLyricsId];
	if (prevLrcItemId != currentLyricsId) {
		DeLog(@"timer update new item.");
		//lyricsController.lyricsText = currentLyrics;
		lyricsController.lyricsID = currentLyricsId;
		prevLrcItemId = currentLyricsId;
	}
}

- (void)setLrcWindowStatus:(NSString*)statusText
{
	
	lyricsController.statusText = statusText;
	// clear old pool
	lyricsController.lyricsPool = nil;
	
}

- (void)_openPreferences 
{
	if (preferencesController == nil) {
		preferencesController = [[PreferencesController alloc] init];
		preferencesController.window.delegate = self;
	}
	
	[preferencesController showWindow:self];
	[NSApp activateIgnoringOtherApps:YES];
}

- (void)_openLRCManager 
{
	if ( store == nil ) {
		store = [[LrcStorage alloc] init];
	}
	if (lrcManagerController == nil) {
		lrcManagerController = [[LRCManagerController alloc] initWithStorage:store];
		lrcManagerController.window.delegate = self;
	}
	
	[lrcManagerController showWindow:self];
	[NSApp activateIgnoringOtherApps:YES];
}

- (void)_quitApp 
{
	[NSApp terminate:self];
}

- (void)_setupStatusItem 
{	
	NSImage *statusIcon = [NSImage imageNamed:@"status_icon.png"];
	controllerItem = [[[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength] retain];
	[controllerItem setImage:statusIcon];
	[controllerItem setHighlightMode:YES];
	
	statusItem = [[[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength] retain];
	[statusItem setImage:[NSImage imageNamed:@"blank.png"]];
	[statusItem setView:statusView];
	
	NSMenu *mainMenu = [[NSMenu alloc] init];
	[mainMenu setAutoenablesItems:NO];
	
	NSMenuItem *theItem = [mainMenu addItemWithTitle:@"About"
								  action:@selector(_aboutApp)
						   keyEquivalent:@""];
	[theItem setTarget:self];
	
	theItem = [mainMenu addItemWithTitle:@"Check for Updates..."
								  action:@selector(checkForUpdates:)
						   keyEquivalent:@""];
	[theItem setTarget:sparkle];
	
	theItem = [mainMenu addItemWithTitle:@"Preferences..."
								  action:@selector(_openPreferences)
						   keyEquivalent:@""];
	[theItem setTarget:self];
	
	[mainMenu addItem:[NSMenuItem separatorItem]];
	
	theItem = [mainMenu addItemWithTitle:@"Lyrics..."
								  action:@selector(_openLyrics)
						   keyEquivalent:@""];
	[theItem setTarget:self];
	
	theItem = [mainMenu addItemWithTitle:@"LRC Manager"
								  action:@selector(_openLRCManager)
						   keyEquivalent:@""];
	[theItem setTarget:self];
	
	[mainMenu addItem:[NSMenuItem separatorItem]];
	
	
	theItem = [mainMenu addItemWithTitle:@"Quit"
								  action:@selector(_quitApp)
						   keyEquivalent:@"q"];
	[theItem setTarget:self];
	
	[controllerItem setMenu:mainMenu];
	[mainMenu release];
}

- (void)_updateStatusItemButtons 
{
	if ([[iTunesController sharedInstance] isPlaying] == NO) {
		[playButton setImage:[NSImage imageNamed:@"play"]];
	}
	else {
		[playButton setImage:[NSImage imageNamed:@"pause"]];
	}
}

@end
