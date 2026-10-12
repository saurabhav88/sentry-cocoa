#import "SentryInternalCDefines.h"
#if !SDK_V10 && SENTRY_HAS_MACH
#    import "SentryCrashMonitor_MachException.h"
#    import <XCTest/XCTest.h>
#    import <mach/ndr.h>
#    import <stddef.h>
#    import <unistd.h>

// Independently follows mach_exc.defs / mach_exception_raise wire layout.
#    pragma pack(push, 4)
typedef struct {
    mach_msg_header_t header;
    mach_msg_body_t body;
    mach_msg_port_descriptor_t thread;
    mach_msg_port_descriptor_t task;
    NDR_record_t NDR;
    exception_type_t exception;
    mach_msg_type_number_t codeCount;
    mach_exception_data_type_t code[2];
} TestExceptionRequest;
#    pragma pack(pop)

typedef struct {
    TestExceptionRequest request;
    mach_msg_max_trailer_t trailer;
} TestReceiveBuffer;

@interface SentryCrashMonitor_MachException_Tests : XCTestCase
@end

@implementation SentryCrashMonitor_MachException_Tests

- (TestExceptionRequest)validReceivedRequest
{
    TestExceptionRequest request = { 0 };
    request.header.msgh_bits
        = MACH_MSGH_BITS(MACH_MSG_TYPE_PORT_SEND_ONCE, 0) | MACH_MSGH_BITS_COMPLEX;
    request.header.msgh_size = sizeof(request);
    request.header.msgh_remote_port = 123;
    request.header.msgh_id = 2405;
    request.body.msgh_descriptor_count = 2;
    request.thread.type = MACH_MSG_PORT_DESCRIPTOR;
    request.thread.disposition = MACH_MSG_TYPE_PORT_SEND;
    request.thread.name = 124;
    request.task = request.thread;
    request.task.name = 125;
    request.NDR = NDR_record;
    request.exception = EXC_BREAKPOINT;
    request.codeCount = 2;
    return request;
}

- (void)testRequest_whenCanonicalLayout_shouldAccept
{
    // -- Arrange --
    TestExceptionRequest request = [self validReceivedRequest];
    // -- Act --
    bool accepted = sentrycrashcm_test_isValidMachException(&request, sizeof(request));
    // -- Assert --
    XCTAssertTrue(accepted);
}

- (void)testRequest_whenBufferTooShort_shouldRejectEveryPrefix
{
    // -- Arrange --
    TestExceptionRequest request = [self validReceivedRequest];
    // -- Act / Assert --
    for (size_t length = 0; length < sizeof(request); length++) {
        XCTAssertFalse(sentrycrashcm_test_isValidMachException(&request, length));
    }
}

- (void)testRequest_whenZeroOrOneCode_shouldRespectVariableLength
{
    // -- Arrange --
    TestExceptionRequest request = [self validReceivedRequest];
    // -- Act / Assert --
    for (unsigned int count = 0; count < 2; count++) {
        request.codeCount = count;
        request.header.msgh_size = offsetof(TestExceptionRequest, code) + count * sizeof(int64_t);
        XCTAssertTrue(sentrycrashcm_test_isValidMachException(&request, sizeof(request)));
    }
}

- (void)testRequest_whenCodeCountOrSizeInvalid_shouldReject
{
    // -- Arrange --
    TestExceptionRequest request = [self validReceivedRequest];
    // -- Act / Assert --
    request.codeCount = 3;
    XCTAssertFalse(sentrycrashcm_test_isValidMachException(&request, sizeof(request)));
    request = [self validReceivedRequest];
    request.header.msgh_size--;
    XCTAssertFalse(sentrycrashcm_test_isValidMachException(&request, sizeof(request)));
    request = [self validReceivedRequest];
    request.header.msgh_size++;
    XCTAssertFalse(sentrycrashcm_test_isValidMachException(&request, sizeof(request)));
}

