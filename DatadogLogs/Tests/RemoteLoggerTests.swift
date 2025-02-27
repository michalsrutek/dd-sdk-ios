/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

import XCTest
import TestUtilities
import DatadogInternal

@testable import DatadogLogs

private class ErrorMessageReceiverMock: FeatureMessageReceiver {
    struct ErrorMessage: Decodable {
        /// The Log error message
        let message: String
    }

    var errors: [String] = []

    /// Adds RUM Error with given message and stack to current RUM View.
    func receive(message: FeatureMessage, from core: DatadogCoreProtocol) -> Bool {
        guard
            let error = try? message.baggage(forKey: "error", type: ErrorMessage.self)
        else {
            return false
        }

        self.errors.append(error.message)

        return true
    }
}

class RemoteLoggerTests: XCTestCase {
    func testItSendsErrorAlongWithErrorLog() throws {
        let messageReceiver = ErrorMessageReceiverMock()

        let core = PassthroughCoreMock(
            expectation: expectation(description: "Send error"),
            messageReceiver: messageReceiver
        )

        // Given
        let logger = RemoteLogger(
            core: core,
            configuration: .mockAny(),
            dateProvider: RelativeDateProvider(),
            rumContextIntegration: false,
            activeSpanIntegration: false
        )

        // When
        logger.error("Error message")

        // Then
        waitForExpectations(timeout: 0.5, handler: nil)

        XCTAssertEqual(messageReceiver.errors.count, 1)
        XCTAssertEqual(messageReceiver.errors.first, "Error message")
    }

    func testItDoesNotSendErrorAlongWithCrossPlatformCrashLog() throws {
        let messageReceiver = ErrorMessageReceiverMock()

        let core = PassthroughCoreMock(
            expectation: expectation(description: "Send error"),
            messageReceiver: messageReceiver
        )

        // Given
        let logger = RemoteLogger(
            core: core,
            configuration: .mockAny(),
            dateProvider: RelativeDateProvider(),
            rumContextIntegration: false,
            activeSpanIntegration: false
        )

        // When
        logger.error("Error message", error: nil, attributes: [CrossPlatformAttributes.errorLogIsCrash: true])

        // Then
        waitForExpectations(timeout: 0.5, handler: nil)

        XCTAssertEqual(messageReceiver.errors.count, 0)
    }

    // MARK: - RUM Integration

    func testWhenRUMIntegrationIsEnabled_itSendsLogWithRUMContext() throws {
        let core = PassthroughCoreMock(
            expectation: expectation(description: "Send log")
        )

        // Given
        let logger = RemoteLogger(
            core: core,
            configuration: .mockAny(),
            dateProvider: RelativeDateProvider(),
            rumContextIntegration: true,
            activeSpanIntegration: false
        )

        let applicationID: String = .mockRandom()
        let sessionID: String = .mockRandom()
        let viewID: String = .mockRandom()
        let actionID: String = .mockRandom()

        // When
        core.set(
            baggage: [
                "application.id": applicationID,
                "session.id": sessionID,
                "view.id": viewID,
                "user_action.id": actionID
            ],
            forKey: "rum"
        )

        logger.info("message")

        // Then
        waitForExpectations(timeout: 0.5, handler: nil)

        let logs = core.events(ofType: LogEvent.self)
        XCTAssertEqual(logs.count, 1)

        let log = try XCTUnwrap(logs.first)
        XCTAssertEqual(log.attributes.internalAttributes?["application_id"] as? String, applicationID)
        XCTAssertEqual(log.attributes.internalAttributes?["session_id"] as? String, sessionID)
        XCTAssertEqual(log.attributes.internalAttributes?["view.id"] as? String, viewID)
        XCTAssertEqual(log.attributes.internalAttributes?["user_action.id"] as? String, actionID)
    }

    func testWhenRUMIntegrationIsEnabled_withNoRUMContext_itDoesNotSendTelemetryError() throws {
        let telemetryReceiver = TelemetryReceiverMock()
        let core = PassthroughCoreMock(
            expectation: expectation(description: "Send log"),
            messageReceiver: telemetryReceiver
        )

        // Given
        let logger = RemoteLogger(
            core: core,
            configuration: .mockAny(),
            dateProvider: RelativeDateProvider(),
            rumContextIntegration: true,
            activeSpanIntegration: false
        )

        // When
        core.set(baggage: nil, forKey: "rum")

        logger.info("message")

        // Then
        waitForExpectations(timeout: 0.5, handler: nil)

        let logs = core.events(ofType: LogEvent.self)
        XCTAssertEqual(logs.count, 1)

        let log = try XCTUnwrap(logs.first)
        XCTAssertNil(log.attributes.internalAttributes?["application_id"])
        XCTAssertNil(log.attributes.internalAttributes?["session_id"])
        XCTAssertNil(log.attributes.internalAttributes?["view.id"])
        XCTAssertNil(log.attributes.internalAttributes?["user_action.id"])
        XCTAssertTrue(telemetryReceiver.messages.isEmpty)
    }

