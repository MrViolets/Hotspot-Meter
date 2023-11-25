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
    static let runAtStartup = "runAtStartup"
    static let allTimeDataRecord = "allTimeDataRecord"
}

@main
struct MenuBar: App {
    @StateObject private var menuHandler = MenuHandler()
    
    var body: some Scene {
        MenuBarExtra {
            Divider()
            Text("Total Usage")
                .font(.system(.body, weight: .medium))
            Menu {
                Text("All: \(menuHandler.allTimeData.total.formattedDataString())")
                Text("Sent: \(menuHandler.allTimeData.sent.formattedDataString())")
                Text("Received: \(menuHandler.allTimeData.received.formattedDataString())")
                Divider()
                Button("Reset", action: menuHandler.resetAllTimeData)
            } label: {
                Text("\(menuHandler.allTimeData.total.formattedDataString())")
            }
            Divider()
            Picker("Counter Display", selection: $menuHandler.currentDisplayMode) {
                ForEach(DisplayMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }.pickerStyle(MenuPickerStyle())
            Divider()
            Toggle("Start at Login", isOn: $menuHandler.isRunAtStartupEnabled)
            Divider()
            Button("Quit") {
                NSApp.terminate(self)
            }.keyboardShortcut("q")
            
        } label: {
            switch menuHandler.currentDisplayMode {
            case .combined:
                HStack {
                    Image(systemName: "arrow.up.arrow.down")
                    if !menuHandler.allDataText.isEmpty {
                        Text(menuHandler.allDataText)
                            .font(.system(.body, design: .monospaced))
                    }
                }
                
            case .onlyReceived:
                HStack {
                    Image(systemName: "arrow.down")
                    if !menuHandler.downloadedText.isEmpty {
                        Text(menuHandler.downloadedText)
                            .font(.system(.body, design: .monospaced))
                    }
                }
                
            case .onlySent:
                HStack {
                    Image(systemName: "arrow.up")
                    if !menuHandler.uploadedText.isEmpty {
                        Text(menuHandler.uploadedText)
                            .font(.system(.body, design: .monospaced))
                    }
                }
            }
        }
    }
}

enum DisplayMode: String, CaseIterable {
    case combined = "All Data"
    case onlySent = "Data Sent"
    case onlyReceived = "Data Received"
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

class SystemDataUsage {
    private static let wifiInterfacePrefix = "en"
    
    class func getDataUsage() -> DataUsageInfo {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        var dataUsageInfo = DataUsageInfo()
        
        guard getifaddrs(&ifaddr) == 0 else { return dataUsageInfo }
        while let addr = ifaddr {
            guard let info = getDataUsageInfo(from: addr) else {
                ifaddr = addr.pointee.ifa_next
                continue
            }
            dataUsageInfo.updateInfoByAdding(info)
            ifaddr = addr.pointee.ifa_next
        }
        
        freeifaddrs(ifaddr)
        
        return dataUsageInfo
    }
    
    private class func getDataUsageInfo(from infoPointer: UnsafeMutablePointer<ifaddrs>) -> DataUsageInfo? {
        let pointer = infoPointer
        guard let name = String(cString: pointer.pointee.ifa_name, encoding: .utf8) else { return nil }
        let addr = pointer.pointee.ifa_addr.pointee
        guard addr.sa_family == UInt8(AF_LINK) else { return nil }
        
        return dataUsageInfo(from: pointer, name: name)
    }
    
    private class func dataUsageInfo(from pointer: UnsafeMutablePointer<ifaddrs>, name: String) -> DataUsageInfo {
        var networkData: UnsafeMutablePointer<if_data>?
        var dataUsageInfo = DataUsageInfo()
        
        if name.hasPrefix(wifiInterfacePrefix) {
            networkData = unsafeBitCast(pointer.pointee.ifa_data, to: UnsafeMutablePointer<if_data>.self)
            if let data = networkData {
                dataUsageInfo.wifiSent += UInt64(data.pointee.ifi_obytes)
                dataUsageInfo.wifiReceived += UInt64(data.pointee.ifi_ibytes)
            }
            
        }
        