- (void)testRequest_whenIDOrComplexBitInvalid_shouldReject
{
    // -- Arrange --
    TestExceptionRequest request = [self validReceivedRequest];
    // -- Act / Assert --
    request.header.msgh_id++;
    XCTAssertFalse(sentrycrashcm_test_isValidMachException(&request, sizeof(request)));
    request = [self validReceivedRequest];
    request.header.msgh_bits &= ~MACH_MSGH_BITS_COMPLEX;
    XCTAssertFalse(sentrycrashcm_test_isValidMachException(&request, sizeof(request)));
}

- (void)testRequest_whenDescriptorsInvalid_shouldReject
{
    // -- Arrange --
    TestExceptionRequest request = [self validReceivedRequest];
    // -- Act / Assert --
    request.body.msgh_descriptor_count = 1;
    XCTAssertFalse(sentrycrashcm_test_isValidMachException(&request, sizeof(request)));
    request = [self validReceivedRequest];
    request.task.type = MACH_MSG_OOL_DESCRIPTOR;
    XCTAssertFalse(sentrycrashcm_test_isValidMachException(&request, sizeof(request)));
    request = [self validReceivedRequest];
    request.thread.disposition = MACH_MSG_TYPE_MOVE_RECEIVE;
    XCTAssertFalse(sentrycrashcm_test_isValidMachException(&request, sizeof(request)));
    request = [self validReceivedRequest];
    request.task.name = MACH_PORT_DEAD;
    XCTAssertFalse(sentrycrashcm_test_isValidMachException(&request, sizeof(request)));
}

- (void)testRequest_whenReplyRightOrNDRInvalid_shouldReject
{
    // -- Arrange --
    TestExceptionRequest request = [self validReceivedRequest];
    // -- Act / Assert --
    request.header.msgh_remote_port = MACH_PORT_NULL;
    XCTAssertFalse(sentrycrashcm_test_isValidMachException(&request, sizeof(request)));
    request = [self validReceivedRequest];
    request.header.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_PORT_SEND, 0) | MACH_MSGH_BITS_COMPLEX;
    XCTAssertFalse(sentrycrashcm_test_isValidMachException(&request, sizeof(request)));
    request = [self validReceivedRequest];
    request.NDR.int_rep ^= 1;
    XCTAssertFalse(sentrycrashcm_test_isValidMachException(&request, sizeof(request)));
}

- (void)testTask_whenCurrent_shouldIdentifyHost
{
    // -- Arrange --
    task_t task = mach_task_self();
    // -- Act --
    bool isHost = sentrycrashcm_test_isHostExceptionTask(task);
    // -- Assert --
    XCTAssertTrue(isHost);
}

- (void)testTask_whenUnknown_shouldNeverIdentifyHost
{
    // -- Arrange --
    mach_port_t port = MACH_PORT_NULL;
    XCTAssertEqual(
        KERN_SUCCESS, mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &port));
    // -- Act / Assert --
    XCTAssertFalse(sentrycrashcm_test_isHostExceptionTask(MACH_PORT_NULL));
    XCTAssertFalse(sentrycrashcm_test_isHostExceptionTask(MACH_PORT_DEAD));
    XCTAssertFalse(sentrycrashcm_test_isHostExceptionTask(port));
    XCTAssertEqual(
        KERN_SUCCESS, mach_port_mod_refs(mach_task_self(), port, MACH_PORT_RIGHT_RECEIVE, -1));
}

- (void)testReply_whenFailure_shouldFollowMIGProtocol
{
    // -- Arrange --
    TestExceptionRequest request = [self validReceivedRequest];
    mig_reply_error_t reply = { 0 };
    // -- Act --
    sentrycrashcm_test_makeMachReply(&request.header, KERN_FAILURE, &reply);
    // -- Assert --
    XCTAssertEqual(2505, reply.Head.msgh_id);
    XCTAssertEqual(sizeof(mig_reply_error_t), reply.Head.msgh_size);
    XCTAssertEqual(request.header.msgh_remote_port, reply.Head.msgh_remote_port);
    XCTAssertEqual(MACH_PORT_NULL, reply.Head.msgh_local_port);
    XCTAssertEqual(MACH_MSGH_BITS(MACH_MSG_TYPE_MOVE_SEND_ONCE, 0), reply.Head.msgh_bits);
    XCTAssertEqual(KERN_FAILURE, reply.RetCode);
    XCTAssertEqual(0, memcmp(&NDR_record, &reply.NDR, sizeof(NDR_record)));
}

