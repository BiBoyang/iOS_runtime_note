/*
 * Copyright (c) 2006-2008 Apple Inc.  All Rights Reserved.
 * 
 * @APPLE_LICENSE_HEADER_START@
 * 
 * This file contains Original Code and/or Modifications of Original Code
 * as defined in and that are subject to the Apple Public Source License
 * Version 2.0 (the 'License'). You may not use this file except in
 * compliance with the License. Please obtain a copy of the License at
 * http://www.opensource.apple.com/apsl/ and read it before using this
 * file.
 * 
 * The Original Code and all software distributed under the License are
 * distributed on an 'AS IS' basis, WITHOUT WARRANTY OF ANY KIND, EITHER
 * EXPRESS OR IMPLIED, AND APPLE HEREBY DISCLAIMS ALL SUCH WARRANTIES,
 * INCLUDING WITHOUT LIMITATION, ANY WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE, QUIET ENJOYMENT OR NON-INFRINGEMENT.
 * Please see the License for the specific language governing rights and
 * limitations under the License.
 * 
 * @APPLE_LICENSE_HEADER_END@
 */

#include <string.h>
#include <stddef.h>

#include <libkern/OSAtomic.h>

#include "objc-private.h"
#include "runtime.h"

// stub interface declarations to make compiler happy.

@interface __NSCopyable
- (id)copyWithZone:(void *)zone;
@end

@interface __NSMutableCopyable
- (id)mutableCopyWithZone:(void *)zone;
@end

StripedMap<spinlock_t> PropertyLocks;
StripedMap<spinlock_t> StructLocks;
// MARK: -- PropertyLocks 是一个 StripedMap 类型的全局变量,而StripedMap 是一个 hashMap，key 是指针，value 是 spinlock_t 对象。
StripedMap<spinlock_t> CppObjectLocks;

#define MUTABLE_COPY 2

/**
 * >> getter 方法的实现
 * self : 隐含参数，对象消息接收者
 * _cmd : 隐含参数，setter对应函数
 * offset : 属性所在指针的偏移量
 * atomic : 是否是原子操作
 */
id objc_getProperty(id self, SEL _cmd, ptrdiff_t offset, BOOL atomic) {
    if (offset == 0) {
        return object_getClass(self);
    }

    // Retain release world
    // MARK: -- 计算属性缩在的指针偏移量
    id *slot = (id*) ((char*)self + offset);
    // MARK: -- 如果是非原子性操作，直接返回属性的对象指针
    if (!atomic) return *slot;
        
    // Atomic retain release world
    // MARK: -- 这里是自旋锁，但是因为有线程优先级冲突的问题，将其修改
    spinlock_t& slotlock = PropertyLocks[slot];
    slotlock.lock();
    id value = objc_retain(*slot);
    slotlock.unlock();
    
    // for performance, we (safely) issue the autorelease OUTSIDE of the spinlock.
    return objc_autoreleaseReturnValue(value);
}


static inline void reallySetProperty(id self, SEL _cmd, id newValue, ptrdiff_t offset, bool atomic, bool copy, bool mutableCopy) __attribute__((always_inline));

/**
 * self : 隐含参数，对象消息接收者
 * _cmd : 隐含参数，setter对应函数
 * newValue : 需要赋值的传入
 * offset : 属性所在指针的偏移量
 * atomic : 是否是原子操作
 * copy : 是否是浅拷贝
 * mutableCopy : 是否是深拷贝
 */
