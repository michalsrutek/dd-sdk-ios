/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

import Foundation
import DatadogInternal

/// Defines keys referencing RUM messages supported on the bus.
internal enum LoggingMessageKeys {
    /// The key references a log entry message.
    static let log = "log"

    /// The key references a crash message.
    static let crash = "crash"

    /// The key references a browser log message.
    static let browserLog = "browser-log"
}

/// Receiver to consume a Log message
internal struct LogMessageReceiver: FeatureMessageReceiver {
    struct LogMessage: Decodable {
        /// The Logger name
        let logger: String
        /// The Logger service
        let service: String?
        /// The Log date
        let date: Date
        /// The Log message
        let message: String
        /// The Log error
        let error: DDError?
        /// The Log level
        let level: LogLevel
        /// The thread name
        let thread: String
        /// The thread name
        let networkInfoEnabled: Bool?
        /// The Log user custom attributes
        let userAttributes: [String: AnyCodable]?
        /// The Log internal attributes
        let internalAttributes: [String: AnyCodable]?
    }

    /// The log event mapper
    let logEventMapper: LogEventMapper?

    /// Process messages receives from the bus.
    ///
    /// - Parameters:
    ///   - message: The Feature message
    ///   - core: The core from which the message is transmitted.
    func receive(message: FeatureMessage, from core: DatadogCoreProtocol) -> Bool {
        do {
            guard let log: LogMessage = try message.baggage(forKey: LoggingMessageKeys.log) else {
                return false
            }

            core.scope(for: LogsFeature.name)?.eventWriteContext { context, writer in
                let builder = LogEventBuilder(
                    service: log.service ?? context.service,
                    loggerName: log.logger,
                    networkInfoEnabled: log.networkInfoEnabled ?? false,
                    eventMapper: logEventMapper
                )

                builder.createLogEvent(
                    date: log.date,
                    level: log.level,
                    message: log.message,
                    error: log.error,
                    attributes: .init(
                        userAttributes: log.userAttributes ?? [:],
                        internalAttributes: log.internalAttributes
                    ),
                    tags: [],
                    context: context,
                    threadName: log.thread,
                    callback: writer.write
                )
            }

            return true
        } catch {
            core.telemetry
                .error("Fails to decode crash from Logs", error: error)
        }

        return false
    }
}

/// Receiver to consume a Crash Log message as Log.
internal struct CrashLogReceiver: FeatureMessageReceiver {
    private struct Crash: Decodable {
        /// The crash report.
        let report: CrashReport
        /// The crash context
        let context: CrashContext
    }

    private struct CrashReport: Decodable {
        /// The date of the crash occurrence.
        let date: Date?
        /// Crash report type - used to group similar crash reports.
        /// In Datadog Error Tracking this corresponds to `error.type`.
        let type: String
        /// Crash report message - if possible, it should provide additional troubleshooting information in addition to the crash type.
        /// In Datadog Error Tracking this corresponds to `error.message`.
        let message: String
        /// Unsymbolicated stack trace related to the crash (this can be either uncaugh exception backtrace or stack trace of the halted thread).
        /// In Datadog Error Tracking this corresponds to `error.stack`.
        let stack: String
        /// All threads running in the process.
        let threads: AnyCodable
        /// List of binary images referenced from all stack traces.
        let binaryImages: AnyCodable
        /// Meta information about the crash and process.
        let meta: AnyCodable
        /// If any stack trace information was truncated due to crash report minimization.
        let wasTruncated: Bool
    }

    private struct CrashContext: Decodable {
        /// Interval between device and server time.
        let serverTimeOffset: TimeInterval
        /// The name of the service that data is generated from.
        let service: String
        /// The name of the environment that data is generated from.
        let env: String
        /// The version of the application that data is generated from.
        let version: String
        /// The build number of the application that data is generated from.
        let buildNumber: String
        /// Current device information.
        let device: DeviceInfo
        /// The version of Datadog iOS SDK.
        let sdkVersion: String
        /// Network information.
        ///
        /// Represents the current state of the device network connectivity and interface.
        /// The value can be `unknown` if the network interface is not available or if it has not
        /// yet been evaluated.
        let networkConnectionInfo: NetworkConnectionInfo?
        /// Carrier information.
        ///
        /// Represents the current telephony service info of the device.
        /// This value can be `nil` of no service is currently registered, or if the device does
        /// not support telephony services.
        let carrierInfo: CarrierInfo?
        /// Current user information.
        let userInfo: UserInfo?
    }

    /// Time provider.
    let dateProvider: DateProvider

