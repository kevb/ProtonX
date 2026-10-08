// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: GPL-3.0-or-later
package main

/*
#cgo LDFLAGS: -framework Security -framework CoreFoundation
#include <Security/Security.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdlib.h>
#include <string.h>
static CFMutableDictionaryRef px_query(void) {
 CFMutableDictionaryRef q=CFDictionaryCreateMutable(NULL,0,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
 CFDictionarySetValue(q,kSecClass,kSecClassGenericPassword);
 CFDictionarySetValue(q,kSecAttrService,CFSTR("org.kevb.ProtonX.Calendar.Native"));
 CFDictionarySetValue(q,kSecAttrAccount,CFSTR("session"));
 CFDictionarySetValue(q,kSecAttrSynchronizable,kCFBooleanFalse);
 return q;
}
static int px_read(void **bytes, long *size) {
 CFMutableDictionaryRef q=px_query();CFDictionarySetValue(q,kSecReturnData,kCFBooleanTrue);CFDictionarySetValue(q,kSecMatchLimit,kSecMatchLimitOne);
 CFTypeRef result=NULL;OSStatus status=SecItemCopyMatching(q,&result);CFRelease(q);
 if(status!=errSecSuccess) return status;
 if(!result || CFGetTypeID(result)!=CFDataGetTypeID()) { if(result) CFRelease(result);return errSecDecode; }
 CFDataRef data=(CFDataRef)result;*size=CFDataGetLength(data);
 if(*size<=0 || *size>32768) { CFRelease(result);return errSecDecode; }
 *bytes=malloc(*size);if(!*bytes) { CFRelease(result);return errSecAllocate; }
 memcpy(*bytes,CFDataGetBytePtr(data),*size);CFRelease(result);return 0;
}
static int px_write(const void *bytes,long size) {
 CFMutableDictionaryRef q=px_query();CFDataRef data=CFDataCreate(NULL,bytes,size);
 CFMutableDictionaryRef a=CFDictionaryCreateMutable(NULL,0,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
 CFDictionarySetValue(a,kSecValueData,data);OSStatus status=SecItemUpdate(q,a);
 if(status==errSecItemNotFound) {
  CFDictionarySetValue(q,kSecValueData,data);CFDictionarySetValue(q,kSecAttrAccessible,kSecAttrAccessibleWhenUnlockedThisDeviceOnly);status=SecItemAdd(q,NULL);
 }
 CFRelease(a);CFRelease(data);CFRelease(q);return status;
}
static int px_delete(void) { CFMutableDictionaryRef q=px_query();OSStatus s=SecItemDelete(q);CFRelease(q);return s==errSecItemNotFound ? 0:s; }
static void px_free(void *p,long n) { volatile unsigned char *b=p;while(n-->0) *b++=0;free(p); }
*/
import "C"
import (
	"github.com/cheeseandcereal/proton-cal/pkg/config"
	"unsafe"
)

type keychainBackend struct{}

func (keychainBackend) Read() ([]byte, error) {
	var p unsafe.Pointer
	var n C.long
	s := C.px_read(&p, &n)
	if s == -25300 {
		return nil, config.ErrNoSession
	}
	if s != 0 {
		return nil, config.ErrStorage
	}
	defer C.px_free(p, n)
	return C.GoBytes(p, C.int(n)), nil
}
func (keychainBackend) Write(b []byte) error {
	if len(b) == 0 || len(b) > 32768 {
		return config.ErrStorage
	}
	if C.px_write(unsafe.Pointer(&b[0]), C.long(len(b))) != 0 {
		return config.ErrStorage
	}
	return nil
}
func (keychainBackend) Delete() error {
	if C.px_delete() != 0 {
		return config.ErrStorage
	}
	return nil
}
