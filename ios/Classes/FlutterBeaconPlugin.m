#import "FlutterBeaconPlugin.h"
#import <CoreBluetooth/CoreBluetooth.h>
#import <CoreLocation/CoreLocation.h>
#import "FBUtils.h"
#import "FBBluetoothStateHandler.h"
#import "FBRangingStreamHandler.h"
#import "FBMonitoringStreamHandler.h"
#import "FBAuthorizationStatusHandler.h"

@interface FlutterBeaconPlugin() <CLLocationManagerDelegate, CBCentralManagerDelegate>

@property (strong, nonatomic) CLLocationManager *locationManager;
@property (strong, nonatomic) CBCentralManager *bluetoothManager;
@property (strong, nonatomic) NSMutableArray *regionRanging;
@property (strong, nonatomic) NSMutableArray *regionMonitoring;

@property (strong, nonatomic) FBRangingStreamHandler* rangingHandler;
@property (strong, nonatomic) FBMonitoringStreamHandler* monitoringHandler;
@property (strong, nonatomic) FBBluetoothStateHandler* bluetoothHandler;
@property (strong, nonatomic) FBAuthorizationStatusHandler* authorizationHandler;

@property FlutterResult flutterResult;
@property FlutterResult flutterBluetoothResult;

@end

@implementation FlutterBeaconPlugin{
    FlutterEngine *_headlessRunner;
    NSUserDefaults *_persistentState;
    NSObject<FlutterPluginRegistrar> *_registrar;
    FlutterMethodChannel *_callbackChannel;
    FlutterMethodChannel *_mainChannel;
    NSMutableArray *_eventQueue;
}

static FlutterPluginRegistrantCallback registerPlugins = nil;
static NSString * _Nonnull kCallbackMapping = @"monitoring_callback_mapping";
static BOOL backgroundIsolateRun = NO;
static BOOL initialized = NO;

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
    FlutterMethodChannel* channel = [FlutterMethodChannel methodChannelWithName:@"flutter_beacon"
                                                                binaryMessenger:[registrar messenger]];
    FlutterBeaconPlugin* instance = [[FlutterBeaconPlugin alloc] initWithRegistrar: registrar];
    [registrar addMethodCallDelegate:instance channel:channel];
    
    instance.rangingHandler = [[FBRangingStreamHandler alloc] initWithFlutterBeaconPlugin:instance];
    FlutterEventChannel* streamChannelRanging =
    [FlutterEventChannel eventChannelWithName:@"flutter_beacon_event"
                              binaryMessenger:[registrar messenger]];
    [streamChannelRanging setStreamHandler:instance.rangingHandler];
    
    instance.monitoringHandler = [[FBMonitoringStreamHandler alloc] initWithFlutterBeaconPlugin:instance];
    FlutterEventChannel* streamChannelMonitoring =
    [FlutterEventChannel eventChannelWithName:@"flutter_beacon_event_monitoring"
                              binaryMessenger:[registrar messenger]];
    [streamChannelMonitoring setStreamHandler:instance.monitoringHandler];
    
    instance.bluetoothHandler = [[FBBluetoothStateHandler alloc] initWithFlutterBeaconPlugin:instance];
    FlutterEventChannel* streamChannelBluetooth =
    [FlutterEventChannel eventChannelWithName:@"flutter_bluetooth_state_changed"
                              binaryMessenger:[registrar messenger]];
    [streamChannelBluetooth setStreamHandler:instance.bluetoothHandler];
    
    instance.authorizationHandler = [[FBAuthorizationStatusHandler alloc] initWithFlutterBeaconPlugin:instance];
    FlutterEventChannel* streamChannelAuthorization =
    [FlutterEventChannel eventChannelWithName:@"flutter_authorization_status_changed"
                              binaryMessenger:[registrar messenger]];
    [streamChannelAuthorization setStreamHandler:instance.authorizationHandler];
}

