//
//  UIActionSheet+MKBlockAdditions.m
//  UIKitCategoryAdditions
//
//  Created by Mugunth on 21/03/11.
//  Copyright 2011 Steinlogic All rights reserved.
//

#import "UIActionSheet+MKBlockAdditions.h"

static DismissBlock _dismissBlock;
static CancelBlock _cancelBlock;

@implementation UIActionSheet (MKBlockAdditions)

+(void) actionSheetWithTitle:(NSString*) title
                     message:(NSString*) message
                     buttons:(NSArray*) buttonTitles
                  showInView:(UIView*) view
                   onDismiss:(DismissBlock) dismissed                   
                    onCancel:(CancelBlock) cancelled
{    
  
  [_cancelBlock release];
  _cancelBlock  = [cancelled copy];
  
  [_dismissBlock release];
  _dismissBlock  = [dismissed copy];
  
  UIActionSheet *actionSheet = [[UIActionSheet alloc] initWithTitle:title 
                                                           delegate:[self self] 
                                                  cancelButtonTitle:nil
                                             destructiveButtonTitle:nil 
                                                  otherButtonTitles:nil];
  
  for(NSString* thisButtonTitle in buttonTitles)
    [actionSheet addButtonWithTitle:thisButtonTitle];
  
  [actionSheet addButtonWithTitle:NSLocalizedString(@"Cancel", @"")];
  actionSheet.cancelButtonIndex = [buttonTitles count];
  
  if([view isKindOfClass:[UIView class]])
    [actionSheet showInView:view];
  
  if([view isKindOfClass:[UITabBar class]])
    [actionSheet showFromTabBar:(UITabBar*) view];
  
  if([view isKindOfClass:[UIBarButtonItem class]])
    [actionSheet showFromBarButtonItem:(UIBarButtonItem*) view animated:YES];
  
  [actionSheet release];
  
}

+(void)actionSheet:(UIActionSheet*) actionSheet didDismissWithButtonIndex:(NSInteger) buttonIndex
{
	if(buttonIndex == [actionSheet cancelButtonIndex])
	{
		_cancelBlock();
	}
  else
  {
    _dismissBlock(buttonIndex);
  }
}
@end