    func testWhenRUMIntegrationIsEnabled_withMalformedRUMContext_itSendsTelemetryError() throws {
        let telemetryReceiver = TelemetryReceiverMock()
        let core = PassthroughCoreMock(
            expectation: expectation(description: "Send log"),
            messageReceiver: telemetryReceiver
        )

        // Given
        let logger = RemoteLogger(
            core: core,
            configuration: .mockAny(),
            dateProvider: RelativeDateProvider(),
            rumContextIntegration: true,
            activeSpanIntegration: false
        )

        // When
        core.set(baggage: "malformed RUM context", forKey: "rum")

        logger.info("message")

        // Then
        waitForExpectations(timeout: 0.5, handler: nil)

        let logs = core.events(ofType: LogEvent.self)
        XCTAssertEqual(logs.count, 1)

        let log = try XCTUnwrap(logs.first)
        XCTAssertNil(log.attributes.internalAttributes?["application_id"])
        XCTAssertNil(log.attributes.internalAttributes?["session_id"])
        XCTAssertNil(log.attributes.internalAttributes?["view.id"])
        XCTAssertNil(log.attributes.internalAttributes?["user_action.id"])

        let error = try XCTUnwrap(telemetryReceiver.messages.first?.asError)
        XCTAssert(error.message.contains("Fails to decode RUM context from Logs - typeMismatch"))
    }

    // MARK: - Span Integration

    func testWhenActiveSpanIntegrationIsEnabled_itSendsLogWithSpanContext() throws {
        let core = PassthroughCoreMock(
            expectation: expectation(description: "Send log")
        )

        // Given
        let logger = RemoteLogger(
            core: core,
            configuration: .mockAny(),
            dateProvider: RelativeDateProvider(),
            rumContextIntegration: false,
            activeSpanIntegration: true
        )

        let traceID: String = .mockRandom()
        let spanID: String = .mockRandom()

        // When
        core.set(
            baggage: [
                "dd.trace_id": traceID,
                "dd.span_id": spanID
            ],
            forKey: "span_context"
        )

        logger.info("message")

        // Then
        waitForExpectations(timeout: 0.5, handler: nil)

        let logs = core.events(ofType: LogEvent.self)
        XCTAssertEqual(logs.count, 1)

        let log = try XCTUnwrap(logs.first)
        XCTAssertEqual(log.attributes.internalAttributes?["dd.trace_id"] as? String, traceID)
        XCTAssertEqual(log.attributes.internalAttributes?["dd.span_id"] as? String, spanID)
    }

    func testWhenActiveSpanIntegrationIsEnabled_withNoActiveSpan_itDoesNotSendTelemetryError() throws {
        let telemetryReceiver = TelemetryReceiverMock()
        let core = PassthroughCoreMock(
            expectation: expectation(description: "Send log"),
            messageReceiver: telemetryReceiver
        )

        // Given
        let logger = RemoteLogger(
            core: core,
            configuration: .mockAny(),
            dateProvider: RelativeDateProvider(),
            rumContextIntegration: false,
            activeSpanIntegration: true
        )

        // When
        core.set(baggage: nil, forKey: "span_context")

        logger.info("message")

        // Then
        waitForExpectations(timeout: 0.5, handler: nil)

        let logs = core.events(ofType: LogEvent.self)
        XCTAssertEqual(logs.count, 1)

        let log = try XCTUnwrap(logs.first)
        XCTAssertNil(log.attributes.internalAttributes?["dd.trace_id"])
        XCTAssertNil(log.attributes.internalAttributes?["dd.span_id"])
        XCTAssertTrue(telemetryReceiver.messages.isEmpty)
    }

    func testWhenActiveSpanIntegrationIsEnabled_withMalformedRUMContext_itSendsTelemetryError() throws {
        let telemetryReceiver = TelemetryReceiverMock()
        let core = PassthroughCoreMock(
            expectation: expectation(description: "Send log"),
            messageReceiver: telemetryReceiver
        )

        // Given
        let logger = RemoteLogger(
            core: core,
            configuration: .mockAny(),
            dateProvider: RelativeDateProvider(),
            rumContextIntegration: false,
            activeSpanIntegration: true
        )

        // When
        core.set(baggage: "malformed Span context", forKey: "span_context")

        logger.info("message")

        // Then
        waitForExpectations(timeout: 0.5, handler: nil)

        let logs = core.events(ofType: LogEvent.self)
        XCTAssertEqual(logs.count, 1)

        let log = try XCTUnwrap(logs.first)
        XCTAssertNil(log.attributes.internalAttributes?["dd.trace_id"])
        XCTAssertNil(log.attributes.internalAttributes?["dd.span_id"])

        let error = try XCTUnwrap(telemetryReceiver.messages.first?.asError)
        XCTAssert(error.message.contains("Fails to decode Span context from Logs - typeMismatch"))
    }
}