+ (void)setPluginRegistrantCallback:(FlutterPluginRegistrantCallback)callback {
  registerPlugins = callback;
}

- (instancetype)initWithRegistrar: (NSObject<FlutterPluginRegistrar> *)registrar 
{
    self = [super init];
    if (self) {
          self = [super init];
        NSAssert(self, @"super init cannot be nil");
        _persistentState = [NSUserDefaults standardUserDefaults];
        _eventQueue = [[NSMutableArray alloc] init];
        _locationManager = [[CLLocationManager alloc] init];
        [_locationManager setDelegate:self];
        [_locationManager requestAlwaysAuthorization];
        if (@available(iOS 9.0, *)) {
            _locationManager.allowsBackgroundLocationUpdates = YES;
        }

        _headlessRunner = [[FlutterEngine alloc] initWithName:@"FlutterBeaconIsolate" project:nil allowHeadlessExecution:YES];
        _registrar = registrar;

        _mainChannel = [FlutterMethodChannel methodChannelWithName:@"flutter_beacon"
                                                   binaryMessenger:[registrar messenger]];
        [registrar addMethodCallDelegate:self channel:_mainChannel];

        _callbackChannel =
            [FlutterMethodChannel methodChannelWithName:@"flutter_beacon_event_monitoring_background"
                                        binaryMessenger:_headlessRunner];
        return self;
    }
    return self;
}

- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
    NSArray *arguments = call.arguments;
    if ([@"initialize" isEqualToString:call.method]) {
        [self initializeLocationManager];
        [self initializeCentralManager];
        result(@(YES));
        return;
    }

    if ([@"initializeBackground" isEqualToString:call.method]) {
        [self initializeLocationManager];
        [self startBackgroundService:[arguments[0] longValue]];
        result(@(YES));
        return;
    }
    
    if ([@"initializeDispatch" isEqualToString:call.method]) {
        initialized = YES;
        while ([_eventQueue count] > 0) {
            NSDictionary* event = _eventQueue[0];
            [_eventQueue removeObjectAtIndex:0];
            [self sendMonitoringEvent:event];
        }
        result(@(YES));
        return;
    }
    
    if ([@"initializeAndCheck" isEqualToString:call.method]) {
        [self initializeWithResult:result];
        return;
    }
    
    if ([@"authorizationStatus" isEqualToString:call.method]) {
        [self initializeLocationManager];
        
        switch ([CLLocationManager authorizationStatus]) {
            case kCLAuthorizationStatusNotDetermined:
                result(@"NOT_DETERMINED");
                break;
            case kCLAuthorizationStatusRestricted:
                result(@"RESTRICTED");
                break;
            case kCLAuthorizationStatusDenied:
                result(@"DENIED");
                break;
            case kCLAuthorizationStatusAuthorizedAlways:
                result(@"ALWAYS");
                break;
            case kCLAuthorizationStatusAuthorizedWhenInUse:
                result(@"WHEN_IN_USE");
                break;
        }
        return;
    }
    
    if ([@"checkLocationServicesIfEnabled" isEqualToString:call.method]) {
        result(@([CLLocationManager locationServicesEnabled]));
        return;
    }
    
    if ([@"bluetoothState" isEqualToString:call.method]) {
        self.flutterBluetoothResult = result;
        [self initializeCentralManager];
        
        // Delay 2 seconds
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (self.flutterBluetoothResult) {
                switch(self.bluetoothManager.state) {
                    case CBManagerStateUnknown:
                        self.flutterBluetoothResult(@"STATE_UNKNOWN");
                        break;
                    case CBManagerStateResetting:
                        self.flutterBluetoothResult(@"STATE_RESETTING");
                        break;
                    case CBManagerStateUnsupported:
                        self.flutterBluetoothResult(@"STATE_UNSUPPORTED");
                        break;
                    case CBManagerStateUnauthorized:
                        self.flutterBluetoothResult(@"STATE_UNAUTHORIZED");
                        break;
                    case CBManagerStatePoweredOff:
                        self.flutterBluetoothResult(@"STATE_OFF");
                        break;
                    case CBManagerStatePoweredOn:
                        self.flutterBluetoothResult(@"STATE_ON");
                        break;
                }
                self.flutterBluetoothResult = nil;
            }
        });
        return;
    }
    
    if ([@"requestAuthorization" isEqualToString:call.method]) {
        if (self.locationManager) {
            self.flutterResult = result;
            [self.locationManager requestAlwaysAuthorization];
        } else {
            result(@(YES));
        }
        return;
    }
    
    if ([@"openBluetoothSettings" isEqualToString:call.method]) {
        // not implemented
    }
    
    if ([@"openLocationSettings" isEqualToString:call.method]) {
        // not implemented
    }
    
    if ([@"openApplicationSettings" isEqualToString:call.method]) {
        [[UIApplication sharedApplication] openURL:[NSURL URLWithString:UIApplicationOpenSettingsURLString]];
        result(@(YES));
        return;
    }
    
    if ([@"close" isEqualToString:call.method]) {
        [self stopRangingBeacon];
        [self stopMonitoringBeacon];
        result(@(YES));
        return;
    }

    if ([@"startMonitorRegionsInBackground" isEqualToString:call.method]) {
        [self startMonitorRegionsInBackground:arguments];
        result(@(YES));
        return;
    }


    result(FlutterMethodNotImplemented);
}

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
  // Check to see if we're being launched due to a location event.
  if (launchOptions[UIApplicationLaunchOptionsLocationKey] != nil) {
    // Restart the headless service.
    [self startBackgroundService:[self getCallbackDispatcherHandle]];
  }

  // Note: if we return NO, this vetos the launch of the application.
  return YES;
}

