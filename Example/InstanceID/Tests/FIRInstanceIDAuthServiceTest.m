/*
 * Copyright 2019 Google
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#import <XCTest/XCTest.h>

#import <OCMock/OCMock.h>
#import "Firebase/InstanceID/FIRInstanceIDAuthService.h"
#import "Firebase/InstanceID/FIRInstanceIDCheckinPreferences+Internal.h"
#import "Firebase/InstanceID/FIRInstanceIDCheckinService.h"
#import "Firebase/InstanceID/FIRInstanceIDStore.h"
#import "Firebase/InstanceID/NSError+FIRInstanceID.h"

static NSString *const kDeviceAuthId = @"device-id";
static NSString *const kSecretToken = @"secret-token";
static NSString *const kDigest = @"com.google.digest";
static NSString *const kVersionInfo = @"1.0";

@interface FIRInstanceIDCheckinService ()
@property(nonatomic, readwrite, strong) FIRInstanceIDCheckinPreferences *checkinPreferences;
@end

@interface FIRInstanceIDAuthService ()
@property(atomic, readwrite, assign) int64_t lastCheckinTimestampSeconds;
@property(atomic, readwrite, assign) int64_t nextScheduledCheckinIntervalSeconds;
@property(atomic, readwrite, assign) int checkinRetryCount;
@property(nonatomic, readonly, strong)
    NSMutableArray<FIRInstanceIDDeviceCheckinCompletion> *checkinHandlers;
@end

@interface FIRInstanceIDAuthServiceTest : XCTestCase

@property(nonatomic, readwrite, strong) FIRInstanceIDAuthService *authService;
@property(nonatomic, readwrite, strong) FIRInstanceIDCheckinService *checkinService;
@property(nonatomic, readwrite, strong) id mockCheckinService;
@property(nonatomic, readwrite, strong) id mockStore;
@property(nonatomic, readwrite, copy) FIRInstanceIDDeviceCheckinCompletion checkinCompletion;

@end

@implementation FIRInstanceIDAuthServiceTest

- (void)setUp {
  [super setUp];

  _mockStore = OCMClassMock([FIRInstanceIDStore class]);
  _checkinService = [[FIRInstanceIDCheckinService alloc] init];
  _mockCheckinService = OCMPartialMock(_checkinService);
  _authService = [[FIRInstanceIDAuthService alloc] initWithCheckinService:_mockCheckinService
                                                                    store:_mockStore];
  _authService.firebaseUserAgent = @"Fake firebaseUserAgent";
  // The tests here are to focus on checkin interval not locale change, so always set locale as
  // non-changed.
  [[NSUserDefaults standardUserDefaults] setObject:FIRInstanceIDCurrentLocale()
                                            forKey:kFIRInstanceIDUserDefaultsKeyLocale];
}

- (void)tearDown {
  _checkinCompletion = nil;
  [super tearDown];
}

/**
 *  Test scheduling a checkin which completes successfully. Once the checkin is complete
 *  we should have the valid checkin preferences in memory.
 */
- (void)testScheduleCheckin_initialSuccess {
  XCTestExpectation *checkinExpectation =
      [self expectationWithDescription:@"Did call checkin service"];

  FIRInstanceIDCheckinPreferences *checkinPreferences = [self validCheckinPreferences];
  [[[self.mockCheckinService stub] andDo:^(NSInvocation *invocation) {
    self.checkinCompletion(checkinPreferences, nil);
  }] checkinWithExistingCheckin:[OCMArg any]
              firebaseUserAgent:[OCMArg isEqual:self.authService.firebaseUserAgent]
                     completion:[OCMArg checkWithBlock:^BOOL(id obj) {
                       [checkinExpectation fulfill];
                       self.checkinCompletion = obj;
                       return obj != nil;
                     }]];

  // Always return YES for whether we succeeded in persisting the checkin
  [[self.mockStore stub] saveCheckinPreferences:[OCMArg any]
                                        handler:[OCMArg invokeBlockWithArgs:[NSNull null], nil]];

  [self.authService scheduleCheckin:YES];

  XCTAssertTrue([self.authService hasValidCheckinInfo]);
  XCTAssertEqual([self.authService checkinRetryCount], 1);
  [self waitForExpectationsWithTimeout:2.0 handler:NULL];
}

/**
 *  Test scheduling a checkin which completes successfully, but fails to save, due to Keychain
 *  errors.
 */
