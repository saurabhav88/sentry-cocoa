#if SWIFT_PACKAGE
@_spi(Private) @testable import SentrySwift
#else
@_spi(Private) @testable import Sentry
#endif
import SentryTestUtils
import XCTest

class SentryStacktraceTests: XCTestCase {

    func testSerialize() {
        let stacktrace = TestData.stacktrace
        
        let actual = stacktrace.serialize()
        
        // Changing the original doesn't modify the serialized
        stacktrace.frames.removeAll()
        stacktrace.registers.removeAll()
        
        let frames = actual["frames"] as? [Any]
        XCTAssertEqual(1, frames?.count)
        XCTAssertEqual(["register": "one"], actual["registers"] as? [String: String])
        XCTAssertEqual(stacktrace.snapshot, actual["snapshot"] as? NSNumber)
    }
    
    func testSerializeNoRegisters() {
        let stacktrace = TestData.stacktrace
        stacktrace.registers = [:]
        let actual = stacktrace.serialize()

        XCTAssertNil(actual["registers"] as? [String: String])
    }
    
    func testSerializeNoFrames() {
        let stacktrace = TestData.stacktrace
        stacktrace.frames = []
        let actual = stacktrace.serialize()
        
        XCTAssertNil(actual["frames"] as? [Any])
    }
    
    func testSerialize_Bools() {
        SentryBooleanSerialization.test(SentryStacktrace(frames: [], registers: [:]), property: "snapshot")
    }
    
    func testDecode_WithAllProperties() throws {
        // Arrange
        let stacktrace = TestData.stacktrace
        let serialized = stacktrace.serialize()
        let data = try XCTUnwrap(SentrySerializationSwift.data(withJSONObject: serialized))
        
        // Act
        let decoded = try XCTUnwrap(decodeFromJSONData(jsonData: data) as SentryStacktraceDecodable?)
        
        // Assert
        XCTAssertEqual(stacktrace.frames.count, decoded.frames.count)
        XCTAssertEqual(stacktrace.registers, decoded.registers)
        XCTAssertEqual(stacktrace.snapshot, decoded.snapshot)
    }
    
    func testDecode_MissingSnapshot() throws {
        // Arrange
        let stacktrace = TestData.stacktrace
        stacktrace.snapshot = nil
        let serialized = stacktrace.serialize()
        let data = try XCTUnwrap(SentrySerializationSwift.data(withJSONObject: serialized))
        
        // Act
        let decoded = try XCTUnwrap(decodeFromJSONData(jsonData: data) as SentryStacktraceDecodable?)
        
        // Assert
        XCTAssertEqual(stacktrace.frames.count, decoded.frames.count)
        XCTAssertEqual(stacktrace.registers, decoded.registers)
        XCTAssertNil(decoded.snapshot)
    }
    
    func testDecode_EmptyFrames() throws {
        // Arrange
        let stacktrace = TestData.stacktrace
        stacktrace.frames = []
        let serialized = stacktrace.serialize()
        let data = try XCTUnwrap(SentrySerializationSwift.data(withJSONObject: serialized))
        
        // Act
        let decoded = try XCTUnwrap(decodeFromJSONData(jsonData: data) as SentryStacktraceDecodable?)
        
        // Assert
        XCTAssertEqual(stacktrace.frames.count, decoded.frames.count)
        XCTAssertEqual(stacktrace.registers, decoded.registers)
        XCTAssertEqual(stacktrace.snapshot, decoded.snapshot)
    }
    
    func testDecode_EmptyRegisters() throws {
        // Arrange
        let stacktrace = TestData.stacktrace
        stacktrace.registers = [:]
        let serialized = stacktrace.serialize()
        let data = try XCTUnwrap(SentrySerializationSwift.data(withJSONObject: serialized))
        
        // Act
        let decoded = try XCTUnwrap(decodeFromJSONData(jsonData: data) as SentryStacktraceDecodable?)
        
        // Assert
        XCTAssertEqual(stacktrace.frames.count, decoded.frames.count)
        XCTAssertEqual(stacktrace.registers, decoded.registers)
        XCTAssertEqual(stacktrace.snapshot, decoded.snapshot)
    }

    private func callerStack(_ addresses: [String], registers: [String: String]) -> SentryStacktrace {
        let frames = addresses.enumerated().map { index, address in
            let frame = Frame()
            frame.instructionAddress = address
            frame.function = "captured_\(index)"
            return frame
        }
        return SentryStacktrace(frames: frames, registers: registers)
    }

