/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-2020 Datadog, Inc.
 */

import XCTest
import TestUtilities

@testable import DatadogInternal

class TelemetryTests: XCTestCase {
    func testTelemetryDebug() {
        // Given
        class TelemetryTest: Telemetry {
            var debug: (id: String, message: String, attributes: [String: Encodable]?)?

            func send(telemetry: DatadogInternal.TelemetryMessage) {
                guard case let .debug(id, message, attributes) = telemetry else {
                    return
                }

                debug = (id: id, message: message, attributes: attributes)
            }
        }

        let telemetry = TelemetryTest()

        struct SwiftError: Error {
            let description = "error description"
        }

        // When
        #sourceLocation(file: "File.swift", line: 1)
        telemetry.debug("debug message", attributes: ["foo": "bar"])
        #sourceLocation()

        // Then
        XCTAssertEqual(telemetry.debug?.id, "File.swift:1:debug message")
        XCTAssertEqual(telemetry.debug?.message, "debug message")
        XCTAssertEqual(telemetry.debug?.attributes as? [String: String], ["foo": "bar"])
    }

    func testTelemetryErrorFormatting() {
        // Given
        class TelemetryTest: Telemetry {
            var error: (id: String, message: String, kind: String?, stack: String?)?

            func send(telemetry: DatadogInternal.TelemetryMessage) {
                guard case let .error(id, message, kind, stack) = telemetry else {
                    return
                }

                error = (id: id, message: message, kind: kind, stack: stack)
            }
        }

        let telemetry = TelemetryTest()

        struct SwiftError: Error {
            let description = "error description"
        }

        let swiftError = SwiftError()

        let nsError = NSError(
            domain: "custom-domain",
            code: 10,
            userInfo: [
                NSLocalizedDescriptionKey: "error description"
            ]
        )

        // When
        #sourceLocation(file: "File.swift", line: 1)
        telemetry.error(swiftError)
        #sourceLocation()

        // Then
        XCTAssertEqual(telemetry.error?.id, #"File.swift:1:SwiftError(description: "error description")"#)
        XCTAssertEqual(telemetry.error?.message, #"SwiftError(description: "error description")"#)
        XCTAssertEqual(telemetry.error?.kind, "SwiftError")
        XCTAssertEqual(telemetry.error?.stack, #"SwiftError(description: "error description")"#)

        // When
        #sourceLocation(file: "File.swift", line: 2)
        telemetry.error(nsError)
        #sourceLocation()

        // Then
        XCTAssertEqual(telemetry.error?.id, "File.swift:2:error description")
        XCTAssertEqual(telemetry.error?.message, "error description")
        XCTAssertEqual(telemetry.error?.kind, "custom-domain - 10")
        XCTAssertEqual(
            telemetry.error?.stack,
            """
            Error Domain=custom-domain Code=10 "error description" UserInfo={NSLocalizedDescription=error description}
            """
        )

        // When
        telemetry.error("swift error", error: swiftError)
        // Then
        XCTAssertEqual(telemetry.error?.message, #"swift error - SwiftError(description: "error description")"#)

        // When
        telemetry.error("ns error", error: nsError)
        // Then
        XCTAssertEqual(telemetry.error?.message, "ns error - error description")
    }

    func testTelemetryConfiguration() {
        // Given
        let expectedConfiguration: ConfigurationTelemetry = .mockRandom()

        let telemetry = TelemetryTest()

        // When
        telemetry.applyConfiguration(configuration: expectedConfiguration)

        // Then
        XCTAssertEqual(telemetry.configuration, expectedConfiguration)
    }

    func testTelemetryConfigurationMerge() {
        // Given
        let initialConfiguration: ConfigurationTelemetry = .mockRandom()
        let expectedConfiguration: ConfigurationTelemetry = .mockRandom()

        let telemetry = TelemetryTest()

        // When
        telemetry.applyConfiguration(configuration: initialConfiguration)
        telemetry.applyConfiguration(configuration: expectedConfiguration)

        // Then
        XCTAssertEqual(telemetry.configuration, expectedConfiguration)
        XCTAssertNotEqual(telemetry.configuration, initialConfiguration)
    }

    func testWhenSendingTelemetryMessage_itForwardsToCore() {
        // Given
        class Receiver: FeatureMessageReceiver {
            var telemetry: TelemetryMessage?

            func receive(message: FeatureMessage, from core: DatadogCoreProtocol) -> Bool {
                guard case .telemetry(let telemetry) = message else {
                    return false
                }

                self.telemetry = telemetry
                return true
            }
        }

        let receiver = Receiver()
        let core = PassthroughCoreMock(messageReceiver: receiver)

        // When
        core.telemetry.debug("debug")

        // Then
        guard case .debug(_, let message, _) = receiver.telemetry else {
            return XCTFail("A debug should be send to core.")
        }
        XCTAssertEqual(message, "debug")

        // When
        core.telemetry.error("error")

        // Then
        guard case .error(_, let message, _, _) = receiver.telemetry else {
            return XCTFail("An error should be send to core.")
        }
        XCTAssertEqual(message, "error")

        // When
        core.telemetry.configuration(batchSize: 0)

        // Then
        guard case .configuration(let configuration) = receiver.telemetry else {
            return XCTFail("An error should be send to core.")
        }
        XCTAssertEqual(configuration.batchSize, 0)
    }
}

class TelemetryTest: Telemetry {
    var configuration: ConfigurationTelemetry?

    func send(telemetry: DatadogInternal.TelemetryMessage) {
        guard case .configuration(let configuration) = telemetry else {
            return
        }

        self.configuration = configuration
    }

    internal func applyConfiguration(configuration: ConfigurationTelemetry) {
        self.configuration(
            actionNameAttribute: configuration.actionNameAttribute,
            allowFallbackToLocalStorage: configuration.allowFallbackToLocalStorage,
            allowUntrustedEvents: configuration.allowUntrustedEvents,
            batchSize: configuration.batchSize,
            batchUploadFrequency: configuration.batchUploadFrequency,
            dartVersion: configuration.dartVersion,
            defaultPrivacyLevel: configuration.defaultPrivacyLevel,
            forwardErrorsToLogs: configuration.forwardErrorsToLogs,
            initializationType: configuration.initializationType,
            mobileVitalsUpdatePeriod: configuration.mobileVitalsUpdatePeriod,
            premiumSampleRate: configuration.premiumSampleRate,
            reactNativeVersion: configuration.reactNativeVersion,
            reactVersion: configuration.reactVersion,
            replaySampleRate: configuration.replaySampleRate,
            sessionReplaySampleRate: configuration.sessionReplaySampleRate,
            sessionSampleRate: configuration.sessionSampleRate,
            silentMultipleInit: configuration.silentMultipleInit,
            startSessionReplayRecordingManually: configuration.startSessionReplayRecordingManually,
            telemetryConfigurationSampleRate: configuration.telemetryConfigurationSampleRate,
            telemetrySampleRate: configuration.telemetrySampleRate,
            traceSampleRate: configuration.traceSampleRate,
            trackBackgroundEvents: configuration.trackBackgroundEvents,
            trackCrossPlatformLongTasks: configuration.trackCrossPlatformLongTasks,
            trackErrors: configuration.trackErrors,
            trackFlutterPerformance: configuration.trackFlutterPerformance,
            trackFrustrations: configuration.trackFrustrations,
            trackInteractions: configuration.trackInteractions,
            trackLongTask: configuration.trackLongTask,
            trackNativeErrors: configuration.trackNativeErrors,
            trackNativeLongTasks: configuration.trackNativeLongTasks,
            trackNativeViews: configuration.trackNativeViews,
            trackNetworkRequests: configuration.trackNetworkRequests,
            trackResources: configuration.trackResources,
            trackSessionAcrossSubdomains: configuration.trackSessionAcrossSubdomains,
            trackUserInteractions: configuration.trackUserInteractions,
            trackViewsManually: configuration.trackViewsManually,
            useAllowedTracingOrigins: configuration.useAllowedTracingOrigins,
            useAllowedTracingUrls: configuration.useAllowedTracingUrls,
            useBeforeSend: configuration.useBeforeSend,
            useCrossSiteSessionCookie: configuration.useCrossSiteSessionCookie,
            useExcludedActivityUrls: configuration.useExcludedActivityUrls,
            useFirstPartyHosts: configuration.useFirstPartyHosts,
            useLocalEncryption: configuration.useLocalEncryption,
            useProxy: configuration.useProxy,
            useSecureSessionCookie: configuration.useSecureSessionCookie,
            useTracing: configuration.useTracing,
            useWorkerUrl: configuration.useWorkerUrl
        )
    }
}
