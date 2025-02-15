/*****************************************************************************
 **
 ** FinalBurn X: FinalBurn for macOS
 ** https://github.com/0xe1f/FinalBurn-X
 ** Copyright (C) Akop Karapetyan
 **
 ** Licensed under the Apache License, Version 2.0 (the "License");
 ** you may not use this file except in compliance with the License.
 ** You may obtain a copy of the License at
 **
 **     http://www.apache.org/licenses/LICENSE-2.0
 **
 ** Unless required by applicable law or agreed to in writing, software
 ** distributed under the License is distributed on an "AS IS" BASIS,
 ** WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 ** See the License for the specific language governing permissions and
 ** limitations under the License.
 **
 ******************************************************************************
 */
#import "FXInput.h"

#import "FXAppDelegate.h"

#import "FXManifest.h"
#import "FXInputConstants.h"
#import "FXButtonMap.h"
#import "FXDIPState.h"
#import "FXInputConfig.h"

#include "burner.h"
#include "burnint.h"
#include "driverlist.h"

//#define DEBUG_KEY_STATE
//#define DEBUG_GP

@interface FXInput()

- (void) releaseAllKeys;
- (void) initializeInput;

- (void) restoreInputMap;
- (void) saveInputMap;

- (int) remap:(FXButtonMap *) map
	 toPlayer:(int) playerIndex
   deviceCode:(int) deviceCode;
- (FXButtonMap *) defaultKeyboardMap;
- (FXButtonMap *) defaultGamepadMap:(AKGamepad *) gamepad;
- (void) didReceiveDIPNotification:(NSNotification *) notification;

@end

@implementation FXInput
{
	BOOL _hasFocus;
	BOOL _inputStates[256];
	FXDriver *_driver;
	FXButtonMap *_keyboardMap;
	int *_playerCodeOffsets;
	int _playerCount;
	int _playerInputSpan;
	int _resetInputCode;
	int _diagInputCode;
}

#pragma mark - Init, dealloc

- (instancetype) initWithDriver:(FXDriver *) driver
{
    if ((self = [super init]) != nil) {
		_ready = NO;
		_playerCount = 1;
		_playerInputSpan = 0;
		_driver = driver;
		_playerCodeOffsets = NULL;
		[[AKGamepadManager sharedInstance] addObserver:self];

		[[NSNotificationCenter defaultCenter] addObserver:self
												 selector:@selector(didReceiveDIPNotification:)
													 name:FXDIPStateChanged
												   object:nil];
    }

    return self;
}

