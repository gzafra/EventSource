//
//  EventSourceTests.swift
//  EventSourceTests
//
//  Created by Andres on 2/13/15.
//  Copyright (c) 2015 Inaka. All rights reserved.
//

import UIKit
import XCTest
@testable import EventSource

class SplittedEvents: XCTestCase {

    var sut: TestableEventSource!

	override func setUp() {
		sut = TestableEventSource(url: "http://test.com", headers: ["Authorization" : "basic auth"])
		super.setUp()
	}

	func testEventDataIsRemovedFromBufferWhenProcessed() {
		let expectation = self.expectationWithDescription("onMessage should be called")
		let eventData = "id: event-id\ndata:event-data\n\n".dataUsingEncoding(NSUTF8StringEncoding)
		sut.onMessage { (id, event, data) in
			expectation.fulfill()
		}

		sut.callDidReceiveResponse()
		sut.callDidReceiveData(eventData!)
		self.waitForExpectationsWithTimeout(2) { (error) in
			if let _ = error {
				XCTFail("Expectation not fulfilled")
			}
		}
		XCTAssertEqual(sut!.receivedDataBuffer.length, 0)
	}

	func testEventDataSplitOverMultiplePackets() {
		let expectation = self.expectationWithDescription("onMessage should be called")

		let dataPacket1 = "id: event-id\nda".dataUsingEncoding(NSUTF8StringEncoding)
		let dataPacket2 = "ta:event-data\n\n".dataUsingEncoding(NSUTF8StringEncoding)
		sut.onMessage { (id, event, data) in
			XCTAssertEqual(event!, "message", "the event should be message")
			XCTAssertEqual(id!, "event-id", "the event id should be received")
			XCTAssertEqual(data!, "event-data", "the event data should be received")

			expectation.fulfill()
		}

		sut.callDidReceiveResponse()
		sut.callDidReceiveData(dataPacket1!)
		sut.callDidReceiveData(dataPacket2!)

		self.waitForExpectationsWithTimeout(2) { (error) in
			if let _ = error {
				XCTFail("Expectation not fulfilled")
			}
		}
	}
}