    func testFixDuplicateFrames_whenTwoDistinctPCLR_shouldPreserveBoth() {
        // -- Arrange --
        let stack = callerStack(["0x200", "0x100"], registers: ["lr": "0x200", "pc": "0x100"])
        // -- Act --
        stack.fixDuplicateFrames()
        // -- Assert --
        XCTAssertEqual(stack.frames.map { $0.instructionAddress }, ["0x200", "0x100"])
        XCTAssertEqual(stack.frames.map { $0.function }, ["captured_0", "captured_1"])
        XCTAssertEqual(stack.registers, ["lr": "0x200", "pc": "0x100"])
    }

    func testFixDuplicateFrames_whenTwoEqualPCLR_shouldPreserveIncompleteEvidence() {
        // -- Arrange --
        let stack = callerStack(["0x100", "0x100"], registers: ["lr": "0x100"])
        // -- Act --
        stack.fixDuplicateFrames()
        // -- Assert --
        XCTAssertEqual(stack.frames.map { $0.instructionAddress }, ["0x100", "0x100"])
        XCTAssertEqual(stack.frames.map { $0.function }, ["captured_0", "captured_1"])
        XCTAssertEqual(stack.registers, ["lr": "0x100"])
    }

    func testFixDuplicateFrames_whenEmptyOrOneFrame_shouldPreserve() {
        // -- Arrange / Act / Assert --
        for addresses in [[], ["0x100"]] {
            let stack = callerStack(addresses, registers: ["lr": "0x100"])
            stack.fixDuplicateFrames()
            XCTAssertEqual(stack.frames.map { $0.instructionAddress }, addresses)
            XCTAssertEqual(stack.registers, ["lr": "0x100"])
        }
    }

    func testFixDuplicateFrames_whenRegistersOrLRAbsent_shouldPreserve() {
        // -- Arrange / Act / Assert --
        for registers in [[:], ["pc": "0x100"]] {
            let stack = callerStack(["0x200", "0x200", "0x100"], registers: registers)
            stack.fixDuplicateFrames()
            XCTAssertEqual(stack.frames.map { $0.instructionAddress }, ["0x200", "0x200", "0x100"])
            XCTAssertEqual(stack.frames.map { $0.function }, ["captured_0", "captured_1", "captured_2"])
            XCTAssertEqual(stack.registers, registers)
        }
    }

    func testFixDuplicateFrames_whenCapturedCallerProvesDuplicate_shouldRemoveOnlyLR() {
        // -- Arrange --
        let stack = callerStack(["0x300", "0x200", "0x200", "0x100"], registers: ["lr": "0x200"])
        // -- Act --
        stack.fixDuplicateFrames()
        // -- Assert --
        XCTAssertEqual(stack.frames.map { $0.instructionAddress }, ["0x300", "0x200", "0x100"])
        XCTAssertEqual(stack.frames.map { $0.function }, ["captured_0", "captured_1", "captured_3"])
        XCTAssertEqual(stack.registers, ["lr": "0x200"])
    }

    func testFixDuplicateFrames_whenLRIsNotCapturedCaller_shouldPreserveEveryFrame() {
        // -- Arrange --
        let stack = callerStack(["0x300", "0x200", "0x100"], registers: ["lr": "0x200"])
        // -- Act --
        stack.fixDuplicateFrames()
        // -- Assert --
        XCTAssertEqual(stack.frames.map { $0.instructionAddress }, ["0x300", "0x200", "0x100"])
        XCTAssertEqual(stack.frames.map { $0.function }, ["captured_0", "captured_1", "captured_2"])
        XCTAssertEqual(stack.registers, ["lr": "0x200"])
    }

    func testFixDuplicateFrames_whenRecursiveCallerChain_shouldPreserveCapturedDepth() {
        // -- Arrange --
        let stack = callerStack(["0x200", "0x200", "0x200", "0x200", "0x100"], registers: ["lr": "0x200"])
        // -- Act --
        stack.fixDuplicateFrames()
        // -- Assert --
        XCTAssertEqual(stack.frames.map { $0.instructionAddress }, ["0x200", "0x200", "0x200", "0x100"])
        XCTAssertEqual(stack.frames.map { $0.function }, ["captured_0", "captured_1", "captured_2", "captured_4"])
        XCTAssertEqual(stack.registers, ["lr": "0x200"])
    }

    func testFixDuplicateFrames_whenRepeatedAddressesDoNotMatchLR_shouldPreserve() {
        // -- Arrange --
        let stack = callerStack(["0x200", "0x200", "0x100"], registers: ["lr": "0x999"])
        // -- Act --
        stack.fixDuplicateFrames()
        // -- Assert --
        XCTAssertEqual(stack.frames.map { $0.instructionAddress }, ["0x200", "0x200", "0x100"])
        XCTAssertEqual(stack.frames.map { $0.function }, ["captured_0", "captured_1", "captured_2"])
        XCTAssertEqual(stack.registers, ["lr": "0x999"])
    }
}
