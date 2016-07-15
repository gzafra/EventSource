//
//  EventSource.swift
//  EventSource
//
//  Created by Andres on 2/13/15.
//  Copyright (c) 2015 Inaka. All rights reserved.
//


/**
  Check: https://www.w3.org/TR/2012/WD-eventsource-20120426/#parsing-an-event-stream
 */

import Foundation

public enum EventSourceState {
    case Connecting
    case Open
    case Closed
}

public class EventSource: NSObject, NSURLSessionDataDelegate {
	static let DefaultsKey = "com.inaka.eventSource.lastEventId"
private enum EventSourceKeys: String {
    case Id = "id"
    case EventName = "event"
    case EventData = "data"
    
    func key() -> String {
        return self.rawValue
    }
}

    private static let DefaultEventName = "message"
    
    //MARK: Properties
    let url: NSURL
	private let lastEventIDKey: String
    private let receivedString: NSString?
    private var onOpenCallback: (Void -> Void)?
    private var onErrorCallback: (NSError? -> Void)?
    
    typealias EventBody = (id: String?, eventName: String?, data: String?)
    private var onMessageCallback: (EventBody -> Void)?
    
    public internal(set) var readyState: EventSourceState
    public private(set) var retryTime = 3000
    private var eventListeners = Dictionary<String, EventBody -> Void>()
    private var headers: Dictionary<String, String>
    internal var urlSession: NSURLSession?
    internal var task: NSURLSessionDataTask?
    private var operationQueue: NSOperationQueue
    private var errorBeforeSetErrorCallBack: NSError?
    internal let receivedDataBuffer: NSMutableData
	private let uniqueIdentifier: String
    public var queue = dispatch_get_main_queue()

    internal var lastEventID: String? {
        set {
            if let lastEventID = newValue {
                let defaults = NSUserDefaults.standardUserDefaults()
                defaults.setObject(lastEventID, forKey: lastEventIDKey)
                defaults.synchronize()
            }
        }
        
        get {
            if let lastEventID = NSUserDefaults.standardUserDefaults().stringForKey(lastEventIDKey) {
                return lastEventID
            }
            return nil
        }
    }
    
    internal var events : [String] {
        get {
            return Array(self.eventListeners.keys)
        }
    }
    
    //MARK: Lifecycle

    public init(url: String, headers: [String : String] = [:]) {
        self.url = NSURL(string: url)!
        self.headers = headers
        self.readyState = EventSourceState.Closed
        self.operationQueue = NSOperationQueue()
        self.receivedString = nil
        self.receivedDataBuffer = NSMutableData()


		let port = self.url.port?.stringValue ?? ""
		let relativePath = self.url.relativePath ?? ""
		let host = self.url.host ?? ""

		self.uniqueIdentifier = "\(self.url.scheme).\(host).\(port).\(relativePath)"
		self.lastEventIDKey = "\(EventSource.DefaultsKey).\(self.uniqueIdentifier)"

        super.init()
    }
    
    //MARK: Connection
    
    func connect() {
        var additionalHeaders = self.headers
        if let eventID = self.lastEventID {
            additionalHeaders["Last-Event-Id"] = eventID
        }

        additionalHeaders["Accept"] = "text/event-stream"
        additionalHeaders["Cache-Control"] = "no-cache"

        let configuration = NSURLSessionConfiguration.defaultSessionConfiguration()
        configuration.timeoutIntervalForRequest = NSTimeInterval(INT_MAX)
        configuration.timeoutIntervalForResource = NSTimeInterval(INT_MAX)
        configuration.HTTPAdditionalHeaders = additionalHeaders

        self.readyState = EventSourceState.Connecting
        self.urlSession = newSession(configuration)
        self.task = urlSession!.dataTaskWithURL(self.url)

		self.resumeSession()
    }

	internal func resumeSession() {
		self.task!.resume()
	}

    internal func newSession(configuration: NSURLSessionConfiguration) -> NSURLSession {
        return NSURLSession(configuration: configuration,
								 delegate: self,
						    delegateQueue: operationQueue)
    }
    
    public func close() {
        self.readyState = EventSourceState.Closed
        self.urlSession?.invalidateAndCancel()
    }

