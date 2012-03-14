//
//  RSTwitterEngine.m
//  RSOAuthEngine
//
//  Created by Rodrigo Sieiro on 12/8/11.
//  Copyright (c) 2011 Rodrigo Sieiro <rsieiro@sharpcube.com>. All rights reserved.
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

#import "RSTwitterEngine.h"
#import "RSWebViewController.h"
#import "RSTwitterConfigs.h"
#import "UIActionSheet+MKBlockAdditions.h"
#import <Twitter/Twitter.h>
#import <Accounts/Accounts.h>

// Default twitter hostname and paths
#define TW_HOSTNAME @"api.twitter.com"
#define TW_REQUEST_TOKEN @"oauth/request_token"
#define TW_ACCESS_TOKEN @"oauth/access_token"
#define TW_STATUS_UPDATE @"1/statuses/update.json"

// URL to redirect the user for authentication
#define TW_AUTHORIZE(__TOKEN__) [NSString stringWithFormat:@"https://api.twitter.com/oauth/authorize?oauth_token=%@", __TOKEN__]

@interface RSTwitterEngine ()

- (void)removeOAuthTokenFromKeychain;
- (void)storeOAuthTokenInKeychain;
- (void)retrieveOAuthTokenFromKeychain;
- (void)resumeAuthenticationFlowWithURL:(NSURL *)url;
- (void)cancelAuthentication;

@property (strong, nonatomic) RSWebViewController *webController;
@property (strong, nonatomic) ACAccount *iOS5TwitterAccount;

@end

@implementation RSTwitterEngine

@synthesize webController = _webController;
@synthesize statusChangeHandler = _statusChangeHandler;
@synthesize presentingViewController = _presentingViewController;
@synthesize iOS5TwitterAccount = _iOS5TwitterChosenAccount;

#pragma mark - Read-only Properties

- (NSString *)screenName
{
  return _screenName;
}

#pragma mark - Initialization

- (id)initWithStatusChangedHandler:(RSTwitterEngineStatusChangeHandler) handler
{
  self = [super initWithHostName:TW_HOSTNAME
              customHeaderFields:nil
                 signatureMethod:RSOAuthHMAC_SHA1
                     consumerKey:TW_CONSUMER_KEY
                  consumerSecret:TW_CONSUMER_SECRET 
                     callbackURL:TW_CALLBACK_URL];
  
  if (self) {
    _oAuthCompletionBlock = nil;
    _screenName = nil;
    self.statusChangeHandler = handler;
    // Retrieve OAuth access token (if previously stored)
    [self retrieveOAuthTokenFromKeychain];
  }
  
  return self;
}

#pragma mark - OAuth Access Token store/retrieve

- (void)removeOAuthTokenFromKeychain
{
  // Build the keychain query
  NSMutableDictionary *keychainQuery = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                                        (__bridge_transfer NSString *)kSecClassGenericPassword, (__bridge_transfer NSString *)kSecClass,
                                        self.consumerKey, kSecAttrService,
                                        self.consumerKey, kSecAttrAccount,
                                        kCFBooleanTrue, kSecReturnAttributes,
                                        nil];
  
  // If there's a token stored for this user, delete it
  CFDictionaryRef query = (__bridge_retained CFDictionaryRef) keychainQuery;
  SecItemDelete(query);
  CFRelease(query);
}

- (void)storeOAuthTokenInKeychain
{
  // Build the keychain query
  NSMutableDictionary *keychainQuery = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                                        (__bridge_transfer NSString *)kSecClassGenericPassword, (__bridge_transfer NSString *)kSecClass,
                                        self.consumerKey, kSecAttrService,
                                        self.consumerKey, kSecAttrAccount,
                                        kCFBooleanTrue, kSecReturnAttributes,
                                        nil];
  
  CFTypeRef resData = NULL;
  
  // If there's a token stored for this user, delete it first
  CFDictionaryRef query = (__bridge_retained CFDictionaryRef) keychainQuery;
  SecItemDelete(query);
  CFRelease(query);
  
  // Build the token dictionary
  NSMutableDictionary *tokenDictionary = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                                          self.token, @"oauth_token",
                                          self.tokenSecret, @"oauth_token_secret",
                                          self.screenName, @"screen_name",
                                          nil];
  
  // Add the token dictionary to the query
  [keychainQuery setObject:[NSKeyedArchiver archivedDataWithRootObject:tokenDictionary] 
                    forKey:(__bridge_transfer NSString *)kSecValueData];
  
  // Add the token data to the keychain
  // Even if we never use resData, replacing with NULL in the call throws EXC_BAD_ACCESS
  query = (__bridge_retained CFDictionaryRef) keychainQuery;
  SecItemAdd(query, (CFTypeRef *) &resData);
  CFRelease(query);
}

