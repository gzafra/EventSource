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
    case connecting
    case open
    case closed
}

private enum EventSourceKeys: String {
    case id = "id"
    case eventName = "event"
    case eventData = "data"
    
    var key: String {
        return self.rawValue
    }
}

open class EventSource: NSObject, URLSessionDataDelegate {
    static let DefaultsKey = "com.inaka.eventSource.lastEventId"
    fileprivate static let DefaultEventName = "message"
    
    //MARK: Properties
    let url: URL
    fileprivate let lastEventIDKey: String
    fileprivate let receivedString: NSString?
    fileprivate var onOpenCallback: ((Void) -> Void)?
    fileprivate var onErrorCallback: ((Error?) -> Void)?
    
    typealias EventBody = (id: String?, eventName: String?, data: String?)
    fileprivate var onMessageCallback: ((EventBody) -> Void)?
    
    open internal(set) var readyState: EventSourceState
    open fileprivate(set) var retryTime = 3000
    fileprivate var eventListeners = Dictionary<String, (EventBody) -> Void>()
    fileprivate var headers: Dictionary<String, String>
    internal var urlSession: Foundation.URLSession?
    internal var task: URLSessionDataTask?
    fileprivate var errorBeforeSetErrorCallBack: Error?
    internal let receivedDataBuffer: NSMutableData
    fileprivate let uniqueIdentifier: String
    open var queue = DispatchQueue.main
    
    internal var lastEventID: String? {
        set {
            if let lastEventID = newValue {
                let defaults = UserDefaults.standard
                defaults.set(lastEventID, forKey: lastEventIDKey)
                defaults.synchronize()
            }
        }
        
        get {
            if let lastEventID = UserDefaults.standard.string(forKey: lastEventIDKey) {
                return lastEventID
            }
            return nil
        }
    }
    
    //MARK: Lifecycle
    internal var events : [String] {
        get {
            return Array(self.eventListeners.keys)
        }
    }
    
    public init(url: String, headers: [String : String] = [:]) {
        self.url = URL(string: url)!
        self.headers = headers
        self.readyState = EventSourceState.closed
        self.receivedString = nil
        self.receivedDataBuffer = NSMutableData()
        
        let port = (self.url as NSURL).port?.stringValue ?? ""
        let relativePath = self.url.relativePath
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
        
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = TimeInterval(INT_MAX)
        configuration.timeoutIntervalForResource = TimeInterval(INT_MAX)
        configuration.httpAdditionalHeaders = additionalHeaders
        
        self.readyState = EventSourceState.connecting
        self.urlSession = newSession(configuration)
        self.task = urlSession!.dataTask(with: self.url)
        
        self.resumeSession()
    }
    
    internal func resumeSession() {
        self.task!.resume()
    }
    
    internal func newSession(_ configuration: URLSessionConfiguration) -> Foundation.URLSession {
        return Foundation.URLSession(configuration: configuration,
                                     delegate: self,
                                     delegateQueue: OperationQueue())
    }
    
    open func close() {
        self.readyState = EventSourceState.closed
        self.urlSession?.invalidateAndCancel()
    }
    
    /// Checks whether the server sents a close request, specified by a 204 http according to w3c
    fileprivate func receivedMessageToClose(_ httpResponse: HTTPURLResponse?) -> Bool {
        guard let response = httpResponse  else {
            return false
        }
        
        if response.statusCode == 204 {
            self.close()
            return true
        }
        return false
    }
    
    //MARK: Events
    
    open func onOpen(_ onOpenCallback: @escaping (Void) -> Void) {
        self.onOpenCallback = onOpenCallback
    }
    
    open func onError(_ onErrorCallback: @escaping (Error?) -> Void) {
        self.onErrorCallback = onErrorCallback
        
        if let errorBeforeSet = self.errorBeforeSetErrorCallBack {
            self.onErrorCallback!(errorBeforeSet)
            self.errorBeforeSetErrorCallBack = nil
        }
    }
    
    open func onMessage(_ onMessageCallback: @escaping (_ id: String?, _ event: String?, _ data: String?) -> Void) {
        self.onMessageCallback = onMessageCallback
    }
    
    open func addEventListener(_ event: String, handler: @escaping (_ id: String?, _ event: String?, _ data: String?) -> Void) {
        self.eventListeners[event] = handler
    }
    
    open func removeEventListener(_ event: String) -> Void {
        self.eventListeners.removeValue(forKey: event)
    }
    
    //MARK: NSURLSessionDataDelegate
    
    open func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if self.receivedMessageToClose(dataTask.response as? HTTPURLResponse) {
            return
        }
        
        if self.readyState != EventSourceState.open {
            return
        }
        
