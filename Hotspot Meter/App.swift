//
//  Hotspot_MeterApp.swift
//  Hotspot Meter
//
//  Created by Mr Violets on 23/11/2023.
//

import SwiftUI
import SystemConfiguration
import Network
import ServiceManagement

public enum Keys {
    static let displayMode = "displayMode"
    static let counterType = "counterType"
    static let allTimeDataRecord = "allTimeDataRecord"
}

enum CounterType: String {
    case session
    case accumulative
}

enum DisplayMode: String {
    case combined
    case split
    case sent
    case received
}

@main
struct MenuBar: App {
    @StateObject private var menuHandler = MenuHandler()
    
    var body: some Scene {
        MenuBarExtra {
            
            Menu("Counter") {
                Picker("Type", selection: $menuHandler.currentType) {
                    Text("Session").tag(CounterType.session)
                    Text("Accumulative").tag(CounterType.accumulative)
                }
                .pickerStyle(InlinePickerStyle())
                
                Picker("Display", selection: $menuHandler.currentDisplayMode) {
                    Text("Combined").tag(DisplayMode.combined)
                    Text("Split").tag(DisplayMode.split)
                    Text("Sent").tag(DisplayMode.sent)
                    Text("Received").tag(DisplayMode.received)
                }
                .pickerStyle(InlinePickerStyle())
            }
            
            Button("Reset Counters") {
                menuHandler.resetDataUsageCounters()
                menuHandler.resetAllTimeData()
            }.keyboardShortcut("r")
            
            Divider()
            
            Toggle("Launch at Login", isOn: $menuHandler.isRunAtStartupEnabled)
            
            Divider()
            
            Button("Quit") {
                NSApp.terminate(self)
            }.keyboardShortcut("q")
        } label: {
            Group {
                if menuHandler.currentType == .session {
                    switch menuHandler.currentDisplayMode {
                    case .combined:
                        HStack {
                            Image(systemName: "arrow.up.arrow.down")
                            if menuHandler.isActive {
                                Text(menuHandler.currentData.total.formattedDataString())
                            }
                        }
                        
                    case .split:
                        HStack {
                            if !menuHandler.isActive {
                                Image(systemName: "arrow.up.arrow.down")
                            } else {
                                Text("↑ \(menuHandler.currentData.sent.formattedDataString()) ↓ \(menuHandler.currentData.received.formattedDataString())")
                            }
                        }
                        
                    case .sent:
                        HStack {
                            Image(systemName: "arrow.up")
                            if menuHandler.isActive {
                                Text(menuHandler.currentData.sent.formattedDataString())
                            }
                        }
                        
                    case .received:
                        HStack {
                            Image(systemName: "arrow.down")
                            if menuHandler.isActive {
                                Text(menuHandler.currentData.received.formattedDataString())
                            }
                        }
                    }
                } else if menuHandler.currentType == .accumulative {
                    switch menuHandler.currentDisplayMode {
                    case .combined:
                        HStack {
                            Image(systemName: "arrow.up.arrow.down")
                            if menuHandler.allTimeData.total > 0 {
                                Text(menuHandler.allTimeData.total.formattedDataString())
                            }
                        }
                        
                    case .split:
                        HStack {
                            if menuHandler.allTimeData.total == 0 {
                                Image(systemName: "arrow.up.arrow.down")
                            } else {
                                Text("↑ \(menuHandler.allTimeData.sent.formattedDataString()) ↓ \(menuHandler.allTimeData.received.formattedDataString())")
                            }
                        }
                        
                    case .sent:
                        HStack {
                            Image(systemName: "arrow.up")
                            if menuHandler.allTimeData.sent > 0 {
                                Text(menuHandler.allTimeData.sent.formattedDataString())
                            }
                        }
                        
                    case .received:
                        HStack {
                            Image(systemName: "arrow.down")
                            if menuHandler.allTimeData.received > 0 {
                                Text(menuHandler.allTimeData.received.formattedDataString())
                            }
                        }
                    }
                }
            }
        }
    }
}

struct DataUsageInfo {
    var wifiReceived: UInt64 = 0
    var wifiSent: UInt64 = 0
    
    mutating func updateInfoByAdding(_ info: DataUsageInfo) {
        wifiSent += info.wifiSent
        wifiReceived += info.wifiReceived
    }
    
    var wifiComplete: UInt64 {
        return wifiSent + wifiReceived
    }
}

struct DataStruct: Codable {
    var sent: UInt64
    var received: UInt64
    var total: UInt64
}

class MenuHandler: NSObject, ObservableObject {
    enum NetworkState {
        case expensive, cheap
    }
    
    @Published var allTimeData = DataStruct(sent: 0, received: 0, total: 0)
    @Published var currentData = DataStruct(sent: 0, received: 0, total: 0)
    