    /// Process messages receives from the bus.
    ///
    /// - Parameters:
    ///   - message: The Feature message
    ///   - core: The core from which the message is transmitted.
    func receive(message: FeatureMessage, from core: DatadogCoreProtocol) -> Bool {
        do {
            guard let crash: Crash = try message.baggage(forKey: LoggingMessageKeys.crash) else {
                return false
            }

            return send(report: crash.report, with: crash.context, to: core)
        } catch {
            core.telemetry
                .error("Fails to decode crash from RUM", error: error)
        }
        return false
    }

    private func send(report: CrashReport, with context: CrashContext, to core: DatadogCoreProtocol) -> Bool {
        // The `report.crashDate` uses system `Date` collected at the moment of crash, so we need to adjust it
        // to the server time before processing. Following use of the current correction is not ideal, but this is the best
        // approximation we can get.
        let date = (report.date ?? dateProvider.now)
            .addingTimeInterval(context.serverTimeOffset)

        var errorAttributes: [AttributeKey: AttributeValue] = [:]
        errorAttributes[DDError.threads] = report.threads
        errorAttributes[DDError.binaryImages] = report.binaryImages
        errorAttributes[DDError.meta] = report.meta
        errorAttributes[DDError.wasTruncated] = report.wasTruncated

        let user = context.userInfo
        let deviceInfo = context.device

        let event = LogEvent(
            date: date,
            status: .emergency,
            message: report.message,
            error: .init(
                kind: report.type,
                message: report.message,
                stack: report.stack
            ),
            serviceName: context.service,
            environment: context.env,
            loggerName: "crash-reporter",
            loggerVersion: context.sdkVersion,
            threadName: nil,
            applicationVersion: context.version,
            applicationBuildNumber: context.buildNumber,
            dd: .init(
                device: .init(architecture: deviceInfo.architecture)
            ),
            os: .init(
                name: context.device.osName,
                version: context.device.osVersion,
                build: context.device.osBuildNumber
            ),
            userInfo: .init(
                id: user?.id,
                name: user?.name,
                email: user?.email,
                extraInfo: user?.extraInfo ?? [:]
            ),
            networkConnectionInfo: context.networkConnectionInfo,
            mobileCarrierInfo: context.carrierInfo,
            attributes: .init(userAttributes: [:], internalAttributes: errorAttributes),
            tags: nil
        )

        // crash reporting is considering the user consent from previous session, if an event reached
        // the message bus it means that consent was granted and we can safely bypass current consent.
        core.scope(for: LogsFeature.name)?.eventWriteContext(bypassConsent: true, forceNewBatch: false) { _, writer in
            writer.write(value: event)
        }

        return true
    }
}

/// Receiver to consume a Log event coming from Browser SDK.
internal struct WebViewLogReceiver: FeatureMessageReceiver {
    /// Process messages receives from the bus.
    ///
    /// - Parameters:
    ///   - message: The Feature message
    ///   - core: The core from which the message is transmitted.
    func receive(message: FeatureMessage, from core: DatadogCoreProtocol) -> Bool {
        do {
            guard case let .baggage(label, baggage) = message, label == LoggingMessageKeys.browserLog else {
                return false
            }

            guard var event = try baggage.encode() as? [String: Any?] else {
                throw InternalError(description: "event is not a dictionary")
            }

            let versionKey = LogEventEncoder.StaticCodingKeys.applicationVersion.rawValue
            let envKey = LogEventEncoder.StaticCodingKeys.environment.rawValue
            let tagsKey = LogEventEncoder.StaticCodingKeys.tags.rawValue
            let dateKey = LogEventEncoder.StaticCodingKeys.date.rawValue

            core.scope(for: LogsFeature.name)?.eventWriteContext { context, writer in
                let ddTags = "\(versionKey):\(context.version),\(envKey):\(context.env)"

                if let tags = event[tagsKey] as? String, !tags.isEmpty {
                    event[tagsKey] = "\(ddTags),\(tags)"
                } else {
                    event[tagsKey] = ddTags
                }

                if let timestampInMs = event[dateKey] as? Int64 {
                    let serverTimeOffsetInMs = context.serverTimeOffset.toInt64Milliseconds
                    let correctedTimestamp = Int64(timestampInMs) + serverTimeOffsetInMs
                    event[dateKey] = correctedTimestamp
                }

                if let rum = context.baggages[RUMContext.key] {
                    do {
                        let context = try rum.decode(type: RUMContext.self)
                        event.merge(context.internalAttributes) { $1 }
                    } catch {
                        core.telemetry.error("Fails to decode RUM context from Logs", error: error)
                    }
                }

                writer.write(value: AnyEncodable(event))
            }

            return true
        } catch {
            core.telemetry
                .error("Fails to decode browser log", error: error)
        }

        return false
    }
}