- (void)retrieveOAuthTokenFromKeychain
{
  // Build the keychain query
  NSMutableDictionary *keychainQuery = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                                        (__bridge_transfer NSString *)kSecClassGenericPassword, (__bridge_transfer NSString *)kSecClass,
                                        self.consumerKey, kSecAttrService,
                                        self.consumerKey, kSecAttrAccount,
                                        kCFBooleanTrue, kSecReturnData,
                                        kSecMatchLimitOne, kSecMatchLimit,
                                        nil];
  
  // Get the token data from the keychain
  CFTypeRef resData = NULL;
  
  // Get the token dictionary from the keychain
  CFDictionaryRef query = (__bridge_retained CFDictionaryRef) keychainQuery;
  
  if (SecItemCopyMatching(query, (CFTypeRef *) &resData) == noErr)
  {
    NSData *resultData = (__bridge_transfer NSData *)resData;
    
    if (resultData)
    {
      NSMutableDictionary *tokenDictionary = [NSKeyedUnarchiver unarchiveObjectWithData:resultData];
      
      if (tokenDictionary) {
        [self setAccessToken:[tokenDictionary objectForKey:@"oauth_token"]
                      secret:[tokenDictionary objectForKey:@"oauth_token_secret"]];
        
        _screenName = [tokenDictionary objectForKey:@"screen_name"];
      }
    }
  }
  
  CFRelease(query);
}

#pragma mark - OAuth Authentication Flow

-(void) tryiOS5TwitterAccountAuthOnCompletion:(void (^)(void)) completionBlock {
  
  if(![ACAccountStore class]) completionBlock();
  
  ACAccountStore *account = [[ACAccountStore alloc] init];
  ACAccountType *accountType = [account accountTypeWithAccountTypeIdentifier:ACAccountTypeIdentifierTwitter];
  self.statusChangeHandler(@"Authenticating...");

  [account requestAccessToAccountsWithType:accountType withCompletionHandler:^(BOOL granted, NSError *error) 
   {
     if (!granted) {
       completionBlock();
       return;      
     }

     NSArray *arrayOfAccounts = [account accountsWithAccountType:accountType];
     if([arrayOfAccounts count] <= 0) {
       completionBlock();
       return;      
     }
     
     if([arrayOfAccounts count] == 1) {
       self.iOS5TwitterAccount = [arrayOfAccounts objectAtIndex:0];
       _screenName = self.iOS5TwitterAccount.username;
       completionBlock();
       return;      
     } else {
       
       NSMutableArray *buttonsArray = [NSMutableArray array];
       [arrayOfAccounts enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
         
         [buttonsArray addObject:((ACAccount*)obj).username];
       }];
       
       self.statusChangeHandler(@"Waiting for user authorization...");

       [UIActionSheet actionSheetWithTitle:@"Choose your Twitter account" 
                                   message:nil 
                                   buttons:buttonsArray 
                                showInView:self.presentingViewController.view 
                                 onDismiss:^(int buttonIndex) {
                                   
                                   self.iOS5TwitterAccount = [[account accountsWithAccountType:accountType] objectAtIndex:buttonIndex];
                                   _screenName = self.iOS5TwitterAccount.username;

                                   completionBlock();
                                 } onCancel:^{
                                   
                                   self.iOS5TwitterAccount = nil;
                                   completionBlock();
                                 }];         
     }
   }];  
}

- (void)authenticateWithCompletionBlock:(RSTwitterEngineCompletionBlock)completionBlock
{
  
  [self tryiOS5TwitterAccountAuthOnCompletion:^{
    if(!self.iOS5TwitterAccount) {
      
      // Store the Completion Block to call after Authenticated
      _oAuthCompletionBlock = [completionBlock copy];
      // First we reset the OAuth token, so we won't send previous tokens in the request
      [self resetOAuthToken];
      
      // OAuth Step 1 - Obtain a request token
      MKNetworkOperation *op = [self operationWithPath:TW_REQUEST_TOKEN
                                                params:nil
                                            httpMethod:@"POST"
                                                   ssl:YES];
      
      [op onCompletion:^(MKNetworkOperation *completedOperation)
       {
         // Fill the request token with the returned data
         [self fillTokenWithResponseBody:[completedOperation responseString] type:RSOAuthRequestToken];
         
         // OAuth Step 2 - Redirect user to authorization page
         self.statusChangeHandler(@"Waiting for user authorization...");
         NSURL *url = [NSURL URLWithString:TW_AUTHORIZE(self.token)];
         [self openURL:url];
       } 
               onError:^(NSError *error)
       {
         completionBlock(error);
         _oAuthCompletionBlock = nil;
       }];
      
      self.statusChangeHandler(@"Requesting Tokens...");
      [self enqueueSignedOperation:op];
      
    } else {
      completionBlock(nil);
    }
  }];    
}