- (void) initializeCentralManager {
    if (!self.bluetoothManager) {
        // initialize central manager if it itsn't
        self.bluetoothManager = [[CBCentralManager alloc] initWithDelegate:self queue:dispatch_get_main_queue()];
    }
}

- (void) initializeLocationManager {
    if (!self.locationManager) {
        // initialize location manager if it itsn't
        self.locationManager = [[CLLocationManager alloc] init];
        self.locationManager.delegate = self;
    }
}

- (void)startBackgroundService:(int64_t)handle {
    [self setCallbackDispatcherHandle:handle];
    FlutterCallbackInformation *info = [FlutterCallbackCache lookupCallbackInformation:handle];
    NSAssert(info != nil, @"failed to find callback");
    NSString *entrypoint = info.callbackName;
    NSString *uri = info.callbackLibraryPath;
    [_headlessRunner runWithEntrypoint:entrypoint libraryURI:uri];
    NSAssert(registerPlugins != nil, @"failed to set registerPlugins");
    
    // Once our headless runner has been started, we need to register the application's plugins
    // with the runner in order for them to work on the background isolate. `registerPlugins` is
    // a callback set from AppDelegate.m in the main application. This callback should register
    // all relevant plugins (excluding those which require UI).
    if (!backgroundIsolateRun) {
        registerPlugins(_headlessRunner);
    }
    [_registrar addMethodCallDelegate:self channel:_callbackChannel];
    backgroundIsolateRun = YES;
}

- (int64_t)getCallbackDispatcherHandle {
  id handle = [_persistentState objectForKey:@"callback_dispatcher_handle"];
  if (handle == nil) {
    return 0;
  }
  return [handle longLongValue];
}

- (void)setCallbackDispatcherHandle:(int64_t)handle {
  [_persistentState setObject:[NSNumber numberWithLongLong:handle]
                       forKey:@"callback_dispatcher_handle"];
}

///------------------------------------------------------------
#pragma mark - Flutter Beacon Ranging
///------------------------------------------------------------