static inline void reallySetProperty(id self, SEL _cmd, id newValue, ptrdiff_t offset, bool atomic, bool copy, bool mutableCopy)
{
    // MARK: -- 偏移量是0的时候，指向的其实就是对象自身，对对象自身赋值
    if (offset == 0) {
        object_setClass(self, newValue);
        return;
    }

    id oldValue;
    // MARK: -- 获取属性的对象指针
    id *slot = (id*) ((char*)self + offset);

    if (copy) {
        // MARK: -- 浅拷贝，将传入的新对象调用copyWithZone方法浅拷贝一份，并且赋值给newValue变量
        newValue = [newValue copyWithZone:nil];
    } else if (mutableCopy) {
        // MARK: -- 深拷贝，将传入的新对象调用mutableCopyWithZone方法深拷贝一份，并且赋值给newValue变量
        newValue = [newValue mutableCopyWithZone:nil];
    } else {
        // MARK: -- 非拷贝，且传入的对象与旧对象一致，直接返回
        if (*slot == newValue) return;
        // MARK: -- 否则，调用objc_retain函数，将newValue变量指向对象引用计数+1，并且将返回值赋值给newValue变量
        newValue = objc_retain(newValue);
    }

    if (!atomic) {
        // MARK: -- 非原子操作，将slot指针指向的对象引用赋值给oldValue
        oldValue = *slot;
        *slot = newValue;
    } else {
        // MARK: -- 原子操作，则获取锁
        spinlock_t& slotlock = PropertyLocks[slot];
        slotlock.lock();
        oldValue = *slot;
        *slot = newValue;        
        slotlock.unlock();
    }
    // MARK: -- 释放oldValue所持有的对象
    objc_release(oldValue);
}

// MARK: -- setter 方法的实现
void objc_setProperty(id self, SEL _cmd, ptrdiff_t offset, id newValue, BOOL atomic, signed char shouldCopy) 
{
    bool copy = (shouldCopy && shouldCopy != MUTABLE_COPY);
    bool mutableCopy = (shouldCopy == MUTABLE_COPY);
    reallySetProperty(self, _cmd, newValue, offset, atomic, copy, mutableCopy);
}

void objc_setProperty_atomic(id self, SEL _cmd, id newValue, ptrdiff_t offset)
{
    reallySetProperty(self, _cmd, newValue, offset, true, false, false);
}

void objc_setProperty_nonatomic(id self, SEL _cmd, id newValue, ptrdiff_t offset)
{
    reallySetProperty(self, _cmd, newValue, offset, false, false, false);
}


void objc_setProperty_atomic_copy(id self, SEL _cmd, id newValue, ptrdiff_t offset)
{
    reallySetProperty(self, _cmd, newValue, offset, true, true, false);
}

void objc_setProperty_nonatomic_copy(id self, SEL _cmd, id newValue, ptrdiff_t offset)
{
    reallySetProperty(self, _cmd, newValue, offset, false, true, false);
}


// This entry point was designed wrong.  When used as a getter, src needs to be locked so that
// if simultaneously used for a setter then there would be contention on src.
// So we need two locks - one of which will be contended.
/**
 * 结构体拷贝
 * src：源指针
 * dest：目标指针
 * size：大小
 * atomic：是否是原子操作
 * hasStrong：可能是表示是否是strong修饰
 */
void objc_copyStruct(void *dest, const void *src, ptrdiff_t size, BOOL atomic, BOOL hasStrong __unused) {
    spinlock_t *srcLock = nil;
    spinlock_t *dstLock = nil;
    // MARK: -- 如果是原子操作，则加锁
    if (atomic) {
        srcLock = &StructLocks[src];
        dstLock = &StructLocks[dest];
        spinlock_t::lockTwo(srcLock, dstLock);
    }
    // MARK: -- 实际的拷贝操作
    memmove(dest, src, size);

    // MARK: -- 解锁
    if (atomic) {
        spinlock_t::unlockTwo(srcLock, dstLock);
    }
}

/**
 * 对象拷贝
 * src：源指针
 * dest：目标指针
 * copyHelper：对对象进行实际拷贝的函数指针，参数是 src 和 dest
*/

void objc_copyCppObjectAtomic(void *dest, const void *src, void (*copyHelper) (void *dest, const void *source)) {
    // MARK: -- 获取源指针的对象锁
    spinlock_t *srcLock = &CppObjectLocks[src];
    // MARK: -- 获取目标指针的对象锁
    spinlock_t *dstLock = &CppObjectLocks[dest];
    // MARK: -- 对源对象和目标对象进行上锁
    spinlock_t::lockTwo(srcLock, dstLock);

    // let C++ code perform the actual copy.
    // MARK: -- 调用函数指针对应的函数，让C++进行实际的拷贝操作
    copyHelper(dest, src);
    // MARK: -- 解锁
    spinlock_t::unlockTwo(srcLock, dstLock);
}
