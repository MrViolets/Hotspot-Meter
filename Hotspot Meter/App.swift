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
    static let allTimeDataRecord = "allTimeDataRecord"
}

@main
struct MenuBar: App {
    @StateObject private var menuHandler = MenuHandler()
    
    init() {
        let defaultDataStruct = DataStruct(sent: 0, received: 0, total: 0)
        let defaultDataStructEncoded = try? JSONEncoder().encode(defaultDataStruct)
        
        UserDefaults.standard.register(defaults: [
            Keys.displayMode: DisplayMode.combined.rawValue,
            Keys.allTimeDataRecord: defaultDataStructEncoded ?? Data()
        ])
    }
    
    var body: some Scene {
        MenuBarExtra {
            Text("Total Usage")
                .font(.system(.body, weight: .medium))
            Menu {
                Text("Total: \(menuHandler.allTimeData.total.formattedDataString())")
                Text("Sent: \(menuHandler.allTimeData.sent.formattedDataString())")
                Text("Received: \(menuHandler.allTimeData.received.formattedDataString())")
                Divider()
                Button("Reset", action: menuHandler.resetAllTimeData)
            } label: {
                Text("\(menuHandler.allTimeData.total.formattedDataString())")
            }
            if !menuHandler.recentSessions.isEmpty {
                Divider()
                Menu("Recent Sessions") {
                    ForEach(menuHandler.recentSessions.indices, id: \.self) { index in
                        let session = menuHandler.recentSessions[index]
                        Menu {
                            Text("\(session.date.formattedForRecentSessions())")
                            Divider()
                            Text("Total: \(session.total.formattedDataString())")
                            Text("Sent: \(session.sent.formattedDataString())")
                            Text("Received: \(session.received.formattedDataString())")
                        } label: {
                            Text("\(session.total.formattedDataString())")
                        }
                    }
                    Divider()
                    Button("Clear", action: menuHandler.clearSessions)
                }
            }
            Divider()
            Picker("Counter Display", selection: $menuHandler.currentDisplayMode) {
                ForEach(DisplayMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }.pickerStyle(MenuPickerStyle())
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
                    if menuHandler.isActive {
                        Text(menuHandler.currentData.total.formattedDataString())
                    }
                }
                
            case .split:
                HStack {
                    if !menuHandler.isActive {
                        Image(systemName: "arrow.up.arrow.down")
                    } else {
                        Text("↑ \(menuHandler.currentData.sent.formattedDataString())  ↓ \(menuHandler.currentData.received.formattedDataString())")
                    }
                }
                
            case .onlyReceived:
                HStack {
                    Image(systemName: "arrow.down")
                    if menuHandler.isActive {
                        Text(menuHandler.currentData.received.formattedDataString())
                    }
                }
                
            case .onlySent:
                HStack {
                    Image(systemName: "arrow.up")
                    if menuHandler.isActive {
                        Text(menuHandler.currentData.sent.formattedDataString())
                    }
                }
            }
        }
    }
}

enum DisplayMode: String, CaseIterable {
    case combined = "Combined"
    case split = "Split"
    case onlySent = "Sent"
    case onlyReceived = "Received"
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

struct DataStruct: Codable {
    var sent: UInt64
    var received: UInt64
    var total: UInt64
}

struct SessionData: Codable {
    let date: Date
    let sent: UInt64
    let received: UInt64
    let total: UInt64
}

class MenuHandler: NSObject, ObservableObject {
    enum NetworkState {
        case expensive, cheap
    }
    
    @Published var allTimeData = DataStruct(sent: 0, received: 0, total: 0)
    @Published var currentData = DataStruct(sent: 0, received: 0, total: 0)
    
    @Published var recentSessions: [SessionData] = []
    
    private var lastDataUsage = DataUsageInfo()
    
    private var dataPollingTimer: Timer?
    private var lastExpensiveDetectionTime: Date?
    
    @Published var isActive: Bool = false
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
                    
                    print("expensive connection detected")
                    
                    if self.lastExpensiveDetectionTime == nil || Date().timeIntervalSince(self.lastExpensiveDetectionTime!) > 3.5 {
                        if self.currentData.total != 0 {
                            self.saveSession()
                        }
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
                    self.saveSession()
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
    
    func saveSession() {
        print("Saving session")
        let session = SessionData(
            date: Date(),
            sent: currentData.sent,
            received: currentData.received,
            total: currentData.total
        )
        
        recentSessions.insert(session, at: 0)
        if recentSessions.count > 10 {
            recentSessions.removeLast()
        }
        
        if let data = try? JSONEncoder().encode(recentSessions) {
            UserDefaults.standard.set(data, forKey: "recentSessions")
        }
    }
    
    private func loadRecentSessions() {
        if let data = UserDefaults.standard.data(forKey: "recentSessions"),
           let sessions = try? JSONDecoder().decode([SessionData].self, from: data) {
            self.recentSessions = sessions
        }
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
        
        currentData.total = currentDataUsage.wifiComplete
        currentData.received = currentDataUsage.wifiReceived
        currentData.sent = currentDataUsage.wifiSent
        
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
    
    func clearSessions() {
        recentSessions.removeAll()
        UserDefaults.standard.removeObject(forKey: "recentSessions")
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
        loadRecentSessions()
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