- (void) startRangingBeaconWithCall:(id)arguments {
    if (self.regionRanging) {
        [self.regionRanging removeAllObjects];
    } else {
        self.regionRanging = [NSMutableArray array];
    }
    
    NSArray *array = arguments;
    for (NSDictionary *dict in array) {
        CLBeaconRegion *region = [FBUtils regionFromDictionary:dict];
        
        if (region) {
            [self.regionRanging addObject:region];
        }
    }
    
    for (CLBeaconRegion *r in self.regionRanging) {
        NSLog(@"START: %@", r);
        [self.locationManager startRangingBeaconsInRegion:r];
    }
}

- (void) stopRangingBeacon {
    for (CLBeaconRegion *region in self.regionRanging) {
        [self.locationManager stopRangingBeaconsInRegion:region];
    }
    self.flutterEventSinkRanging = nil;
}

///------------------------------------------------------------
#pragma mark - Flutter Beacon Monitoring
///------------------------------------------------------------

- (void) startMonitorRegionsInBackground: (NSArray*)arguments {
    int64_t callbackHandle = [arguments[0] longLongValue];
    [self setCallbackHandle:callbackHandle];

    NSArray* regionInfos = [arguments subarrayWithRange: NSMakeRange(1, arguments.count - 1)];
    [self startMonitoringBeaconWithCall:regionInfos];
}

- (void)setCallbackHandle:(int64_t)handle {
  [self setCallback:[NSNumber numberWithLongLong:handle]];
}

- (int64_t)getCallbackHandleForRegionId:(NSString *)identifier {
  id handle = [self getCallback];
  if (handle == nil) {
    return 0;
  }
  return [handle longLongValue];
}

- (NSNumber *)getCallback {
  return (NSNumber *)[_persistentState objectForKey:kCallbackMapping];
}

- (void)setCallback:(NSNumber *)callbackID {
  [_persistentState setObject:callbackID forKey:kCallbackMapping];
}

- (void) startMonitoringBeaconWithCall:(id)arguments {
    if (self.regionMonitoring) {
        [self.regionMonitoring removeAllObjects];
    } else {
        self.regionMonitoring = [NSMutableArray array];
    }
    
    NSArray *array = arguments;
    for (NSDictionary *dict in array) {
        CLBeaconRegion *region = [FBUtils regionFromDictionary:dict];
        
        if (region) {
            [self.regionMonitoring addObject:region];
        }
    }
    
    for (CLBeaconRegion *r in self.regionMonitoring) {
        NSLog(@"START: %@", r);
        [self.locationManager startMonitoringForRegion:r];
    }
}

- (void) stopMonitoringBeacon {
    for (CLBeaconRegion *region in self.regionMonitoring) {
        [self.locationManager stopMonitoringForRegion:region];
    }
    self.flutterEventSinkMonitoring = nil;
}

///------------------------------------------------------------
#pragma mark - Flutter Beacon Initialize
///------------------------------------------------------------

- (void) initializeWithResult:(FlutterResult)result {
    self.flutterResult = result;
    
    [self initializeLocationManager];
    [self initializeCentralManager];
}

///------------------------------------------------------------
#pragma mark - Bluetooth Manager
///------------------------------------------------------------

- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
    NSString *message = nil;
    switch(central.state) {
        case CBManagerStateUnknown:
            if (self.flutterBluetoothResult) {
                self.flutterBluetoothResult(@"STATE_UNKNOWN");
                self.flutterBluetoothResult = nil;
                return;
            }
            message = @"CBManagerStateUnknown";
            if (self.flutterEventSinkBluetooth) {
                self.flutterEventSinkBluetooth(@"STATE_UNKNOWN");
            }
            break;
        case CBManagerStateResetting:
            if (self.flutterBluetoothResult) {
                self.flutterBluetoothResult(@"STATE_RESETTING");
                self.flutterBluetoothResult = nil;
                return;
            }
            message = @"CBManagerStateResetting";
            if (self.flutterEventSinkBluetooth) {
                self.flutterEventSinkBluetooth(@"STATE_RESETTING");
            }
            break;
        case CBManagerStateUnsupported:
            if (self.flutterBluetoothResult) {
                self.flutterBluetoothResult(@"STATE_UNSUPPORTED");
                self.flutterBluetoothResult = nil;
                return;
            }
            message = @"CBManagerStateUnsupported";
            if (self.flutterEventSinkBluetooth) {
                self.flutterEventSinkBluetooth(@"STATE_UNSUPPORTED");
            }
            break;
        case CBManagerStateUnauthorized:
            if (self.flutterBluetoothResult) {
                self.flutterBluetoothResult(@"STATE_UNAUTHORIZED");
                self.flutterBluetoothResult = nil;
                return;
            }
            message = @"CBManagerStateUnauthorized";
            if (self.flutterEventSinkBluetooth) {
                self.flutterEventSinkBluetooth(@"STATE_UNAUTHORIZED");
            }
            break;
        case CBManagerStatePoweredOff:
            if (self.flutterBluetoothResult) {
                self.flutterBluetoothResult(@"STATE_OFF");
                self.flutterBluetoothResult = nil;
                return;
            }
            message = @"CBManagerStatePoweredOff";
            if (self.flutterEventSinkBluetooth) {
                self.flutterEventSinkBluetooth(@"STATE_OFF");
            }
            break;
        case CBManagerStatePoweredOn:
            if (self.flutterBluetoothResult) {
                self.flutterBluetoothResult(@"STATE_ON");
                self.flutterBluetoothResult = nil;
                return;
            }
            if (self.flutterEventSinkBluetooth) {
                self.flutterEventSinkBluetooth(@"STATE_ON");
            }
            if ([CLLocationManager locationServicesEnabled]) {
                if ([CLLocationManager authorizationStatus] == kCLAuthorizationStatusNotDetermined) {
                    //[self.locationManager requestWhenInUseAuthorization];
                    [self.locationManager requestAlwaysAuthorization];
                    return;
                } else if ([CLLocationManager authorizationStatus] == kCLAuthorizationStatusDenied) {
                    message = @"CLAuthorizationStatusDenied";
                } else if ([CLLocationManager authorizationStatus] == kCLAuthorizationStatusRestricted) {
                    message = @"CLAuthorizationStatusRestricted";
                } else {
                    // manage scanning
                }
            } else {
                message = @"LocationServicesDisabled";
            }
    }
    
    if (self.flutterResult) {
        if (message) {
            self.flutterResult([FlutterError errorWithCode:@"Beacon" message:message details:nil]);
        } else {
            self.flutterResult(nil);
        }
    }
}

///------------------------------------------------------------
#pragma mark - Location Manager
///------------------------------------------------------------

- (void)locationManager:(CLLocationManager *)manager didChangeAuthorizationStatus:(CLAuthorizationStatus)status {
    NSString *message = nil;
    switch (status) {
        case kCLAuthorizationStatusAuthorizedAlways:
            if (self.flutterEventSinkAuthorization) {
                self.flutterEventSinkAuthorization(@"ALWAYS");
            }
            // manage scanning
            break;
        case kCLAuthorizationStatusAuthorizedWhenInUse:
            if (self.flutterEventSinkAuthorization) {
                self.flutterEventSinkAuthorization(@"WHEN_IN_USE");
            }
            // manage scanning
            break;
        case kCLAuthorizationStatusDenied:
            if (self.flutterEventSinkAuthorization) {
                self.flutterEventSinkAuthorization(@"DENIED");
            }
            message = @"CLAuthorizationStatusDenied";
            break;
        case kCLAuthorizationStatusRestricted:
            if (self.flutterEventSinkAuthorization) {
                self.flutterEventSinkAuthorization(@"RESTRICTED");
            }
            message = @"CLAuthorizationStatusRestricted";
            break;
        case kCLAuthorizationStatusNotDetermined:
            if (self.flutterEventSinkAuthorization) {
                self.flutterEventSinkAuthorization(@"NOT_DETERMINED");
            }
            message = @"CLAuthorizationStatusNotDetermined";
            break;
    }
    
    if (self.flutterResult) {
        if (message) {
            self.flutterResult([FlutterError errorWithCode:@"Beacon" message:message details:nil]);
        } else {
            self.flutterResult(nil);
        }
    }
}