        return dataUsageInfo
    }
}

struct TotalData: Codable {
    var sent: UInt64
    var received: UInt64
    var total: UInt64
}

class MenuHandler: NSObject, ObservableObject {
    enum NetworkState {
        case expensive, cheap
    }
    
    @Published var allTimeData = TotalData(sent: 0, received: 0, total: 0)
    private var lastDataUsage = DataUsageInfo()
    
    private var dataPollingTimer: Timer?
    private var lastExpensiveDetectionTime: Date?
    
    @Published var allDataText: String = ""
    @Published var uploadedText: String = ""
    @Published var downloadedText: String = ""
    
    @Published var isActive: Bool = false
    @Published var currentDisplayMode: DisplayMode {
        didSet {
            UserDefaults.standard.set(currentDisplayMode.rawValue, forKey: Keys.displayMode)
        }
    }
    
    let monitor = NWPathMonitor()
    var stopPollingTimer: Timer?
    var currentState: NetworkState?
    var allDataTextIsEmpty: Bool {
        return uploadedText.isEmpty && downloadedText.isEmpty && allDataText.isEmpty
    }
    
    func startMonitoringNetwork() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            
            DispatchQueue.main.async {
                switch path.isExpensive {
                case true:
                    guard self.currentState != .expensive else { return }
                    
                    print("expensive connection detected")
                    
                    if let lastDetection = self.lastExpensiveDetectionTime,
                       Date().timeIntervalSince(lastDetection) > 3.5 {
                        self.stopPollingData()
                        self.setBaselineValues()
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
    
    var baselineWifiReceived: UInt64 = 0
    var baselineWifiSent: UInt64 = 0
    var previousWifiReceived: UInt64 = 0
    var previousWifiSent: UInt64 = 0
    var wifiReceivedRollovers: UInt64 = 0
    var wifiSentRollovers: UInt64 = 0
    
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
        
        lastDataUsage = currentDataUsage
        
        allDataText = currentDataUsage.wifiComplete.formattedDataString()
        uploadedText = currentDataUsage.wifiSent.formattedDataString()
        downloadedText = currentDataUsage.wifiReceived.formattedDataString()
        print("Total: \(allDataText), Sent: \(uploadedText), Received: \(downloadedText)")
    }
    
    
    private func saveAllTimeData() {
        if let data = try? JSONEncoder().encode(allTimeData) {
            UserDefaults.standard.set(data, forKey: Keys.allTimeDataRecord)
        }
    }
    
    func resetAllTimeData() {
        allTimeData = TotalData(sent: 0, received: 0, total: 0)
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
        allDataText = ""
        uploadedText = ""
        downloadedText = ""
        lastDataUsage = currentDataUsage
    }
    
    @Published var isRunAtStartupEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isRunAtStartupEnabled, forKey: Keys.runAtStartup)
            
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
    }
    
    override init() {
        self.isRunAtStartupEnabled = UserDefaults.standard.bool(forKey: Keys.runAtStartup)
        
        if let savedDisplayMode = UserDefaults.standard.string(forKey: Keys.displayMode),
           let displayMode = DisplayMode(rawValue: savedDisplayMode) {
            self.currentDisplayMode = displayMode
        } else {
            self.currentDisplayMode = .combined
        }
        
        if let data = UserDefaults.standard.data(forKey: Keys.allTimeDataRecord),
           let allTimeRecord = try? JSONDecoder().decode(TotalData.self, from: data) {
            self.allTimeData = allTimeRecord
        } else {
            self.allTimeData = TotalData(sent: 0, received: 0, total: 0)
        }
        
        super.init()
        
        setBaselineValues()
        startMonitoringNetwork()
    }
    
    deinit {
        stopPollingData()
    }
}
