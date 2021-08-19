/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-2020 Datadog, Inc.
 */

import XCTest
import UIKit
@testable import Datadog

// NOTE: RUMM-1086 the case of multiple long task doesn't produce reliable results.
// Sleeping the thread 5 times may result in 1 or more long tasks.
// This case is not tested in order not to add flakiness to the tests.
class VitalLongTaskReaderTests: XCTestCase {
    func testLongTasks() {
        let reader = VitalLongTaskReader()
        let registrar_view = VitalPublisher(initialValue: VitalInfo())

        // This view has long tasks
        reader.register(registrar_view)

        // Block UI thread
        Thread.sleep(forTimeInterval: 0.5)

        // Wait after blocking UI thread so that reader will read long tasks before assertions
        let expectation2 = expectation(description: "async expectation for the observer")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            expectation2.fulfill()
        }
        waitForExpectations(timeout: 1.0) { _ in }

        XCTAssertEqual(registrar_view.currentValue.sampleCount, 1)
    }
}