- (void)testSendResult_whenRecoverable_shouldRetainReplyOwnershipOnlyForCanonicalClass
{
    // -- Arrange / Act / Assert --
    XCTAssertTrue(sentrycrashcm_test_sendErrorRetainsReply(MACH_SEND_INVALID_DEST));
    XCTAssertTrue(sentrycrashcm_test_sendErrorRetainsReply(MACH_SEND_TIMED_OUT));
    XCTAssertTrue(sentrycrashcm_test_sendErrorRetainsReply(MACH_SEND_INTERRUPTED));
    XCTAssertFalse(sentrycrashcm_test_sendErrorRetainsReply(MACH_MSG_SUCCESS));
    XCTAssertFalse(sentrycrashcm_test_sendErrorRetainsReply(MACH_SEND_INVALID_RIGHT));
    XCTAssertFalse(sentrycrashcm_test_sendErrorRetainsReply(MACH_SEND_INVALID_HEADER));
}

- (mach_port_t)createPortWithSendRight
{
    mach_port_t port = MACH_PORT_NULL;
    XCTAssertEqual(
        KERN_SUCCESS, mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &port));
    XCTAssertEqual(KERN_SUCCESS,
        mach_port_insert_right(mach_task_self(), port, port, MACH_MSG_TYPE_MAKE_SEND));
    return port;
}

- (void)testReply_whenRealReceivedRights_shouldDeliverFailureAndReleaseBodyReferences
{
    // -- Arrange --
    mach_port_t server = [self createPortWithSendRight];
    mach_port_t replyPort = MACH_PORT_NULL;
    XCTAssertEqual(
        KERN_SUCCESS, mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &replyPort));
    mach_port_t first = [self createPortWithSendRight];
    mach_port_t second = [self createPortWithSendRight];
    TestExceptionRequest outgoing = [self validReceivedRequest];
    outgoing.header.msgh_bits
        = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, MACH_MSG_TYPE_MAKE_SEND_ONCE)
        | MACH_MSGH_BITS_COMPLEX;
    outgoing.header.msgh_remote_port = server;
    outgoing.header.msgh_local_port = replyPort;
    outgoing.thread.name = first;
    outgoing.thread.disposition = MACH_MSG_TYPE_COPY_SEND;
    outgoing.task.name = second;
    outgoing.task.disposition = MACH_MSG_TYPE_COPY_SEND;
    XCTAssertEqual(MACH_MSG_SUCCESS,
        mach_msg(&outgoing.header, MACH_SEND_MSG, sizeof(outgoing), 0, MACH_PORT_NULL, 0,
            MACH_PORT_NULL));
    TestReceiveBuffer received = { 0 };
    XCTAssertEqual(MACH_MSG_SUCCESS,
        mach_msg(&received.request.header, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, sizeof(received),
            server, 0, MACH_PORT_NULL));
    mach_port_urefs_t refs = 0;
    XCTAssertEqual(
        KERN_SUCCESS, mach_port_get_refs(mach_task_self(), first, MACH_PORT_RIGHT_SEND, &refs));
    XCTAssertEqual(2, refs);
    XCTAssertEqual(
        KERN_SUCCESS, mach_port_get_refs(mach_task_self(), second, MACH_PORT_RIGHT_SEND, &refs));
    XCTAssertEqual(2, refs);
    // -- Act --
    mach_msg_return_t result
        = sentrycrashcm_test_replyToMachException(&received.request, KERN_FAILURE);
    // -- Assert --
    XCTAssertEqual(MACH_MSG_SUCCESS, result);
    XCTAssertEqual(
        KERN_SUCCESS, mach_port_get_refs(mach_task_self(), first, MACH_PORT_RIGHT_SEND, &refs));
    XCTAssertEqual(1, refs);
    XCTAssertEqual(
        KERN_SUCCESS, mach_port_get_refs(mach_task_self(), second, MACH_PORT_RIGHT_SEND, &refs));
    XCTAssertEqual(1, refs);
    struct {
        mig_reply_error_t reply;
        mach_msg_max_trailer_t trailer;
    } response = { 0 };
    XCTAssertEqual(MACH_MSG_SUCCESS,
        mach_msg(&response.reply.Head, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, sizeof(response),
            replyPort, 0, MACH_PORT_NULL));
    XCTAssertEqual(2505, response.reply.Head.msgh_id);
    XCTAssertEqual(KERN_FAILURE, response.reply.RetCode);
    XCTAssertEqual(0, response.reply.Head.msgh_bits & MACH_MSGH_BITS_COMPLEX);
    XCTAssertEqual(KERN_SUCCESS, mach_port_deallocate(mach_task_self(), first));
    XCTAssertEqual(
        KERN_SUCCESS, mach_port_mod_refs(mach_task_self(), first, MACH_PORT_RIGHT_RECEIVE, -1));
    XCTAssertEqual(KERN_SUCCESS, mach_port_deallocate(mach_task_self(), second));
    XCTAssertEqual(
        KERN_SUCCESS, mach_port_mod_refs(mach_task_self(), second, MACH_PORT_RIGHT_RECEIVE, -1));
    XCTAssertEqual(KERN_SUCCESS, mach_port_deallocate(mach_task_self(), server));
    XCTAssertEqual(
        KERN_SUCCESS, mach_port_mod_refs(mach_task_self(), server, MACH_PORT_RIGHT_RECEIVE, -1));
    XCTAssertEqual(
        KERN_SUCCESS, mach_port_mod_refs(mach_task_self(), replyPort, MACH_PORT_RIGHT_RECEIVE, -1));
}