- (void)testScheduleCheckin_successButFailureInSaving {
  XCTestExpectation *checkinFailureExpectation =
      [self expectationWithDescription:@"Did receive error after checkin"];

  FIRInstanceIDCheckinPreferences *checkinPreferences = [self validCheckinPreferences];
  [[[self.mockCheckinService stub] andDo:^(NSInvocation *invocation) {
    self.checkinCompletion(checkinPreferences, nil);
  }] checkinWithExistingCheckin:[OCMArg any]
              firebaseUserAgent:[OCMArg isEqual:self.authService.firebaseUserAgent]
                     completion:[OCMArg checkWithBlock:^BOOL(id obj) {
                       self.checkinCompletion = obj;
                       return obj != nil;
                     }]];

  // Always return NO for whether we succeeded in persisting the checkin, to simulate Keychain error
  [[self.mockStore stub] saveCheckinPreferences:[OCMArg any]
                                        handler:[OCMArg invokeBlockWithArgs:[OCMArg any], nil]];

  [self.authService
      fetchCheckinInfoWithHandler:^(FIRInstanceIDCheckinPreferences *checkin, NSError *error) {
        [checkinFailureExpectation fulfill];
      }];

  [self waitForExpectationsWithTimeout:2.0 handler:NULL];
  XCTAssertFalse([self.authService hasValidCheckinInfo]);
}

/**
 *  Test scheduling multiple checkins to complete immediately. Each successive checkin should
 *  be triggered immediately.
 */
- (void)testMultipleScheduleCheckin_immediately {
  XCTestExpectation *checkinExpectation =
      [self expectationWithDescription:@"Did call checkin service"];
  __block int checkinHandlerInvocationCount = 0;

  FIRInstanceIDCheckinPreferences *checkinPreferences = [self validCheckinPreferences];
  [[[self.mockCheckinService stub] andDo:^(NSInvocation *invocation) {
    checkinHandlerInvocationCount++;
    // Mock successful Checkin after delay.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                     [checkinExpectation fulfill];
                     self.checkinCompletion(checkinPreferences, nil);
                   });
  }] checkinWithExistingCheckin:[OCMArg any]
              firebaseUserAgent:[OCMArg isEqual:self.authService.firebaseUserAgent]
                     completion:[OCMArg checkWithBlock:^BOOL(id obj) {
                       self.checkinCompletion = obj;
                       return obj != nil;
                     }]];

  // Always return YES for whether we succeeded in persisting the checkin
  [[self.mockStore stub] saveCheckinPreferences:[OCMArg any]
                                        handler:[OCMArg invokeBlockWithArgs:[NSNull null], nil]];
  [self.authService scheduleCheckin:YES];

  // Schedule an immediate checkin again.
  // This should just return because the previous checkin isn't over yet.
  [self.authService scheduleCheckin:YES];

  [self waitForExpectationsWithTimeout:5.0 handler:NULL];
  XCTAssertTrue([self.authService hasValidCheckinInfo]);
  XCTAssertEqual([self.authService checkinRetryCount], 2);

  // Checkin handler should only be invoked once since the second checkin request should
  // return immediately.
  XCTAssertEqual(checkinHandlerInvocationCount, 1);
}

/**
 *  Test multiple checkins scheduled. The second checkin should be scheduled after some
 *  delay before the first checkin has returned. Since the latter checkin is not immediate
 *  we should not run it since the first checkin is already scheduled to be executed later.
 */
- (void)testMultipleScheduleCheckin_notImmediately {
  XCTestExpectation *checkinExpectation =
      [self expectationWithDescription:@"Did call checkin service"];

  FIRInstanceIDCheckinPreferences *checkinPreferences = [self validCheckinPreferences];
  [[[self.mockCheckinService stub] andDo:^(NSInvocation *invocation) {
    // Mock successful Checkin after delay.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                     [checkinExpectation fulfill];
                     self.checkinCompletion(checkinPreferences, nil);
                   });
  }] checkinWithExistingCheckin:[OCMArg any]
              firebaseUserAgent:[OCMArg isEqual:self.authService.firebaseUserAgent]
                     completion:[OCMArg checkWithBlock:^BOOL(id obj) {
                       self.checkinCompletion = obj;
                       return obj != nil;
                     }]];

  // Always return YES for whether we succeeded in persisting the checkin
  [[self.mockStore stub] saveCheckinPreferences:[OCMArg any]
                                        handler:[OCMArg invokeBlockWithArgs:[NSNull null], nil]];

  [self.authService scheduleCheckin:YES];

  // Schedule another checkin after some delay while the first checkin has not yet returned
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
                   [self.authService scheduleCheckin:NO];
                 });

  [self waitForExpectationsWithTimeout:5.0 handler:NULL];
  XCTAssertTrue([self.authService hasValidCheckinInfo]);
  XCTAssertEqual([self.authService checkinRetryCount], 1);
}