    private var lastDataUsage = DataUsageInfo()
    private var dataPollingTimer: Timer?
    private var lastExpensiveDetectionTime: Date?
    
    @Published var isActive: Bool = false
    @Published var currentType: CounterType {
        didSet {
            UserDefaults.standard.set(currentType.rawValue, forKey: Keys.counterType)
        }
    }
    
    @Published var currentDisplayMode: DisplayMode {
        didSet {
            UserDefaults.standard.set(currentDisplayMode.rawValue, forKey: Keys.displayMode)
        }
    }
    
    @Published var isRunAtStartupEnabled: Bool {
        didSet {
            updateRunAtStartupPreference()
        }
    }
    
    func updateRunAtStartupPreference() {
        do {
            if isRunAtStartupEnabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("Error while updating run at startup status: \(error)")
        }
    }
    
    let monitor = NWPathMonitor()
    var stopPollingTimer: Timer?
    var currentState: NetworkState?
    
    func startMonitoringNetwork() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            
            DispatchQueue.main.async {
                switch path.isExpensive {
                case true:
                    guard self.currentState != .expensive else { return }
                    
                    if self.lastExpensiveDetectionTime == nil || Date().timeIntervalSince(self.lastExpensiveDetectionTime!) > 3.5 {
                        self.stopPollingData()
                    }
                    
                    self.lastExpensiveDetectionTime = Date()
                    self.stopPollingTimer?.invalidate()
                    self.stopPollingTimer = nil
                    self.printNetworkUsage()
                    self.startPollingData()
                    
                    self.currentState = .expensive
                    
                case false:
                    if self.currentState == nil {
                        self.currentState = .cheap
                        return
                    }
                    
                    guard self.currentState != .cheap else { return }
                    
                    print("cheap connection detected")
                    self.stopPollingData()
                    
                    self.currentState = .cheap
                }
            }
        }
        
        let queue = DispatchQueue(label: "NetworkMonitor")
        monitor.start(queue: queue)
    }
    
    func startPollingData() {
        invalidatePollingTimer()
        
        dataPollingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.printNetworkUsage()
        }
        
        isActive = true
    }
    
    func stopPollingData() {
        print("stopped polling")
        invalidatePollingTimer()
        resetDataUsageCounters()
        
        isActive = false
    }
    
    func invalidatePollingTimer() {
        dataPollingTimer?.invalidate()
        dataPollingTimer = nil
    }
    
    private var baselineWifiReceived: UInt64 = 0
    private var baselineWifiSent: UInt64 = 0
    private var previousWifiReceived: UInt64 = 0
    private var previousWifiSent: UInt64 = 0
    private var wifiReceivedRollovers: UInt64 = 0
    private var wifiSentRollovers: UInt64 = 0
    
    func printNetworkUsage() {
        let currentDataUsage = getDataUsageSinceBaseline()
        
        let deltaSent: UInt64
        let deltaReceived: UInt64
        
        if currentDataUsage.wifiSent >= lastDataUsage.wifiSent {
            deltaSent = currentDataUsage.wifiSent - lastDataUsage.wifiSent
        } else {
            deltaSent = currentDataUsage.wifiSent
        }
        
        if currentDataUsage.wifiReceived >= lastDataUsage.wifiReceived {
            deltaReceived = currentDataUsage.wifiReceived - lastDataUsage.wifiReceived
        } else {
            deltaReceived = currentDataUsage.wifiReceived
        }
        
        allTimeData.sent += deltaSent
        allTimeData.received += deltaReceived
        allTimeData.total = allTimeData.sent + allTimeData.received
        
        saveAllTimeData()
        
        currentData.total = currentDataUsage.wifiComplete
        currentData.sent = currentDataUsage.wifiSent
        currentData.received = currentDataUsage.wifiReceived
        currentData.received = currentDataUsage.wifiReceived
        
        print("Total: \(currentData.total), Sent: \(currentData.sent), Received: \(currentData.received)")
    }
    
    private func saveAllTimeData() {
        if let data = try? JSONEncoder().encode(allTimeData) {
            UserDefaults.standard.set(data, forKey: Keys.allTimeDataRecord)
        }
    }
    
    func resetAllTimeData() {
        allTimeData = DataStruct(sent: 0, received: 0, total: 0)
        saveAllTimeData()
    }
    
    func setBaselineValues() {
        let currentDataUsage = SystemDataUsage.getDataUsage()
        baselineWifiReceived = currentDataUsage.wifiReceived
        baselineWifiSent = currentDataUsage.wifiSent
    }
    
    func getDataUsageSinceBaseline() -> DataUsageInfo {
        let currentDataUsage = SystemDataUsage.getDataUsage()
        checkForRollovers(currentDataUsage: currentDataUsage)
        
        let maxUInt32Value: UInt64 = 4294967295
        
        return DataUsageInfo(
            wifiReceived: (currentDataUsage.wifiReceived + (wifiReceivedRollovers * maxUInt32Value)) - baselineWifiReceived,
            wifiSent: (currentDataUsage.wifiSent + (wifiSentRollovers * maxUInt32Value)) - baselineWifiSent
        )
    }
    
    func checkForRollovers(currentDataUsage: DataUsageInfo) {
        if currentDataUsage.wifiReceived < previousWifiReceived {
            wifiReceivedRollovers += 1
        }
        
        if currentDataUsage.wifiSent < previousWifiSent {
            wifiSentRollovers += 1
        }
        
        previousWifiReceived = currentDataUsage.wifiReceived
        previousWifiSent = currentDataUsage.wifiSent
    }
    
    func resetDataUsageCounters() {
        let currentDataUsage = SystemDataUsage.getDataUsage()
        previousWifiReceived = currentDataUsage.wifiReceived
        wifiReceivedRollovers = 0
        wifiSentRollovers = 0
        setBaselineValues()
        currentData = DataStruct(sent: 0, received: 0, total: 0)
        lastDataUsage = currentDataUsage
    }
    
    override init() {
        self.isRunAtStartupEnabled = (SMAppService.mainApp.status == .enabled)
        
        if let savedCounterType = UserDefaults.standard.string(forKey: Keys.counterType),
           let counterType = CounterType(rawValue: savedCounterType) {
            self.currentType = counterType
        } else {
            self.currentType = .session
        }
        
        if let savedDisplayMode = UserDefaults.standard.string(forKey: Keys.displayMode),
           let displayMode = DisplayMode(rawValue: savedDisplayMode) {
            self.currentDisplayMode = displayMode
        } else {
            self.currentDisplayMode = .combined
        }
        
        if let data = UserDefaults.standard.data(forKey: Keys.allTimeDataRecord),
           let allTimeRecord = try? JSONDecoder().decode(DataStruct.self, from: data) {
            self.allTimeData = allTimeRecord
        } else {
            self.allTimeData = DataStruct(sent: 0, received: 0, total: 0)
        }
        
        super.init()
        
        setBaselineValues()
        startMonitoringNetwork()
    }
    
    deinit {
        stopPollingData()
    }
}

