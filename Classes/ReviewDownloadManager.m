//
//  ReviewDownloadManager.m
//  AppSales
//
//  Created by Ole Zorn on 27.07.11.
//  Copyright 2011 omz:software. All rights reserved.
//

#import "ReviewDownloadManager.h"
#import "Product.h"
#import "Review.h"
#import "XMLReader.h"

#define kReviewInfoId       @"reviewId"
#define kReviewInfoTitle		@"title"
#define kReviewInfoUser			@"user"
#define kReviewInfoDateString	@"dateString"
#define kReviewInfoRating		@"rating"
#define kReviewInfoVersion		@"version"
#define kReviewInfoText			@"text"

#define MAX_CONCURRENT_REVIEW_DOWNLOADS		5

@interface ReviewDownloadManager ()

- (void)dequeueDownload;

@end

@implementation ReviewDownloadManager

- (id)init
{
	self = [super init];
	if (self) {
		activeDownloads = [NSMutableSet new];
		downloadQueue = [NSMutableArray new];
	}
	return self;
}

+ (id)sharedManager
{
	static id sharedManager = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		sharedManager = [[self alloc] init];
	});
	return sharedManager;
}

- (void)downloadReviewsForProducts:(NSArray *)products
{
	if ([activeDownloads count] > 0 || [downloadQueue count] > 0) return;
	
	NSDictionary *storeInfos = [[NSDictionary dictionaryWithContentsOfFile:[[NSBundle mainBundle] pathForResource:@"stores" ofType:@"plist"]] objectForKey:@"StoreInfos"];
	for (NSString *country in storeInfos) {
		for (Product *product in products) {
			if (product.parentSKU) continue; //don't download reviews for in-app-purchases
			ReviewDownload *download = [[[ReviewDownload alloc] initWithProduct:product store:country countryCode:country] autorelease];
			download.delegate = self;
			[downloadQueue addObject:download];
		}
	}
	totalDownloadsCount = [downloadQueue count];
	completedDownloadsCount = 0;
	[[NSNotificationCenter defaultCenter] postNotificationName:ReviewDownloadManagerDidUpdateProgressNotification object:self];
	[self dequeueDownload];
}

- (void)cancelAllDownloads
{
	[downloadQueue removeAllObjects];
	for (ReviewDownload *download in activeDownloads) {
		[download cancel];
	}
	[activeDownloads removeAllObjects];
	completedDownloadsCount = 0;
	totalDownloadsCount = 0;
	[[NSNotificationCenter defaultCenter] postNotificationName:ReviewDownloadManagerDidUpdateProgressNotification object:self];
}

- (void)dequeueDownload
{
	if ([downloadQueue count] == 0) return;
	if ([activeDownloads count] >= MAX_CONCURRENT_REVIEW_DOWNLOADS) return;
	
	ReviewDownload *nextDownload = [[[downloadQueue objectAtIndex:0] retain] autorelease];
	[downloadQueue removeObjectAtIndex:0];
	[activeDownloads addObject:nextDownload];
	[nextDownload start];
	
	[self dequeueDownload];
}

- (void)reviewDownloadDidFinish:(ReviewDownload *)download
{
	[activeDownloads removeObject:download];
	completedDownloadsCount++;
	[[NSNotificationCenter defaultCenter] postNotificationName:ReviewDownloadManagerDidUpdateProgressNotification object:self];
	[self dequeueDownload];
}

- (BOOL)isDownloading
{
	return [downloadQueue count] != 0 || [activeDownloads count] != 0;
}

- (float)downloadProgress
{
	float progress = (totalDownloadsCount == 0) ? 1.0 : (float)completedDownloadsCount / (float)totalDownloadsCount;
	return progress;
}

- (void)dealloc
{
	[activeDownloads release];
	[downloadQueue release];
	[super dealloc];
}

@end



@implementation ReviewDownload

@synthesize delegate, downloadConnection;

- (id)initWithProduct:(Product *)app store:(NSString *)storeID countryCode:(NSString *)countryCode
{
	self = [super init];
	if (self) {
		_product = [app retain];
		country = [countryCode retain];
		productObjectID = [[app objectID] copy];
		psc = [[[app managedObjectContext] persistentStoreCoordinator] retain];
		store = [storeID retain];
		data = [NSMutableData new];
		page = 1;
	}
	return self;
}

- (void)start
{
	backgroundTaskID = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:nil];
  
	NSString *productID = _product.productID;
  NSString *URLString = [NSString stringWithFormat:@"https://itunes.apple.com/%@/rss/customerreviews/page=%d/id=%@/sortby=mostrecent/xml", store, page , productID];
	NSURL *URL = [NSURL URLWithString:URLString];
	NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:URL];
  //[request setValue:@"Mozilla/5.0 (Macintosh; Intel Mac OS X 1083) AppleWebKit/536.26.17 (KHTML like Gecko) Version/6.0.2 Safari/536.26.17" forHTTPHeaderField:@"User-Agent"];

	self.downloadConnection = [NSURLConnection connectionWithRequest:request delegate:self];
}