- (void)testReply_whenSendOnceReceiverDied_shouldConsumeRightAndBodyReferences
{
    // -- Arrange --
    mach_port_t server = [self createPortWithSendRight];
    mach_port_t replyPort = MACH_PORT_NULL;
    XCTAssertEqual(
        KERN_SUCCESS, mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &replyPort));
    mach_port_t first = [self createPortWithSendRight];
    mach_port_t second = [self createPortWithSendRight];
    TestExceptionRequest outgoing = [self validReceivedRequest];
    outgoing.header.msgh_bits
        = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, MACH_MSG_TYPE_MAKE_SEND_ONCE)
        | MACH_MSGH_BITS_COMPLEX;
    outgoing.header.msgh_remote_port = server;
    outgoing.header.msgh_local_port = replyPort;
    outgoing.thread.name = first;
    outgoing.thread.disposition = MACH_MSG_TYPE_COPY_SEND;
    outgoing.task.name = second;
    outgoing.task.disposition = MACH_MSG_TYPE_COPY_SEND;
    XCTAssertEqual(MACH_MSG_SUCCESS,
        mach_msg(&outgoing.header, MACH_SEND_MSG, sizeof(outgoing), 0, MACH_PORT_NULL, 0,
            MACH_PORT_NULL));
    TestReceiveBuffer received = { 0 };
    XCTAssertEqual(MACH_MSG_SUCCESS,
        mach_msg(&received.request.header, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, sizeof(received),
            server, 0, MACH_PORT_NULL));
    mach_port_t unsentRight = received.request.header.msgh_remote_port;
    // Destroy only this test's receive right before replying; no race or mock send result.
    XCTAssertEqual(
        KERN_SUCCESS, mach_port_mod_refs(mach_task_self(), replyPort, MACH_PORT_RIGHT_RECEIVE, -1));
    // -- Act --
    mach_msg_return_t result
        = sentrycrashcm_test_replyToMachException(&received.request, KERN_FAILURE);
    // -- Assert --
    XCTAssertEqual(MACH_MSG_SUCCESS, result);
    mach_port_type_t type = 0;
    XCTAssertEqual(KERN_INVALID_NAME, mach_port_type(mach_task_self(), unsentRight, &type));
    mach_port_urefs_t refs = 0;
    XCTAssertEqual(
        KERN_SUCCESS, mach_port_get_refs(mach_task_self(), first, MACH_PORT_RIGHT_SEND, &refs));
    XCTAssertEqual(1, refs);
    XCTAssertEqual(
        KERN_SUCCESS, mach_port_get_refs(mach_task_self(), second, MACH_PORT_RIGHT_SEND, &refs));
    XCTAssertEqual(1, refs);
    for (unsigned int i = 0; i < 3; i++) {
        mach_port_t port = (mach_port_t[]) { first, second, server }[i];
        XCTAssertEqual(KERN_SUCCESS, mach_port_deallocate(mach_task_self(), port));
        XCTAssertEqual(
            KERN_SUCCESS, mach_port_mod_refs(mach_task_self(), port, MACH_PORT_RIGHT_RECEIVE, -1));
    }
}
- (void)testReply_whenSendReceiverDied_shouldReleaseUnsentRightAndBodyReferences
{
    // -- Arrange --
    mach_port_t server = [self createPortWithSendRight];
    mach_port_t replyPort = MACH_PORT_NULL;
    XCTAssertEqual(
        KERN_SUCCESS, mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &replyPort));
    mach_port_t first = [self createPortWithSendRight];
    mach_port_t second = [self createPortWithSendRight];
    TestExceptionRequest outgoing = [self validReceivedRequest];
    outgoing.header.msgh_bits
        = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, MACH_MSG_TYPE_MAKE_SEND) | MACH_MSGH_BITS_COMPLEX;
    outgoing.header.msgh_remote_port = server;
    outgoing.header.msgh_local_port = replyPort;
    outgoing.thread.name = first;
    outgoing.thread.disposition = MACH_MSG_TYPE_COPY_SEND;
    outgoing.task.name = second;
    outgoing.task.disposition = MACH_MSG_TYPE_COPY_SEND;
    XCTAssertEqual(MACH_MSG_SUCCESS,
        mach_msg(&outgoing.header, MACH_SEND_MSG, sizeof(outgoing), 0, MACH_PORT_NULL, 0,
            MACH_PORT_NULL));
    TestReceiveBuffer received = { 0 };
    XCTAssertEqual(MACH_MSG_SUCCESS,
        mach_msg(&received.request.header, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, sizeof(received),
            server, 0, MACH_PORT_NULL));
    mach_port_t unsentRight = received.request.header.msgh_remote_port;
    // Destroy only this test's receive right before replying; no race or mock send result.
    XCTAssertEqual(
        KERN_SUCCESS, mach_port_mod_refs(mach_task_self(), replyPort, MACH_PORT_RIGHT_RECEIVE, -1));
    // -- Act --
    mach_msg_return_t result
        = sentrycrashcm_test_replyToMachException(&received.request, KERN_FAILURE);
    // -- Assert --
    XCTAssertEqual(MACH_SEND_INVALID_DEST, result);
    mach_port_type_t type = 0;
    XCTAssertEqual(KERN_INVALID_NAME, mach_port_type(mach_task_self(), unsentRight, &type));
    mach_port_urefs_t refs = 0;
    XCTAssertEqual(
        KERN_SUCCESS, mach_port_get_refs(mach_task_self(), first, MACH_PORT_RIGHT_SEND, &refs));
    XCTAssertEqual(1, refs);
    XCTAssertEqual(
        KERN_SUCCESS, mach_port_get_refs(mach_task_self(), second, MACH_PORT_RIGHT_SEND, &refs));
    XCTAssertEqual(1, refs);
    for (unsigned int i = 0; i < 3; i++) {
        mach_port_t port = (mach_port_t[]) { first, second, server }[i];
        XCTAssertEqual(KERN_SUCCESS, mach_port_deallocate(mach_task_self(), port));
        XCTAssertEqual(
            KERN_SUCCESS, mach_port_mod_refs(mach_task_self(), port, MACH_PORT_RIGHT_RECEIVE, -1));
    }
}
@end
#endif