/**
 *  Test initial checkin failure which schedules another checkin which should succeed.
 */
- (void)testInitialCheckinFailure_retrySuccess {
  XCTestExpectation *checkinExpectation =
      [self expectationWithDescription:@"Did call checkin service"];
  __block int checkinHandlerInvocationCount = 0;

  [[[self.mockCheckinService stub] andDo:^(NSInvocation *invocation) {
    checkinHandlerInvocationCount++;

    if (checkinHandlerInvocationCount == 1) {
      // Mock failure on first try
      NSError *error = [NSError errorWithFIRInstanceIDErrorCode:kFIRInstanceIDErrorCodeTimeout];
      self.checkinCompletion(nil, error);
    } else if (checkinHandlerInvocationCount == 2) {
      // Mock success on second try
      [checkinExpectation fulfill];
      self.checkinCompletion([self validCheckinPreferences], nil);
    } else {
      // We should not retry for a third time again.
      XCTFail(@"Invoking checkin handler invalid number of times.");
    }
  }] checkinWithExistingCheckin:[OCMArg any]
              firebaseUserAgent:[OCMArg isEqual:self.authService.firebaseUserAgent]
                     completion:[OCMArg checkWithBlock:^BOOL(id obj) {
                       self.checkinCompletion = obj;
                       return obj != nil;
                     }]];

  // Always return YES for whether we succeeded in persisting the checkin
  [[self.mockStore stub] saveCheckinPreferences:[OCMArg any]
                                        handler:[OCMArg invokeBlockWithArgs:[NSNull null], nil]];

  [self.authService scheduleCheckin:YES];
  // Schedule another checkin after some delay while the first checkin has not yet returned
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
                   [self.authService scheduleCheckin:YES];
                   XCTAssertTrue([self.authService hasValidCheckinInfo]);
                   XCTAssertEqual([self.authService checkinRetryCount], 2);
                   XCTAssertEqual(checkinHandlerInvocationCount, 2);
                 });

  [self waitForExpectationsWithTimeout:5.0 handler:NULL];
}

/**
 *  Test initial checkin failure which schedules another checkin which should succeed. If
 *  a new checkin request comes after that we should not schedule a checkin as we have
 *  already have valid checkin credentials.
 */
- (void)testInitialCheckinFailure_multipleRetrySuccess {
  XCTestExpectation *checkinExpectation =
      [self expectationWithDescription:@"Did call checkin service"];
  __block int checkinHandlerInvocationCount = 0;

  [[[self.mockCheckinService stub] andDo:^(NSInvocation *invocation) {
    checkinHandlerInvocationCount++;

    if (checkinHandlerInvocationCount <= 2) {
      // Mock failure on first try
      NSError *error = [NSError errorWithFIRInstanceIDErrorCode:kFIRInstanceIDErrorCodeTimeout];
      self.checkinCompletion(nil, error);
    } else if (checkinHandlerInvocationCount == 3) {
      // Mock success on second try
      [checkinExpectation fulfill];
      self.checkinCompletion([self validCheckinPreferences], nil);
    } else {
      // We should not retry for a third time again.
      XCTFail(@"Invoking checkin handler invalid number of times.");
    }
  }] checkinWithExistingCheckin:[OCMArg any]
              firebaseUserAgent:[OCMArg isEqual:self.authService.firebaseUserAgent]
                     completion:[OCMArg checkWithBlock:^BOOL(id obj) {
                       self.checkinCompletion = obj;
                       return obj != nil;
                     }]];

  // Always return YES for whether we succeeded in persisting the checkin
  [[self.mockStore stub] saveCheckinPreferences:[OCMArg any]
                                        handler:[OCMArg invokeBlockWithArgs:[NSNull null], nil]];

  [self.authService scheduleCheckin:YES];

  [self waitForExpectationsWithTimeout:10.0 handler:NULL];
  XCTAssertTrue([self.authService hasValidCheckinInfo]);
  XCTAssertEqual([self.authService checkinRetryCount], 3);
}

/**
 * Performing multiple checkin requests should result in multiple handlers being
 * called back, but with only a single actual checkin fetch.
 */
