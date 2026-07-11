import Foundation

/// Thin `dlopen`/`dlsym` wrapper over the private IOReport framework — the same
/// energy-model and P-state residency channels `powermetrics`/asitop read. It's
/// loaded lazily and fails soft: if the library or any symbol is missing the
/// whole bridge is `nil`, so callers simply get no data instead of crashing.
final class IOReportBridge {
    static let shared = IOReportBridge()

    // C function-pointer shapes (reverse-engineered; stable for years).
    private typealias CopyChannelsInGroup = @convention(c)
        (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
    private typealias CreateSubscription = @convention(c)
        (UnsafeMutableRawPointer?, CFMutableDictionary,
         UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>, UInt64, CFTypeRef?) -> Unmanaged<AnyObject>?
    private typealias CreateSamples = @convention(c)
        (AnyObject, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias CreateSamplesDelta = @convention(c)
        (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias IterateFn = @convention(c)
        (CFDictionary, @convention(block) (CFDictionary) -> Int32) -> Void
    private typealias ChannelGetString = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias ChannelGetFormat = @convention(c) (CFDictionary) -> Int32
    private typealias SimpleGetInteger = @convention(c) (CFDictionary, Int32) -> Int64
    private typealias StateGetCount = @convention(c) (CFDictionary) -> Int32
    private typealias StateGetNameForIndex = @convention(c) (CFDictionary, Int32) -> Unmanaged<CFString>?
    private typealias StateGetResidency = @convention(c) (CFDictionary, Int32) -> Int64

    private let copyChannelsFn: CopyChannelsInGroup
    private let createSubscriptionFn: CreateSubscription
    private let createSamplesFn: CreateSamples
    private let createDeltaFn: CreateSamplesDelta
    private let iterateFn: IterateFn
    private let getChannelNameFn: ChannelGetString
    private let getUnitLabelFn: ChannelGetString
    private let getFormatFn: ChannelGetFormat
    private let simpleIntegerFn: SimpleGetInteger
    private let stateCountFn: StateGetCount
    private let stateNameFn: StateGetNameForIndex
    private let stateResidencyFn: StateGetResidency

    /// IOReport channel formats (from IOReportChannelGetFormat).
    static let formatSimple: Int32 = 1
    static let formatState: Int32 = 2

    private init?() {
        guard let handle = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW)
                ?? dlopen("/System/Library/PrivateFrameworks/IOReport.framework/IOReport", RTLD_NOW) else {
            return nil
        }
        func load<T>(_ name: String, as type: T.Type) -> T? {
            guard let sym = dlsym(handle, name) else { return nil }
            return unsafeBitCast(sym, to: T.self)
        }
        guard let copy = load("IOReportCopyChannelsInGroup", as: CopyChannelsInGroup.self),
              let sub = load("IOReportCreateSubscription", as: CreateSubscription.self),
              let samples = load("IOReportCreateSamples", as: CreateSamples.self),
              let delta = load("IOReportCreateSamplesDelta", as: CreateSamplesDelta.self),
              let iterate = load("IOReportIterate", as: IterateFn.self),
              let name = load("IOReportChannelGetChannelName", as: ChannelGetString.self),
              let unit = load("IOReportChannelGetUnitLabel", as: ChannelGetString.self),
              let format = load("IOReportChannelGetFormat", as: ChannelGetFormat.self),
              let simple = load("IOReportSimpleGetIntegerValue", as: SimpleGetInteger.self),
              let stCount = load("IOReportStateGetCount", as: StateGetCount.self),
              let stName = load("IOReportStateGetNameForIndex", as: StateGetNameForIndex.self),
              let stRes = load("IOReportStateGetResidency", as: StateGetResidency.self) else {
            return nil
        }
        copyChannelsFn = copy
        createSubscriptionFn = sub
        createSamplesFn = samples
        createDeltaFn = delta
        iterateFn = iterate
        getChannelNameFn = name
        getUnitLabelFn = unit
        getFormatFn = format
        simpleIntegerFn = simple
        stateCountFn = stCount
        stateNameFn = stName
        stateResidencyFn = stRes
    }

    // MARK: - Channel accessors (each takes one channel dict from `iterate`)

    func channelName(_ channel: CFDictionary) -> String {
        (getChannelNameFn(channel)?.takeUnretainedValue() as String?) ?? ""
    }
    func unitLabel(_ channel: CFDictionary) -> String {
        (getUnitLabelFn(channel)?.takeUnretainedValue() as String?) ?? ""
    }
    func format(_ channel: CFDictionary) -> Int32 { getFormatFn(channel) }
    func simpleValue(_ channel: CFDictionary) -> Int64 { simpleIntegerFn(channel, 0) }
    func stateCount(_ channel: CFDictionary) -> Int { Int(stateCountFn(channel)) }
    func stateName(_ channel: CFDictionary, _ index: Int) -> String {
        (stateNameFn(channel, Int32(index))?.takeUnretainedValue() as String?) ?? ""
    }
    func stateResidency(_ channel: CFDictionary, _ index: Int) -> Int64 {
        stateResidencyFn(channel, Int32(index))
    }

    /// Walks each channel in a delta sample.
    func forEachChannel(in delta: CFDictionary, _ body: @escaping (CFDictionary) -> Void) {
        iterateFn(delta) { channel in body(channel); return 0 }
    }

    // MARK: - Subscription factory

    /// Opens a live subscription to one group (optionally one subgroup). Returns
    /// `nil` if the group has no channels or the subscription can't be created.
    func makeSubscription(group: String, subgroup: String? = nil) -> IOReportSubscription? {
        guard let channels = copyChannelsFn(group as CFString, subgroup as CFString?, 0, 0, 0)?
            .takeRetainedValue() else { return nil }
        var subbed: Unmanaged<CFMutableDictionary>? = nil
        guard let subscription = createSubscriptionFn(nil, channels, &subbed, 0, nil)?.takeRetainedValue(),
              let subbedChannels = subbed?.takeRetainedValue() else { return nil }
        return IOReportSubscription(bridge: self, subscription: subscription, channels: subbedChannels)
    }

    fileprivate func sample(_ subscription: AnyObject, _ channels: CFMutableDictionary) -> CFDictionary? {
        createSamplesFn(subscription, channels, nil)?.takeRetainedValue()
    }
    fileprivate func delta(_ previous: CFDictionary, _ current: CFDictionary) -> CFDictionary? {
        createDeltaFn(previous, current, nil)?.takeRetainedValue()
    }
}

/// A live IOReport subscription that yields per-interval deltas. Drive it from a
/// single queue (the sampler queue); it holds the previous raw sample so each
/// `nextDelta()` covers the time since the last call.
final class IOReportSubscription {
    private let bridge: IOReportBridge
    private let subscription: AnyObject
    private let channels: CFMutableDictionary
    private var previous: CFDictionary?

    fileprivate init(bridge: IOReportBridge, subscription: AnyObject, channels: CFMutableDictionary) {
        self.bridge = bridge
        self.subscription = subscription
        self.channels = channels
    }

    /// Samples now and returns the delta since the previous call. The first call
    /// only primes the baseline and returns `nil`.
    func nextDelta() -> CFDictionary? {
        guard let current = bridge.sample(subscription, channels) else { return nil }
        defer { previous = current }
        guard let previous else { return nil }
        return bridge.delta(previous, current)
    }
}