- (void)startWithUrl:(NSString*)URLString {
  if (backgroundTaskID != UIBackgroundTaskInvalid) {
    [[UIApplication sharedApplication] endBackgroundTask:backgroundTaskID];
  }
	backgroundTaskID = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:nil];
	
	NSURL *URL = [NSURL URLWithString:URLString];
	NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:URL];
  //[request setValue:@"Mozilla/5.0 (Macintosh; Intel Mac OS X 1083) AppleWebKit/536.26.17 (KHTML like Gecko) Version/6.0.2 Safari/536.26.17" forHTTPHeaderField:@"User-Agent"];
  
	data = [NSMutableData new];
	self.downloadConnection = [NSURLConnection connectionWithRequest:request delegate:self];
}


- (void)cancel
{
	if (backgroundTaskID != UIBackgroundTaskInvalid) {
		[[UIApplication sharedApplication] endBackgroundTask:backgroundTaskID];
	}
	canceled = YES;
	[self.downloadConnection cancel];
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)dataChunk
{
	[data appendData:dataChunk];
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection
{
  NSString *xml = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
  if (!xml) {
		if (!canceled) {
			[self.delegate reviewDownloadDidFinish:self];
		}
		if (backgroundTaskID != UIBackgroundTaskInvalid) {
			[[UIApplication sharedApplication] endBackgroundTask:backgroundTaskID];
		}
    return;
	}
  dispatch_async(dispatch_get_global_queue(0, 0), ^ {
    
    NSDictionary *reviewContainer = [self reviewInfosFromXML:xml];
    
    NSArray *reviewInfos = [reviewContainer objectForKey:@"reviews"];
    NSString *nextPageURL = [reviewContainer objectForKey:@"nextPage"];
    
    NSManagedObjectContext *moc = [[[NSManagedObjectContext alloc] init] autorelease];
    [moc setPersistentStoreCoordinator:psc];
    [moc setMergePolicy:NSMergeByPropertyObjectTrumpMergePolicy];
    Product *product = (Product *)[moc objectWithID:productObjectID];
    
    NSDateFormatter *reviewDateFormatter = [[NSDateFormatter alloc] init];
    //2012-12-19T06:43:35-07:00
    [reviewDateFormatter setDateFormat:@"yyyy-MM-dd'T'HHmmssZZ"];
    
    NSSet *downloadedIds = [NSSet setWithArray:[reviewInfos valueForKey:kReviewInfoId]];
    
    //Fetch existing reviews, based on id and country:
    NSFetchRequest *existingReviewsFetchRequest = [[[NSFetchRequest alloc] init] autorelease];
    [existingReviewsFetchRequest setEntity:[NSEntityDescription entityForName:@"Review" inManagedObjectContext:moc]];
    [existingReviewsFetchRequest setPredicate:[NSPredicate predicateWithFormat:@"product == %@ AND countryCode == %@ AND reviewId IN %@", product, country, downloadedIds]];
    NSArray *existingReviews = [moc executeFetchRequest:existingReviewsFetchRequest error:NULL];
    NSMutableDictionary *existingReviewsById = [NSMutableDictionary dictionary];
    for (Review *existingReview in existingReviews) {
      [existingReviewsById setObject:existingReview forKey:existingReview.reviewId];
    }
    
    BOOL changesMade = NO;
    for (NSDictionary *reviewInfo in [reviewInfos reverseObjectEnumerator]) {
      Review *existingReview = [existingReviewsById objectForKey:[reviewInfo objectForKey:kReviewInfoId]];
      if (!existingReview) {
        Review *newReview = [NSEntityDescription insertNewObjectForEntityForName:@"Review" inManagedObjectContext:moc];
        newReview.reviewId = [reviewInfo objectForKey:kReviewInfoId];
        newReview.user = [reviewInfo objectForKey:kReviewInfoUser];
        newReview.title = [reviewInfo objectForKey:kReviewInfoTitle];
        newReview.text = [reviewInfo objectForKey:kReviewInfoText];
        newReview.rating = [reviewInfo objectForKey:kReviewInfoRating];
        newReview.downloadDate = [NSDate date];
        newReview.productVersion = [reviewInfo objectForKey:kReviewInfoVersion];
        newReview.product = product;
        newReview.countryCode = country;
        newReview.unread = [NSNumber numberWithBool:YES];
        //iTunes RSS use a colon in the "updated" date. To read it properly, remove all colons from date string
        NSString *dateString = [reviewInfo objectForKey:kReviewInfoDateString];
        dateString = [dateString stringByReplacingOccurrencesOfString:@":" withString:@""];
        newReview.reviewDate = [reviewDateFormatter dateFromString:dateString];
        [existingReviewsById setObject:newReview forKey:newReview.reviewId];
        changesMade = YES;
      } else {
        NSString *existingText = existingReview.text;
        NSString *existingTitle = existingReview.title;
        NSNumber *existingRating = existingReview.rating;
        NSString *newText = [reviewInfo objectForKey:kReviewInfoText];
        NSString *newTitle = [reviewInfo objectForKey:kReviewInfoTitle];
        NSNumber *newRating = [reviewInfo objectForKey:kReviewInfoRating];
        if (![existingText isEqualToString:newText] || ![existingTitle isEqualToString:newTitle] || ![existingRating isEqualToNumber:newRating]) {
          existingReview.text = newText;
          existingReview.title = newTitle;
          existingReview.rating = newRating;
          changesMade = YES;
        }
        
      }
    }
    
    if (changesMade) {
      [psc lock];
      NSError *saveError = nil;
      [moc save:&saveError];
      if (saveError) {
        NSLog(@"Could not save context: %@", saveError);
      }
      [psc unlock];
    }
    
    if (changesMade && nextPageURL.length>0) {
      dispatch_async(dispatch_get_main_queue(), ^ {
        page = page + 1;
        [self startWithUrl:nextPageURL];
      });
    } else {
      dispatch_async(dispatch_get_main_queue(), ^ {
        if (!canceled) {
          [self.delegate reviewDownloadDidFinish:self];
        }
        if (backgroundTaskID != UIBackgroundTaskInvalid) {
          [[UIApplication sharedApplication] endBackgroundTask:backgroundTaskID];
        }
      });
    }
  });
}


- (NSDictionary *)reviewInfosFromXML:(NSString *)xml
{
  NSMutableDictionary *reviewContainer = [NSMutableDictionary dictionary];
  NSMutableArray *reviews = [NSMutableArray array];
  NSError *error = nil;
  
  NSDictionary *reviewsDictFromXml = [XMLReader dictionaryForXMLString:xml error:&error];
  
  if (!error && reviewsDictFromXml) {
    NSString *thisPage;
    NSString *nextPage;
    NSString *lastPage;
    for (NSDictionary *reviewDict in [[reviewsDictFromXml objectForKey:@"feed"] objectForKey:@"link"]) {
      NSString *linkType =[reviewDict objectForKey:@"rel"];
      if ([linkType isEqualToString:@"self"])
        thisPage = [reviewDict objectForKey:@"href"];
      if ([linkType isEqualToString:@"next"])
        nextPage = [reviewDict objectForKey:@"href"];
      if ([linkType isEqualToString:@"last"])
        lastPage = [reviewDict objectForKey:@"href"];
    }
    if (lastPage != nil && lastPage.length>0 && ![lastPage isEqualToString:thisPage] )
      [reviewContainer setValue:nextPage forKey:@"nextPage"];
    else
      [reviewContainer setValue:@"" forKey:@"nextPage"];
    for (NSDictionary *reviewDict in [[reviewsDictFromXml objectForKey:@"feed"] objectForKey:@"entry"]) {
      //First entry is itunes description. Only search for entries with "author" tag
      if ([reviewDict objectForKey:@"author"]) {
        NSString *reviewId = [[reviewDict objectForKey:@"id"] objectForKey:@"text"];
        reviewId = [reviewId stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        
        NSString *reviewTitle = [[reviewDict objectForKey:@"title"] objectForKey:@"text"];
        reviewTitle = [reviewTitle stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        
        NSString *reviewRatingString = [[reviewDict objectForKey:@"im:rating"] objectForKey:@"text"];
        reviewRatingString = [reviewRatingString stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSNumber *rating = (NSNumber *)[NSDecimalNumber decimalNumberWithString:reviewRatingString];
        
        NSString *reviewUser = [[[reviewDict objectForKey:@"author"] objectForKey:@"name"] objectForKey:@"text"];
        reviewUser = [reviewUser stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        
        NSString *reviewVersion = [[reviewDict objectForKey:@"im:version"] objectForKey:@"text"];
        reviewVersion = [reviewVersion stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        
        NSString *reviewDateString = [[reviewDict objectForKey:@"updated"] objectForKey:@"text"];
        reviewDateString = [reviewDateString stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        
        NSString *reviewText = [[[reviewDict objectForKey:@"content"] objectAtIndex:0] objectForKey:@"text"];
        reviewText = [reviewText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        
        if (reviewId && rating && reviewTitle && reviewUser && reviewVersion && reviewDateString && reviewText) {
          NSDictionary *reviewInfo = [NSDictionary dictionaryWithObjectsAndKeys:
                                      reviewId, kReviewInfoId,
                                      reviewTitle, kReviewInfoTitle,
                                      reviewUser, kReviewInfoUser,
                                      reviewVersion, kReviewInfoVersion,
                                      reviewDateString, kReviewInfoDateString,
                                      reviewText, kReviewInfoText,
                                      rating, kReviewInfoRating,
                                      nil];
          //NSLog(@"%@", reviewInfo);
          [reviews addObject:reviewInfo];
        }
      }
    }
  }
  [reviewContainer setValue:reviews forKey:@"reviews"];
  return reviewContainer;
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error
{
  if (backgroundTaskID != UIBackgroundTaskInvalid) {
    [[UIApplication sharedApplication] endBackgroundTask:backgroundTaskID];
  }
  [self.delegate reviewDownloadDidFinish:self];
}


- (void)dealloc
{
  [country release];
  [_product release];
  [productObjectID release];
  [psc release];
  [downloadConnection release];
  [data release];
  [store release];
  [super dealloc];
}

@end