    /// Checks whether the server sents a close request, specified by a 204 http according to w3c
	private func receivedMessageToClose(httpResponse: NSHTTPURLResponse?) -> Bool {
		guard let response = httpResponse  else {
			return false
		}

		if response.statusCode == 204 {
			self.close()
			return true
		}
		return false
	}

    //MARK: EventListeners

    public func onOpen(onOpenCallback: Void -> Void) {
        self.onOpenCallback = onOpenCallback
    }

    public func onError(onErrorCallback: NSError? -> Void) {
        self.onErrorCallback = onErrorCallback

        if let errorBeforeSet = self.errorBeforeSetErrorCallBack {
            self.onErrorCallback!(errorBeforeSet)
            self.errorBeforeSetErrorCallBack = nil
        }
    }

    public func onMessage(onMessageCallback: (id: String?, event: String?, data: String?) -> Void) {
        self.onMessageCallback = onMessageCallback
    }

    public func addEventListener(event: String, handler: (id: String?, event: String?, data: String?) -> Void) {
        self.eventListeners[event] = handler
    }

	public func removeEventListener(event: String) -> Void {
		self.eventListeners.removeValueForKey(event)
	}
    
    //MARK: NSURLSessionDataDelegate

    public func URLSession(session: NSURLSession, dataTask: NSURLSessionDataTask, didReceiveData data: NSData) {
		if self.receivedMessageToClose(dataTask.response as? NSHTTPURLResponse) {
			return
		}

		if self.readyState != EventSourceState.Open {
            return
        }

        self.receivedDataBuffer.appendData(data)
        let eventStream = extractEventsFromBuffer()
        self.parseEventStream(eventStream)
    }

    public func URLSession(session: NSURLSession, dataTask: NSURLSessionDataTask, didReceiveResponse response: NSURLResponse, completionHandler: ((NSURLSessionResponseDisposition) -> Void)) {
        completionHandler(NSURLSessionResponseDisposition.Allow)

		if self.receivedMessageToClose(dataTask.response as? NSHTTPURLResponse) {
			return
		}

        self.readyState = EventSourceState.Open
        if self.onOpenCallback != nil {
            dispatch_async(queue) {
                self.onOpenCallback!()
            }
        }
    }

    public func URLSession(session: NSURLSession, task: NSURLSessionTask, didCompleteWithError error: NSError?) {
        self.readyState = EventSourceState.Closed

		if self.receivedMessageToClose(task.response as? NSHTTPURLResponse) {
			return
		}

        if error == nil || error!.code != -999 {
            let nanoseconds = Double(self.retryTime) / 1000.0 * Double(NSEC_PER_SEC)
            let delayTime = dispatch_time(DISPATCH_TIME_NOW, Int64(nanoseconds))
            dispatch_after(delayTime, queue) {
                self.connect()
            }
        }
        
        guard let dispatch_queue_t = queue else {
            return
        }
        dispatch_async(dispatch_queue_t) {
            if let errorCallback = self.onErrorCallback {
                errorCallback(error)
            } else {
                self.errorBeforeSetErrorCallBack = error
            }
        }
    }
    
    //MARK: Helpers
    
    /// Extracts 1 line of data from the buffer as SSE data streams are separated by a pair of \n (CRLF) according to w3c
    private func extractEventsFromBuffer() -> [String] {
        let delimiter = "\n\n".dataUsingEncoding(NSUTF8StringEncoding)!
        var events = [String]()

        // Find first occurrence of delimiter
        var searchRange =  NSRange(location: 0, length: receivedDataBuffer.length)
        var foundRange = receivedDataBuffer.rangeOfData(delimiter, options: NSDataSearchOptions(), range: searchRange)
        while foundRange.location != NSNotFound {
            // Append event
            if foundRange.location > searchRange.location {
                let dataChunk = receivedDataBuffer.subdataWithRange(
                    NSRange(location: searchRange.location, length: foundRange.location - searchRange.location)
                )
                events.append(NSString(data: dataChunk, encoding: NSUTF8StringEncoding) as! String)
            }
            // Search for next occurrence of delimiter
            searchRange.location = foundRange.location + foundRange.length
            searchRange.length = receivedDataBuffer.length - searchRange.location
            foundRange = receivedDataBuffer.rangeOfData(delimiter, options: NSDataSearchOptions(), range: searchRange)
        }

        // Remove the found events from the buffer
        self.receivedDataBuffer.replaceBytesInRange(NSRange(location: 0, length: searchRange.location), withBytes: nil, length: 0)

        return events
    }
    