- (void)testMultipleCheckinHandlersWithSuccessfulCheckin {
  XCTestExpectation *allHandlersCalledExpectation =
      [self expectationWithDescription:@"All checkin handlers were called"];
  __block NSInteger checkinHandlerCallbackCount = 0;
  __block NSInteger checkinServiceInvocationCount = 0;

  // Always return a successful checkin, and count the number of times CheckinService is called
  [[[self.mockCheckinService stub] andDo:^(NSInvocation *invocation) {
    checkinServiceInvocationCount++;
    self.checkinCompletion([self validCheckinPreferences], nil);
  }] checkinWithExistingCheckin:[OCMArg any]
              firebaseUserAgent:[OCMArg isEqual:self.authService.firebaseUserAgent]
                     completion:[OCMArg checkWithBlock:^BOOL(id obj) {
                       self.checkinCompletion = obj;
                       return obj != nil;
                     }]];

  // Always return YES for whether we succeeded in persisting the checkin
  [[self.mockStore stub] saveCheckinPreferences:[OCMArg any]
                                        handler:[OCMArg invokeBlockWithArgs:[NSNull null], nil]];

  NSInteger numHandlers = 10;
  for (NSInteger i = 0; i < numHandlers; i++) {
    [self.authService
        fetchCheckinInfoWithHandler:^(FIRInstanceIDCheckinPreferences *checkin, NSError *error) {
          checkinHandlerCallbackCount++;
          if (checkinHandlerCallbackCount == numHandlers) {
            [allHandlersCalledExpectation fulfill];
          }
        }];
  }

  [self waitForExpectationsWithTimeout:1.0 handler:nil];
  XCTAssertEqual(checkinServiceInvocationCount, 1);
  XCTAssertEqual(checkinHandlerCallbackCount, numHandlers);
}

/**
 * Performing a scheduled checkin *and* simultaneous checkin request should result in
 * the number of pending checkin handlers to be 2 (one for the scheduled checkin, one for
 * the direct fetch).
 */
- (void)testScheduledAndImmediateCheckinsWithMultipleHandler {
  XCTestExpectation *fetchHandlerCalledExpectation =
      [self expectationWithDescription:@"Direct checkin handler was called"];
  __block NSInteger checkinServiceInvocationCount = 0;

  // Always return a successful checkin, and count the number of times CheckinService is called
  [[[self.mockCheckinService stub] andDo:^(NSInvocation *invocation) {
    checkinServiceInvocationCount++;
    // Give the checkin service some time to complete the request
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                     self.checkinCompletion([self validCheckinPreferences], nil);
                   });
  }] checkinWithExistingCheckin:[OCMArg any]
              firebaseUserAgent:[OCMArg isEqual:self.authService.firebaseUserAgent]
                     completion:[OCMArg checkWithBlock:^BOOL(id obj) {
                       self.checkinCompletion = obj;
                       return obj != nil;
                     }]];

  // Always return YES for whether we succeeded in persisting the checkin
  [[self.mockStore stub] saveCheckinPreferences:[OCMArg any]
                                        handler:[OCMArg invokeBlockWithArgs:[NSNull null], nil]];

  // Start a scheduled (though immediate) checkin
  [self.authService scheduleCheckin:YES];

  // Request a direct checkin fetch
  [self.authService
      fetchCheckinInfoWithHandler:^(FIRInstanceIDCheckinPreferences *checkin, NSError *error) {
        [fetchHandlerCalledExpectation fulfill];
      }];
  // At this point we should have checkinHandlers, one for scheduled, one for the direct fetch
  XCTAssertEqual(self.authService.checkinHandlers.count, 2);

  [self waitForExpectationsWithTimeout:0.5 handler:nil];
  // Make sure only one checkin fetch was performed
  XCTAssertEqual(checkinServiceInvocationCount, 1);
}

#pragma mark - Helper Methods

- (FIRInstanceIDCheckinPreferences *)validCheckinPreferences {
  NSDictionary *gservicesData = @{
    kFIRInstanceIDVersionInfoStringKey : kVersionInfo,
    kFIRInstanceIDLastCheckinTimeKey : @(FIRInstanceIDCurrentTimestampInMilliseconds())
  };
  FIRInstanceIDCheckinPreferences *checkinPreferences =
      [[FIRInstanceIDCheckinPreferences alloc] initWithDeviceID:kDeviceAuthId
                                                    secretToken:kSecretToken];
  [checkinPreferences updateWithCheckinPlistContents:gservicesData];
  return checkinPreferences;
}

@end
