// Adapted from: https://github.com/kstenerud/KSCrash
//
//  SentryCrashMonitor_MachException.h
//
//  Created by Karl Stenerud on 2012-02-04.
//
//  Copyright (c) 2012 Karl Stenerud. All rights reserved.
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall remain in place
// in this source code.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.
//

/* Catches mach exceptions.
 */

#ifndef HDR_SentryCrashMonitor_MachException_h
#define HDR_SentryCrashMonitor_MachException_h

#ifdef __cplusplus
extern "C" {
#endif

#include "SentryCrashMonitor.h"
#include <mach/mach.h>
#include <stdbool.h>

/** Access the Monitor API.
 */
SentryCrashMonitorAPI *sentrycrashcm_machexception_getAPI(void);

bool sentrycrashcm_isReservedThread(thread_t thread);

/** Only needed for testing.
 */
bool sentrycrashcm_hasReservedThreads(void);

#if !SDK_V10 && defined(SENTRY_TEST) && SENTRY_HAS_MACH
#    include <mach/mig_errors.h>
#    include <stddef.h>
bool sentrycrashcm_test_isValidMachException(const void *message, size_t capacity);
bool sentrycrashcm_test_isHostExceptionTask(task_t task);
void sentrycrashcm_test_makeMachReply(
    const mach_msg_header_t *request, kern_return_t returnCode, mig_reply_error_t *reply);
bool sentrycrashcm_test_sendErrorRetainsReply(mach_msg_return_t result);
mach_msg_return_t sentrycrashcm_test_replyToMachException(void *message, kern_return_t returnCode);
#endif

#ifdef __cplusplus
}
#endif

#endif // HDR_SentryCrashMonitor_MachException_h
