// Declarations for Apple's private CGVirtualDisplay* CoreGraphics classes.
//
// Provenance: these interfaces were extracted directly from Apple's own
// CoreGraphics framework by Objective-C runtime introspection on macOS 15.7.4
// (class_copyPropertyList / class_copyMethodList) — see
// Scripts/dump-private-api.swift, which reproduces the dump. They are Apple's
// own API surface (facts about the framework, mechanically read from the
// system binary), re-declared here only so Swift can call them.
//
// Apple ships no public header for these classes; only the members this tool
// actually uses are declared below.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

@interface CGVirtualDisplayDescriptor : NSObject

@property(retain, nonatomic) id queue;
@property(retain, nonatomic) NSString *name;
@property(nonatomic) CGPoint whitePoint;
@property(nonatomic) CGPoint redPrimary;
@property(nonatomic) CGPoint greenPrimary;
@property(nonatomic) CGPoint bluePrimary;
@property(nonatomic) unsigned int maxPixelsWide;
@property(nonatomic) unsigned int maxPixelsHigh;
@property(nonatomic) CGSize sizeInMillimeters;
@property(nonatomic) unsigned int serialNum;
@property(nonatomic) unsigned int productID;
@property(nonatomic) unsigned int vendorID;

- (id)init;

@end

@interface CGVirtualDisplay : NSObject

@property(readonly, nonatomic) unsigned int displayID;

- (id)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(id)settings;

@end

@interface CGVirtualDisplayMode : NSObject

@property(readonly, nonatomic) unsigned int width;
@property(readonly, nonatomic) unsigned int height;
@property(readonly, nonatomic) double refreshRate;

- (id)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)refreshRate;

@end

@interface CGVirtualDisplaySettings : NSObject

@property(nonatomic) unsigned int hiDPI;
@property(retain, nonatomic) NSArray *modes;

- (id)init;

@end
