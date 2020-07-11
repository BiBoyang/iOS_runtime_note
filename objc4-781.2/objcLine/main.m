//
//  main.m
//  objcLine
//
//  Created by Boyang on 2020/5/12.
//

#import <Foundation/Foundation.h>
#import <objc/runtime.h>




int main(int argc, const char * argv[]) {
    @autoreleasepool {
//        Class newClass = objc_allocateClassPair(objc_getClass("NSObject"), "newClass", 0);
//        objc_registerClassPair(newClass);
//        id newObject = [[newClass alloc]init];
//        
//        
//        NSLog(@"》》》%s",class_getName([newObject class]));
        
        NSObject *obj = [[NSObject alloc] init];
        
        id __weak obj1 = obj;
        
        NSLog(@"__%@",obj1);
        
        
    }
    return 0;
}