- (void)resumeAuthenticationFlowWithURL:(NSURL *)url
{
  // Fill the request token with data returned in the callback URL
  [self fillTokenWithResponseBody:url.query type:RSOAuthRequestToken];
  
  // OAuth Step 3 - Exchange the request token with an access token
  MKNetworkOperation *op = [self operationWithPath:TW_ACCESS_TOKEN
                                            params:nil
                                        httpMethod:@"POST"
                                               ssl:YES];
  
  [op onCompletion:^(MKNetworkOperation *completedOperation)
   {
     // Fill the access token with the returned data
     [self fillTokenWithResponseBody:[completedOperation responseString] type:RSOAuthAccessToken];
     
     // Retrieve the user's screen name
     _screenName = [self customValueForKey:@"screen_name"];
     
     // Store the OAuth access token
     [self storeOAuthTokenInKeychain];
     
     // Finished, return to previous method
     if (_oAuthCompletionBlock) _oAuthCompletionBlock(nil);
     _oAuthCompletionBlock = nil;
   } 
           onError:^(NSError *error)
   {
     if (_oAuthCompletionBlock) _oAuthCompletionBlock(error);
     _oAuthCompletionBlock = nil;
   }];
  
  self.statusChangeHandler(@"Authenticating...");
  [self enqueueSignedOperation:op];
}

- (void)cancelAuthentication
{
  NSDictionary *ui = [NSDictionary dictionaryWithObjectsAndKeys:@"Authentication cancelled.", NSLocalizedDescriptionKey, nil];
  NSError *error = [NSError errorWithDomain:@"com.sharpcube.RSTwitterEngine.ErrorDomain" code:401 userInfo:ui];
  
  if (_oAuthCompletionBlock) _oAuthCompletionBlock(error);
  _oAuthCompletionBlock = nil;
}

- (void)forgetStoredToken
{
  [self removeOAuthTokenFromKeychain];
  
  [self resetOAuthToken];
  _screenName = nil;
}

#pragma mark - Public Methods

-(BOOL) isAuthenticated {
  
  if(self.iOS5TwitterAccount) return YES;
  else return [super isAuthenticated];
}

- (void)sendTweet:(NSString *)tweet withCompletionBlock:(RSTwitterEngineCompletionBlock)completionBlock
{
  
  if (!self.isAuthenticated) {
    [self authenticateWithCompletionBlock:^(NSError *error) {
      if (error) {
        // Authentication failed, return the error
        completionBlock(error);
      } else {
        // Authentication succeeded, call this method again
        [self sendTweet:tweet withCompletionBlock:completionBlock];
      }
    }];
    
    // This method will be called again once the authentication completes
    return;
  }
  
  if(self.iOS5TwitterAccount) {
    
    TWRequest *postRequest = [[TWRequest alloc] initWithURL:
                              [NSURL URLWithString:@"http://api.twitter.com/1/statuses/update.json"] 
                                                 parameters:[NSDictionary dictionaryWithObject:tweet 
                                                                                        forKey:@"status"] requestMethod:TWRequestMethodPOST];
    
    [postRequest setAccount:self.iOS5TwitterAccount];
    [postRequest performRequestWithHandler:^(NSData *responseData, NSHTTPURLResponse *urlResponse, NSError *error) 
     {
       NSLog(@"Twitter response, HTTP response: %i", [urlResponse statusCode]);
       completionBlock(error);
     }];
  }  else {
    // Fill the post body with the tweet
    NSMutableDictionary *postParams = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                                       tweet, @"status",
                                       nil];
    
    // If the user marks the option "HTTPS Only" in his/her profile,
    // Twitter will fail all non-auth requests that use only HTTP
    // with a misleading "OAuth error". I guess it's a bug.
    MKNetworkOperation *op = [self operationWithPath:TW_STATUS_UPDATE 
                                              params:postParams
                                          httpMethod:@"POST"
                                                 ssl:YES];
    
    [op setFreezable:YES];
    [op onCompletion:^(MKNetworkOperation *completedOperation) {
      completionBlock(nil);
    } onError:^(NSError *error) {
      completionBlock(error);
    }];
    
    self.statusChangeHandler(@"Sending tweet...");
    [self enqueueSignedOperation:op];  
  }
  
}

-(void) openURL:(NSURL*) url {
  
  self.webController = [[RSWebViewController alloc] initWithURL:url];  
  self.webController.callbackURL = TW_CALLBACK_URL;
  
  [self.presentingViewController presentModalViewController:self.webController animated:YES];
  
  __unsafe_unretained RSTwitterEngine *weakSelf = self; 
  
  self.webController.authenticationCanceledHandler = ^{
    
    __strong RSTwitterEngine *strongSelf = weakSelf; 
    [strongSelf.presentingViewController dismissModalViewControllerAnimated:YES];
    [strongSelf cancelAuthentication];
  };
  
  self.webController.authenticationCompletedHandler = ^(NSURL* url) {
    
    __strong RSTwitterEngine *strongSelf = weakSelf; 
    [strongSelf.presentingViewController dismissModalViewControllerAnimated:YES];
    [strongSelf resumeAuthenticationFlowWithURL:url];
  };
}

@end