-(void)locationManager:(CLLocationManager*)manager didRangeBeacons:(NSArray*)beacons inRegion:(CLBeaconRegion*)region{
    if (self.flutterEventSinkRanging) {
        NSDictionary *dictRegion = [FBUtils dictionaryFromCLBeaconRegion:region];
        
        NSMutableArray *array = [NSMutableArray array];
        for (CLBeacon *beacon in beacons) {
            NSDictionary *dictBeacon = [FBUtils dictionaryFromCLBeacon:beacon];
            [array addObject:dictBeacon];
        }
        
        self.flutterEventSinkRanging(@{
                                @"region": dictRegion,
                                @"beacons": array
                                });
    }
}

- (void)locationManager:(CLLocationManager *)manager didEnterRegion:(CLRegion *)region {
    
    CLBeaconRegion *reg;
    for (CLBeaconRegion *r in self.regionMonitoring) {
        if ([region.identifier isEqualToString:r.identifier]) {
            reg = r;
            break;
        }
    }
    
    if (reg) {
        NSDictionary *dictRegion = [FBUtils dictionaryFromCLBeaconRegion:reg];
        if (self.flutterEventSinkMonitoring) {
            self.flutterEventSinkMonitoring(@{
                @"event": @"didEnterRegion",
                @"region": dictRegion
                                            });
        }
        [self sendMonitoringEvent:@{
            @"event": @"didExitRegion",
            @"region": dictRegion
        }];
    }
}

- (void)locationManager:(CLLocationManager *)manager didExitRegion:(CLRegion *)region {
    
    CLBeaconRegion *reg;
    for (CLBeaconRegion *r in self.regionMonitoring) {
        if ([region.identifier isEqualToString:r.identifier]) {
            reg = r;
            break;
        }
    }
    
    if (reg) {
        NSDictionary *dictRegion = [FBUtils dictionaryFromCLBeaconRegion:reg];
        if (self.flutterEventSinkMonitoring) {
            self.flutterEventSinkMonitoring(@{
                @"event": @"didExitRegion",
                @"region": dictRegion
                                            });
        }
        [self sendMonitoringEvent:@{
            @"event": @"didExitRegion",
            @"region": dictRegion
        }];
    }
}

- (void)locationManager:(CLLocationManager *)manager didDetermineState:(CLRegionState)state forRegion:(CLRegion *)region {
   
    CLBeaconRegion *reg;
    for (CLBeaconRegion *r in self.regionMonitoring) {
        if ([region.identifier isEqualToString:r.identifier]) {
            reg = r;
            break;
        }
    }
    
    if (reg) {
        NSDictionary *dictRegion = [FBUtils dictionaryFromCLBeaconRegion:reg];
        NSString *stt;
        switch (state) {
            case CLRegionStateInside:
                stt = @"INSIDE";
                break;
            case CLRegionStateOutside:
                stt = @"OUTSIDE";
                break;
            default:
                stt = @"UNKNOWN";
                break;
        }
        if (self.flutterEventSinkMonitoring) {
            self.flutterEventSinkMonitoring(@{
                @"event": @"didDetermineStateForRegion",
                @"region": dictRegion,
                @"state": stt
                                            });
        }
        [self sendMonitoringEvent:@{
            @"event": @"didDetermineStateForRegion",
            @"region": dictRegion,
            @"state": stt
        }];
    }
}

- (void)sendMonitoringEvent:(NSDictionary *)eventData {
    if (initialized) {
        int64_t handle = [self getCallback].longLongValue;
        [_callbackChannel
         invokeMethod:@""
         arguments:@[@(handle), eventData]];
    } else {
        [_eventQueue addObject:eventData];
    }
}

@end
