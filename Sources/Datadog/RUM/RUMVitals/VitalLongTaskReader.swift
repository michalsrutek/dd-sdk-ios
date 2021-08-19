/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-2020 Datadog, Inc.
 */

import Foundation

/// A class reading the refresh rate (frames per second) of the main screen
internal class VitalLongTaskReader: ContinuousVitalReader {
    static let longTaskDurationThreshold: TimeInterval = 0.01

    private var valuePublishers = [VitalPublisher]()
    private var observer_begin: CFRunLoopObserver?
    private var observer_end: CFRunLoopObserver?
    private var lastActivity: (kind: CFRunLoopActivity, date: Date)?

    init() {
        let activites_begin: [CFRunLoopActivity] = [.entry, .afterWaiting, .beforeSources, .beforeTimers]
        observer_begin = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault,
            CFRunLoopActivity(activites_begin).rawValue,
            true,
            CFIndex.min
        ) { block_obs, block_act in
            let now = Date()
            self.processActivity(block_act, at: now)
            self.lastActivity = (kind: block_act, date: now)
        }

        let activites_end: [CFRunLoopActivity] = [.beforeWaiting, .exit]
        observer_end = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault,
            CFRunLoopActivity(activites_end).rawValue,
            true,
            CFIndex.max
        ) { block_obs, block_act in
            self.processActivity(block_act, at: Date())
            self.lastActivity = nil
        }

        start()
    }

    deinit {
        CFRunLoopRemoveObserver(RunLoop.main.getCFRunLoop(), observer_begin, .commonModes)
        CFRunLoopRemoveObserver(RunLoop.main.getCFRunLoop(), observer_end, .commonModes)
    }

    private func start() {
        CFRunLoopAddObserver(RunLoop.main.getCFRunLoop(), observer_begin, .commonModes)
        CFRunLoopAddObserver(RunLoop.main.getCFRunLoop(), observer_end, .commonModes)
    }

    /// `VitalRefreshRateReader` keeps pushing data to its `observers` at every new frame.
    /// - Parameter observer: receiver of refresh rate per frame.
    func register(_ valuePublisher: VitalPublisher) {
        DispatchQueue.main.async {
            self.valuePublishers.append(valuePublisher)
        }
    }

    /// `VitalRefreshRateReader` stops pushing data to `observer` once unregistered.
    /// - Parameter observer: already added observer; otherwise nothing happens.
    func unregister(_ valuePublisher: VitalPublisher) {
        DispatchQueue.main.async {
            self.valuePublishers.removeAll { existingPublisher in
                return existingPublisher === valuePublisher
            }
        }
    }

    private func processActivity(_ activity: CFRunLoopActivity, at date: Date) {
        if let last = self.lastActivity,
           date.timeIntervalSince(last.date) > Self.longTaskDurationThreshold {
            print("\(last.kind.description) took \(date.timeIntervalSince(last.date) * 1_000)ms")

            for publisher in valuePublishers {
                publisher.mutateAsync { currentInfo in
                    currentInfo.addSample(1)
                }
            }
        }
    }
}

private extension CFRunLoopActivity {
    var description: String {
        switch self {
        case .afterWaiting: return "afterWaiting"
        case .allActivities: return "allActivities"
        case .beforeSources: return "beforeSources"
        case .beforeTimers: return "beforeTimers"
        case .beforeWaiting: return "beforeWaiting"
        case .entry: return "entry"
        case .exit: return "exit"
        default: return String(describing: self)
        }
    }
}