        self.receivedDataBuffer.append(data)
        let eventStream = extractEventsFromBuffer()
        self.parseEventStream(eventStream)
    }
    
    open func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: (@escaping (Foundation.URLSession.ResponseDisposition) -> Void)) {
        completionHandler(Foundation.URLSession.ResponseDisposition.allow)
        if self.receivedMessageToClose(dataTask.response as? HTTPURLResponse) {
            return
        }
        self.readyState = EventSourceState.open
        if self.onOpenCallback != nil {
            queue.async {
                self.onOpenCallback!()
            }
        }
    }
    
    open func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        self.readyState = EventSourceState.closed
        
        if self.receivedMessageToClose(task.response as? HTTPURLResponse) {
            return
        }
        
        if error == nil || (error as NSError!).code != -999 {
            let nanoseconds = Double(self.retryTime) / 1000.0 * Double(NSEC_PER_SEC)
            let delayTime = DispatchTime.now() + Double(Int64(nanoseconds)) / Double(NSEC_PER_SEC)
            queue.asyncAfter(deadline: delayTime) {
                self.connect()
            }
        }
        
        queue.async {
            if let errorCallback = self.onErrorCallback {
                errorCallback(error)
            } else {
                self.errorBeforeSetErrorCallBack = error
            }
        }
    }
    
    //MARK: Helpers
    
    /// Extracts 1 line of data from the buffer as SSE data streams are separated by a pair of \n (CRLF) according to w3c
    fileprivate func extractEventsFromBuffer() -> [String] {
        let delimiter = "\n\n".data(using: String.Encoding.utf8)!
        var events = [String]()
        
        // Find first occurrence of delimiter
        var searchRange =  NSRange(location: 0, length: receivedDataBuffer.length)
        var foundRange = receivedDataBuffer.range(of: delimiter, options: NSData.SearchOptions(), in: searchRange)
        while foundRange.location != NSNotFound {
            // Append event
            if foundRange.location > searchRange.location {
                let dataChunk = receivedDataBuffer.subdata(
                    with: NSRange(location: searchRange.location, length: foundRange.location - searchRange.location)
                )
                events.append(NSString(data: dataChunk, encoding: String.Encoding.utf8.rawValue) as! String)
            }
            // Search for next occurrence of delimiter
            searchRange.location = foundRange.location + foundRange.length
            searchRange.length = receivedDataBuffer.length - searchRange.location
            foundRange = receivedDataBuffer.range(of: delimiter, options: NSData.SearchOptions(), in: searchRange)
        }
        
        // Remove the found events from the buffer
        self.receivedDataBuffer.replaceBytes(in: NSRange(location: 0, length: searchRange.location), withBytes: nil, length: 0)
        
        return events
    }
    
    /// Parses raw data from the event stream and dispatches it according to w3c specs
    fileprivate func parseEventStream(_ events: [String]) {
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
            if (event as NSString).contains("retry:") {
                if let reconnectTime = parseRetryTimeFrom(event: event) {
                    self.retryTime = reconnectTime
                }
                continue
            }
            
            parsedEvents.append(parse(event: event))
        }
        
        // Dispatch previously parsed events
        for parsedEvent in parsedEvents {
            self.lastEventID = parsedEvent.id
            
            // Standard messages need no name, so we we just name it according to specs
            if parsedEvent.eventName == nil {
                if let data = parsedEvent.data, let onMessage = self.onMessageCallback {
                    queue.async {
                        let message: EventBody = (id: self.lastEventID, eventName: EventSource.DefaultEventName, data: data)
                        onMessage(message)
                    }
                }
            }
            
            // Messages with an event name will call the event handlers specified at setup
            if let event = parsedEvent.eventName, let data = parsedEvent.data, let eventHandler = self.eventListeners[event] {
                queue.async {
                    let message: EventBody = (id: self.lastEventID, eventName: event, data: data)
                    eventHandler(message)
                }
            }
        }
    }
    
    /// Creates a dictionary with id, event, data off the raw data string
    fileprivate func parse(event eventString: String) -> EventBody {
        var eventDictionary = Dictionary<String, String>()
        
        for line in eventString.components(separatedBy: CharacterSet.newlines) as [String] {
            autoreleasepool {
                var key: NSString?, value: NSString?
                let scanner = Scanner(string: line)
                scanner.scanUpTo(":", into: &key)
                scanner.scanString(":", into: nil)
                scanner.scanUpTo("\n", into: &value)
                
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
        
        return (eventDictionary[EventSourceKeys.id.key],
                eventDictionary[EventSourceKeys.eventName.key],
                eventDictionary[EventSourceKeys.eventData.key])
    }
    
    /// Reads the retry time included in the event stream
    fileprivate func parseRetryTimeFrom(event eventString: String) -> Int? {
        var reconnectTime: Int?
        let separators = CharacterSet(charactersIn: ":")
        if let milli = eventString.components(separatedBy: separators).last {
            let milliseconds = milli.trimmed
            
            if let intMiliseconds = Int(milliseconds) {
                reconnectTime = intMiliseconds
            }
        }
        return reconnectTime
    }
    
    class open func basicAuthFor(_ username: String, password: String) -> String {
        let authString = "\(username):\(password)"
        let authData = authString.data(using: String.Encoding.utf8)
        let base64String = authData!.base64EncodedString(options: [])
        
        return "Basic \(base64String)"
    }
}

private extension String {
    /// Trims all white space characters from the beginning and end of a string.
    var trimmed : String {
        return self.trimmingCharacters(in: CharacterSet.whitespaces);
    }
}