- (void) dealloc
{
	free(_playerCodeOffsets);
	_playerCodeOffsets = NULL;

	// Release all virtual keys
    [self releaseAllKeys];
    
    // Stop listening for key events
    [[AKKeyboardManager sharedInstance] removeObserver:self];
	[[AKGamepadManager sharedInstance] removeObserver:self];

	[[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Notifications

- (void) didReceiveDIPNotification:(NSNotification *) notification
{
	FXDIPState *state = [notification object];
	if ([[state driverName] isEqualToString:[_driver name]]) {
		NSLog(@"Updating DIP switches");
		[self updateDIPSwitches:state];
	}
}

#pragma mark - Core callbacks

- (BOOL) isInputActiveForCode:(int) inputCode
{
    if (inputCode < 0) {
        return NO;
    }
    
	BOOL isPressed;
    if (inputCode == _resetInputCode) {
        if ((isPressed = [self isResetPressed])) {
            [self setResetPressed:NO];
        }
    } else if (inputCode == _diagInputCode) {
        if ((isPressed = [self isTestPressed])) {
            [self setTestPressed:NO];
        }
	} else {
		isPressed = _inputStates[inputCode];
	}
	
	return isPressed;
}

- (void) initializeInput
{
	NSArray<FXButton *> *buttons = [_driver buttons];

	// Build a map that convert a P1 virtual code to Px virtual code
	// Figure out the array dimensions
	_ready = YES;
	_playerCount = 1;
	_playerInputSpan = 0;
	_resetInputCode = -1;
	_diagInputCode = -1;
	NSMutableDictionary<NSString *, NSNumber *> *nameToIndexMap = [NSMutableDictionary dictionary];
	[buttons enumerateObjectsUsingBlock:^(FXButton *b, NSUInteger idx, BOOL *stop) {
		_playerCount = MAX(_playerCount, [b playerIndex]);
		if ([b playerIndex] == 1) {
			[nameToIndexMap setObject:@([b code]) forKey:[b neutralName]];
			_playerInputSpan = MAX(_playerInputSpan, [b code]);
		}
		if ([[b name] isEqualToString:@"reset"]) {
			_resetInputCode = [b code];
		} else if ([[b name] isEqualToString:@"diag"]) {
			_diagInputCode = [b code];
		}
	}];
	_playerInputSpan++;
	if (_playerCodeOffsets) {
		free(_playerCodeOffsets);
	}
	
	int arraySize = sizeof(int) * _playerCount * _playerInputSpan;
	_playerCodeOffsets = (int *) malloc(arraySize);
	memset(_playerCodeOffsets, 0xff, arraySize);

    [buttons enumerateObjectsUsingBlock:^(FXButton *b, NSUInteger idx, BOOL *stop) {
		GameInp[idx].nInput = GIT_SWITCH;
		GameInp[idx].Input.Switch.nCode = [b code];

		int playerIndex = [b playerIndex] - 1;
		NSNumber *pxIndex = [nameToIndexMap objectForKey:[b neutralName]];
		if (playerIndex >= 0 && pxIndex) {
			_playerCodeOffsets[playerIndex * _playerInputSpan + [pxIndex intValue]] = [b code];
		}
	}];

	[self updateDIPSwitches:[[[FXAppDelegate sharedInstance] emulator] dipState]];
}

#pragma mark - AKKeyboardEventDelegate

- (void) keyStateChanged:(AKKeyEventData *) event
				  isDown:(BOOL) isDown
{
#ifdef DEBUG_KEY_STATE
    if (isDown) {
        NSLog(@"keyboardKeyDown: 0x%lx", [event keyCode]);
    } else {
        NSLog(@"keyboardKeyUp: 0x%lx", [event keyCode]);
    }
#endif

	// Don't generate a KeyDown if Command is pressed
	if (([event modifierFlags] & NSCommandKeyMask) == 0 || !isDown) {
		int code = [_keyboardMap virtualCodeMatching:(int) [event keyCode]];
		if (code != FXMappingNotFound) {
			_inputStates[code] = isDown;
        } else if ([event keyCode] == AKKeyCodeP){ // 1 2 3 4
            _inputStates[[_keyboardMap virtualCodeMatching: AKKeyCodeJ]] = isDown;
            _inputStates[[_keyboardMap virtualCodeMatching: AKKeyCodeK]] = isDown;
            _inputStates[[_keyboardMap virtualCodeMatching: AKKeyCodeL]] = isDown;
            _inputStates[[_keyboardMap virtualCodeMatching: AKKeyCodeSemicolon]] = isDown;
        } else if ([event keyCode] == AKKeyCodeO){ // 3 4
            _inputStates[[_keyboardMap virtualCodeMatching: AKKeyCodeL]] = isDown;
            _inputStates[[_keyboardMap virtualCodeMatching: AKKeyCodeSemicolon]] = isDown;
        } else if ([event keyCode] == AKKeyCodeI){ // 2 3
            _inputStates[[_keyboardMap virtualCodeMatching: AKKeyCodeK]] = isDown;
            _inputStates[[_keyboardMap virtualCodeMatching: AKKeyCodeL]] = isDown;
        } else if ([event keyCode] == AKKeyCodeU){ // 1 2
            _inputStates[[_keyboardMap virtualCodeMatching: AKKeyCodeJ]] = isDown;
            _inputStates[[_keyboardMap virtualCodeMatching: AKKeyCodeK]] = isDown;
        }
	}
}

#pragma mark - AKGamepadDelegate

- (void) gamepadDidConnect:(AKGamepad *) gamepad
{
	NSString *gpId = [gamepad vendorProductString];
	FXButtonMap *map = [_config mapWithId:gpId];
	if (!map) {
		map = [self defaultGamepadMap:gamepad];
		[map setDeviceId:gpId];
		[_config setMap:map];
	}

#ifdef DEBUG_GP
	NSLog(@"Gamepad \"%@\" connected to port %i",
		  [gamepad name], (int) [gamepad index]);
#endif
}

- (void) gamepadDidDisconnect:(AKGamepad *) gamepad
{
#ifdef DEBUG_GP
	NSLog(@"Gamepad \"%@\" disconnected from port %i",
		  [gamepad name], (int) [gamepad index]);
#endif
}

- (void) gamepad:(AKGamepad *) gamepad
		xChanged:(NSInteger) newValue
		  center:(NSInteger) center
	   eventData:(AKGamepadEventData *) eventData
{
	FXButtonMap *map = [_config mapWithId:[gamepad vendorProductString]];
	if (map) {
		int leftCode = [self remap:map
						  toPlayer:(int) [gamepad index]
						deviceCode:FXGamepadLeft];
		int rightCode = [self remap:map
						   toPlayer:(int) [gamepad index]
						 deviceCode:FXGamepadRight];
		if (center - newValue > FXDeadzoneSize) {
			if (leftCode != FXMappingNotFound) {
				_inputStates[leftCode] = YES;
			}
			if (rightCode != FXMappingNotFound) {
				_inputStates[rightCode] = NO;
			}
		} else if (newValue - center > FXDeadzoneSize) {
			if (leftCode != FXMappingNotFound) {
				_inputStates[leftCode] = NO;
			}
			if (rightCode != FXMappingNotFound) {
				_inputStates[rightCode] = YES;
			}
		} else {
			if (leftCode != FXMappingNotFound) {
				_inputStates[leftCode] = NO;
			}
			if (rightCode != FXMappingNotFound) {
				_inputStates[rightCode] = NO;
			}
		}
	}
#ifdef DEBUG_GP
	NSLog(@"Joystick X: %ld (center: %ld) on gamepad %@",
		  newValue, center, gamepad);
#endif
}

- (void) gamepad:(AKGamepad *) gamepad
		yChanged:(NSInteger) newValue
		  center:(NSInteger) center
	   eventData:(AKGamepadEventData *) eventData
{
	FXButtonMap *map = [_config mapWithId:[gamepad vendorProductString]];
	if (map) {
		int upCode = [self remap:map
						toPlayer:(int) [gamepad index]
					  deviceCode:FXGamepadUp];
		int downCode = [self remap:map
						  toPlayer:(int) [gamepad index]
						deviceCode:FXGamepadDown];
		if (center - newValue > FXDeadzoneSize) {
			if (upCode != FXMappingNotFound) {
				_inputStates[upCode] = YES;
			}
			if (downCode != FXMappingNotFound) {
				_inputStates[downCode] = NO;
			}
		} else if (newValue - center > FXDeadzoneSize) {
			if (upCode != FXMappingNotFound) {
				_inputStates[upCode] = NO;
			}
			if (downCode != FXMappingNotFound) {
				_inputStates[downCode] = YES;
			}
		} else {
			if (upCode != FXMappingNotFound) {
				_inputStates[upCode] = NO;
			}
			if (downCode != FXMappingNotFound) {
				_inputStates[downCode] = NO;
			}
		}
	}
#ifdef DEBUG_GP
	NSLog(@"Joystick Y: %ld (center: %ld) on gamepad %@",
		  newValue, center, gamepad);
#endif
}

- (void) gamepad:(AKGamepad *) gamepad
		  button:(NSUInteger) index
		  isDown:(BOOL) isDown
	   eventData:(AKGamepadEventData *) eventData
{
	FXButtonMap *map = [_config mapWithId:[gamepad vendorProductString]];
	if (map) {
		int code = [self remap:map
					  toPlayer:(int) [gamepad index]
					deviceCode:(int) FXMakeButton(index)];
		if (code != FXMappingNotFound) {
			_inputStates[code] = isDown;
		}
	}
#ifdef DEBUG_GP
	NSLog(@"Button %ld %@ on gamepad %@", index, gamepad,
		  isDown ? @"down" : @"up");
#endif
}

#pragma mark - Etc

- (void)setFocus:(BOOL)focus
{
    _hasFocus = focus;
    
    if (!focus) {
#ifdef DEBUG
        NSLog(@"input/focus-");
#endif
        // Emulator has lost focus - release all virtual keys
        [self releaseAllKeys];
        
        // Stop listening for key events
        [[AKKeyboardManager sharedInstance] removeObserver:self];
    } else {
#ifdef DEBUG
        NSLog(@"input/focus+");
#endif
        // Start listening for key events
        [[AKKeyboardManager sharedInstance] addObserver:self];
    }
}

- (void)restore
{
    [self restoreInputMap];
}

- (void)save
{
    [self saveInputMap];
}

- (void) updateDIPSwitches:(FXDIPState *) state
{
	if (!_ready) {
		return;
	}
	
	NSDictionary<NSNumber *, NSNumber *> *dipStates = [state states];
	[[_driver dipswitches] enumerateObjectsUsingBlock:^(FXDIPGroup *group, NSUInteger idx, BOOL *stop) {
		FXDIPOption *option;
		NSNumber *reset = [dipStates objectForKey:@(idx)];
		if (reset) {
			option = [[group options] objectAtIndex:[reset unsignedIntegerValue]];
		} else {
			option = [[group options] objectAtIndex:[group selection]];
		}
		
		struct GameInp *pgi = GameInp + [option start];
		pgi->Input.Constant.nConst = (pgi->Input.Constant.nConst & ~[option mask]) | ([option setting] & [option mask]);
	}];
}

#pragma mark - Private

- (int) remap:(FXButtonMap *) map
	 toPlayer:(int) playerIndex
   deviceCode:(int) deviceCode
{
	if (playerIndex >= 0 && playerIndex < _playerCount) {
		int vcode = [map virtualCodeMatching:deviceCode];
		if (vcode != FXMappingNotFound) {
			return _playerCodeOffsets[playerIndex * _playerInputSpan + vcode];
		}
	}

	return FXMappingNotFound;
}

- (FXButtonMap *) defaultKeyboardMap
{
	BOOL usesSfLayout = [_driver usesStreetFighterLayout];
	FXButtonMap *map = [FXButtonMap new];
	[map setDeviceId:@"keyboard"];
	[[_driver buttons] enumerateObjectsUsingBlock:^(FXButton *b, NSUInteger idx, BOOL *stop) {
		int code = [b code];
		if ([[b name] isEqualToString:@"p1 coin"]) {
			[map mapDeviceCode:AKKeyCode5 virtualCode:code];
		} else if ([[b name] isEqualToString:@"p1 start"]) {
			[map mapDeviceCode:AKKeyCode1 virtualCode:code];
		} else if ([[b name] isEqualToString:@"p1 up"]) {
			[map mapDeviceCode:AKKeyCodeW virtualCode:code];
		} else if ([[b name] isEqualToString:@"p1 down"]) {
			[map mapDeviceCode:AKKeyCodeS virtualCode:code];
		} else if ([[b name] isEqualToString:@"p1 left"]) {
			[map mapDeviceCode:AKKeyCodeA virtualCode:code];
		} else if ([[b name] isEqualToString:@"p1 right"]) {
			[map mapDeviceCode:AKKeyCodeD virtualCode:code];
		} else if ([[b name] isEqualToString:@"p1 fire 1"]) {
			[map mapDeviceCode:AKKeyCodeJ virtualCode:code];
		} else if ([[b name] isEqualToString:@"p1 fire 2"]) {
			[map mapDeviceCode:AKKeyCodeK virtualCode:code];
		} else if ([[b name] isEqualToString:@"p1 fire 3"]) {
			[map mapDeviceCode:AKKeyCodeL virtualCode:code];
		}
		
		if (usesSfLayout) {
			if ([[b name] isEqualToString:@"p1 fire 4"]) {
				[map mapDeviceCode:AKKeyCodeU virtualCode:code];
			} else if ([[b name] isEqualToString:@"p1 fire 5"]) {
				[map mapDeviceCode:AKKeyCodeI virtualCode:code];
			} else if ([[b name] isEqualToString:@"p1 fire 6"]) {
				[map mapDeviceCode:AKKeyCodeO virtualCode:code];
			}
		} else {
			if ([[b name] isEqualToString:@"p1 fire 4"]) {
                [map mapDeviceCode:AKKeyCodeSemicolon virtualCode:code];
			}
		}
	}];
	
	return map;
}

- (FXButtonMap *) defaultGamepadMap:(AKGamepad *) gamepad
{
	int fireButtonCount = [_driver fireButtonCount];
	FXButtonMap *map = [FXButtonMap new];
	[map setDeviceId:[gamepad vendorProductString]];
	[[_driver buttons] enumerateObjectsUsingBlock:^(FXButton *b, NSUInteger idx, BOOL *stop) {
		if ([[b name] isEqualToString:@"p1 coin"]) {
			[map mapDeviceCode:(fireButtonCount + 1) virtualCode:[b code]];
		} else if ([[b name] isEqualToString:@"p1 start"]) {
			[map mapDeviceCode:(fireButtonCount + 2) virtualCode:[b code]];
		} else if ([[b name] isEqualToString:@"p1 up"]) {
			[map mapDeviceCode:FXGamepadUp virtualCode:[b code]];
		} else if ([[b name] isEqualToString:@"p1 down"]) {
			[map mapDeviceCode:FXGamepadDown virtualCode:[b code]];
		} else if ([[b name] isEqualToString:@"p1 left"]) {
			[map mapDeviceCode:FXGamepadLeft virtualCode:[b code]];
		} else if ([[b name] isEqualToString:@"p1 right"]) {
			[map mapDeviceCode:FXGamepadRight virtualCode:[b code]];
		} else if ([[b name] isEqualToString:@"p1 fire 1"]) {
			[map mapDeviceCode:1 virtualCode:[b code]];
		} else if ([[b name] isEqualToString:@"p1 fire 2"]) {
			[map mapDeviceCode:2 virtualCode:[b code]];
		} else if ([[b name] isEqualToString:@"p1 fire 3"]) {
			[map mapDeviceCode:3 virtualCode:[b code]];
		} else if ([[b name] isEqualToString:@"p1 fire 4"]) {
			[map mapDeviceCode:4 virtualCode:[b code]];
		} else if ([[b name] isEqualToString:@"p1 fire 5"]) {
			[map mapDeviceCode:5 virtualCode:[b code]];
		} else if ([[b name] isEqualToString:@"p1 fire 6"]) {
			[map mapDeviceCode:6 virtualCode:[b code]];
		}
	}];
	
	return map;
}

- (void) restoreInputMap
{
    _config = nil;
    
    FXAppDelegate *app = [FXAppDelegate sharedInstance];
    NSString *file = [[_driver name] stringByAppendingPathExtension:@"input"];
    NSString *path = [[app inputMapPath] stringByAppendingPathComponent:file];
    
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:path isDirectory:nil]) {
        if (!(_config = [NSKeyedUnarchiver unarchiveObjectWithFile:path])) {
            NSLog(@"Error reading input configuration");
        }
    }

	if (!_config) {
		_config = [FXInputConfig new];
		[_config setMap:[self defaultKeyboardMap]];
    }

	_keyboardMap = [_config mapWithId:@"keyboard"];

	AKGamepadManager *gm = [AKGamepadManager sharedInstance];
	[[gm allConnected] enumerateObjectsUsingBlock:^(AKGamepad *gp, NSUInteger idx, BOOL *stop) {
		NSString *gpId = [gp vendorProductString];
		if (![_config mapWithId:gpId]) {
			[_config setMap:[self defaultGamepadMap:gp]];
		}
	}];
}

- (void) saveInputMap
{
    if ([_config dirty]) {
		FXAppDelegate *app = [FXAppDelegate sharedInstance];
        NSString *file = [[_driver name] stringByAppendingPathExtension:@"input"];
        NSString *path = [[app inputMapPath] stringByAppendingPathComponent:file];

        if (![NSKeyedArchiver archiveRootObject:_config
                                         toFile:path]) {
            NSLog(@"Error writing to input configuration");
		} else {
			[_config clearDirty];
		}
    }
}

- (void) releaseAllKeys
{
    memset(_inputStates, 0, sizeof(_inputStates));
}

@end

#pragma mark - FinalBurn callbacks

static int cocoaInputInit()
{
    FXInput *__weak input = [[[FXAppDelegate sharedInstance] emulator] input];
    [input initializeInput];
    
	return 0;
}

static int cocoaInputExit()
{
	return 0;
}

static int cocoaInputStart()
{
	return 0;
}

static int cocoaInputState(int nCode)
{
    FXInput *__weak input = [[[FXAppDelegate sharedInstance] emulator] input];
	return [input isInputActiveForCode:nCode] == YES;
}

struct InputInOut InputInOutCocoa = {
    cocoaInputInit,
    cocoaInputExit,
    NULL,
    cocoaInputStart,
    cocoaInputState,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
};