    /// Parses raw data from the event stream and dispatches it according to w3c specs
    private func parseEventStream(events: [String]) {
        var parsedEvents: [EventBody] = Array()
        
        
        // Parse raw events, discarding invalid data
        for event in events {
            // Empty events are ignored according to spec
            if event.isEmpty {
                continue
            }
            
            // Line start with : should be ignored according to specs
            if event.hasPrefix(":") {
                continue
            }
            
            // "retry" keyword prefixing : updates the retry time used to reconnect after connection closes
            if (event as NSString).containsString("retry:") {
                if let reconnectTime = parseRetryTime(event) {
                    self.retryTime = reconnectTime
                }
                continue
            }
            
            parsedEvents.append(parseEvent(event))
        }
        
        // Dispatch previously parsed events
        for parsedEvent in parsedEvents {
            self.lastEventID = parsedEvent.id
            
            // Standard messages need no name, so we we just name it according to specs
            if parsedEvent.eventName == nil {
                if let data = parsedEvent.data, onMessage = self.onMessageCallback {
                    dispatch_async(queue) {
                        let message: EventBody = (id: self.lastEventID, eventName: EventSource.DefaultEventName, data: data)
                        onMessage(message)
                    }
                }
            }
            
            // Messages with an event name will call the event handlers specified at setup
            if let event = parsedEvent.eventName, data = parsedEvent.data, eventHandler = self.eventListeners[event] {
                dispatch_async(queue) {
                    let message: EventBody = (id: self.lastEventID, eventName: event, data: data)
                    eventHandler(message)
                }
            }
        }
    }
    
    /// Creates a dictionary with id, event, data off the raw data string
    private func parseEvent(eventString: String) -> EventBody {
        var eventDictionary = Dictionary<String, String>()
        
        for line in eventString.componentsSeparatedByCharactersInSet(NSCharacterSet.newlineCharacterSet()) as [String] {
            autoreleasepool {
                var key: NSString?, value: NSString?
                let scanner = NSScanner(string: line)
                scanner.scanUpToString(":", intoString: &key)
                scanner.scanString(":", intoString: nil)
                scanner.scanUpToString("\n", intoString: &value)
                
                if key != nil && value != nil {
                    if eventDictionary[key as! String] != nil {
                        eventDictionary[key as! String] = "\(eventDictionary[key as! String]!)\n\(value!)"
                    } else {
                        eventDictionary[key as! String] = value! as String
                    }
                } else if key != nil && value == nil {
                    eventDictionary[key as! String] = ""
                }
            }
        }
        
        return (eventDictionary[EventSourceKeys.Id.key()],
                eventDictionary[EventSourceKeys.EventName.key()],
                eventDictionary[EventSourceKeys.EventData.key()])
    }
    
    /// Reads the retry time included in the event stream
    private func parseRetryTime(eventString: String) -> Int? {
        var reconnectTime: Int?
        let separators = NSCharacterSet(charactersInString: ":")
        if let milli = eventString.componentsSeparatedByCharactersInSet(separators).last {
            let milliseconds = milli.trimmed
            
            if let intMiliseconds = Int(milliseconds) {
                reconnectTime = intMiliseconds
            }
        }
        return reconnectTime
    }
    
    class public func basicAuth(username: String, password: String) -> String {
        let authString = "\(username):\(password)"
        let authData = authString.dataUsingEncoding(NSUTF8StringEncoding)
        let base64String = authData!.base64EncodedStringWithOptions([])

        return "Basic \(base64String)"
    }
}

private extension String {
    /// Trims all white space characters from the beginning and end of a string.
    var trimmed : String {
        return self.stringByTrimmingCharactersInSet(NSCharacterSet.whitespaceCharacterSet());
    }
}