extension Date {
    func formattedForRecentSessions() -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MMMM d yyyy, HH:mm"
        return dateFormatter.string(from: self)
    }
}

extension UInt64 {
    func formattedDataString() -> String {
        if self < (1000 * 1000) {
            return String(format: "%d KB", self / 1000)
        } else if self < (1000 * 1000 * 1000) {
            return String(format: "%.1f MB", Double(self) / (1000.0 * 1000.0))
        } else {
            return String(format: "%.1f GB", Double(self) / (1000.0 * 1000.0 * 1000.0))
        }
    }
}

class SystemDataUsage {
    private static let wifiInterfacePrefix = "en"
    
    class func getDataUsage() -> DataUsageInfo {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        var dataUsageInfo = DataUsageInfo()

        guard getifaddrs(&ifaddr) == 0 else { return dataUsageInfo }
        defer { freeifaddrs(ifaddr) }

        var currentAddr = ifaddr
        while let addr = currentAddr {
            if let info = getDataUsageInfo(from: &addr.pointee) {
                dataUsageInfo.updateInfoByAdding(info)
            }
            currentAddr = addr.pointee.ifa_next
        }

        return dataUsageInfo
    }
    
    private class func getDataUsageInfo(from infoPointer: UnsafeMutablePointer<ifaddrs>) -> DataUsageInfo? {
        guard let name = String(cString: infoPointer.pointee.ifa_name, encoding: .utf8) else { return nil }
        let addr = infoPointer.pointee.ifa_addr.pointee
        guard addr.sa_family == UInt8(AF_LINK) else { return nil }
        
        return dataUsageInfo(from: infoPointer, name: name)
    }
    
    private class func dataUsageInfo(from pointer: UnsafeMutablePointer<ifaddrs>, name: String) -> DataUsageInfo {
        var dataUsageInfo = DataUsageInfo()

        if name.hasPrefix(wifiInterfacePrefix),
           pointer.pointee.ifa_addr.pointee.sa_family == UInt8(AF_LINK) {
            if let networkData = pointer.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) {
                dataUsageInfo.wifiSent += UInt64(networkData.pointee.ifi_obytes)
                dataUsageInfo.wifiReceived += UInt64(networkData.pointee.ifi_ibytes)
            }
        }

        return dataUsageInfo
    }
}
