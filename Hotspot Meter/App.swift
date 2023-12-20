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

    var body: some Scene {
        MenuBarExtra {
            Picker("Counter Display", selection: $menuHandler.currentDisplayMode) {
                ForEach(DisplayMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }.pickerStyle(MenuPickerStyle())

            Divider()

            if menuHandler.allTimeData.total > 0 {
                Menu {
                    Button {
                        // No action
                    } label: {
                        HStack {
                            Text("\(menuHandler.allTimeData.total.formattedDataString())")
                        }
                    }
                    .disabled(true)
                    Divider()
                    Button {
                        // No action
                    } label: {
                        HStack {
                            Image(systemName: "arrow.up")
                            Text(menuHandler.allTimeData.sent.formattedDataString())
                        }
                    }
                    .disabled(true)
                    Button {
                        // No action
                    } label: {
                        HStack {
                            Image(systemName: "arrow.down")
                            Text(menuHandler.allTimeData.received.formattedDataString())
                        }
                    }
                    .disabled(true)
                    Divider()
                    Button("Clear", action: menuHandler.resetAllTimeData)
                } label: {
                    Text("All-Time Data Usage")
                }
            } else {
                Text("All-Time Data Usage").disabled(true)
            }

            if !menuHandler.groupedMonthlyData.isEmpty {
                Menu {
                    ForEach(menuHandler.groupedMonthlyData.keys.sorted(by: >), id: \.self) { year in
                        let monthsData = menuHandler.groupedMonthlyData[year]?.sorted { $0.month > $1.month }
                        Section(header: Text(String(year))) {
                            ForEach(monthsData ?? [], id: \.self) { monthlyData in
                                let formattedMonthYear = monthName(from: monthlyData.month)
                                Menu {
                                    Button {
                                        // No action
                                    } label: {
                                        HStack {
                                            Text(monthlyData.total.formattedDataString())
                                        }
                                    }
                                    .disabled(true)
                                    Divider()
                                    Button {
                                        // No action
                                    } label: {
                                        HStack {
                                            Image(systemName: "arrow.up")
                                            Text(monthlyData.sent.formattedDataString())
                                        }
                                    }
                                    .disabled(true)
                                    Button {
                                        // No action
                                    } label: {
                                        HStack {
                                            Image(systemName: "arrow.down")
                                            Text(monthlyData.received.formattedDataString())
                                        }
                                    }
                                    .disabled(true)
                                } label: {
                                    Text(formattedMonthYear)
                                }
                            }
                        }
                    }
                    Divider()
                    Button("Clear") {
                        menuHandler.clearAllMonthlyData()
                    }
                } label: {
                    Text("Data Usage by Month")
                }
            } else {
                Text("Data Usage by Month").disabled(true)
            }

            Divider()

            Toggle("Launch at Login", isOn: $menuHandler.isRunAtStartupEnabled)

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
                        Text("↑ \(menuHandler.currentData.sent.formattedDataString())   ↓ \(menuHandler.currentData.received.formattedDataString())")
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

struct MonthlyData: Codable, Hashable {
    var year: Int
    var month: Int
    var sent: UInt64
    var received: UInt64
    var total: UInt64
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(year)
        hasher.combine(month)
    }
    
    static func == (lhs: MonthlyData, rhs: MonthlyData) -> Bool {
        return lhs.year == rhs.year && lhs.month == rhs.month
    }
}

class MenuHandler: NSObject, ObservableObject {
    enum NetworkState {
        case expensive, cheap
    }
    
    @Published var allTimeData = DataStruct(sent: 0, received: 0, total: 0)
    @Published var currentData = DataStruct(sent: 0, received: 0, total: 0)
    
    @Published var monthlyDataList: [MonthlyData] = []
    var groupedMonthlyData: [Int: [MonthlyData]] {
        Dictionary(grouping: monthlyDataList) { $0.year }
    }
    
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
    
    private func loadMonthlyData(forYear year: Int, andMonth month: Int) -> MonthlyData? {
        let userDefaults = UserDefaults.standard
        let key = "monthlyData-\(year)-\(month)"
        
        guard let data = userDefaults.data(forKey: key) else {
            return nil
        }
        
        let decoder = JSONDecoder()
        return try? decoder.decode(MonthlyData.self, from: data)
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
        
        let now = Date()
        let calendar = Calendar.current
        let year = calendar.component(.year, from: now)
        let month = calendar.component(.month, from: now)
        updateMonthlyData(year: year, month: month, sent: deltaSent, received: deltaReceived)
        
        lastDataUsage = currentDataUsage
        
        currentData.total = currentDataUsage.wifiComplete
        currentData.sent = currentDataUsage.wifiSent
        currentData.received = currentDataUsage.wifiReceived
        currentData.received = currentDataUsage.wifiReceived
        
        print("Total: \(currentData.total), Sent: \(currentData.sent), Received: \(currentData.received)")
    }
    
    private func updateMonthlyData(year: Int, month: Int, sent: UInt64, received: UInt64) {
        var monthlyData = loadMonthlyData(forYear: year, andMonth: month) ?? MonthlyData(year: year, month: month, sent: 0, received: 0, total: 0)
        
        monthlyData.sent += sent
        monthlyData.received += received
        monthlyData.total += (sent + received)
        
        saveMonthlyData(monthlyData)
        loadAllMonthlyData()
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
    
    private func loadAllMonthlyData() {
        let userDefaults = UserDefaults.standard
        let decoder = JSONDecoder()
        
        if let monthlyDataKeys = userDefaults.array(forKey: "monthlyDataKeys") as? [String] {
            self.monthlyDataList = monthlyDataKeys.compactMap { key in
                if let data = userDefaults.data(forKey: key),
                   let monthlyData = try? decoder.decode(MonthlyData.self, from: data) {
                    return monthlyData
                }
                return nil
            }
        }
    }
    
    private func saveMonthlyData(_ monthlyData: MonthlyData) {
        let userDefaults = UserDefaults.standard
        let encoder = JSONEncoder()
        
        let key = "monthlyData-\(monthlyData.year)-\(monthlyData.month)"
        if let encoded = try? encoder.encode(monthlyData) {
            userDefaults.set(encoded, forKey: key)
            
            if !monthlyDataList.contains(where: { $0.year == monthlyData.year && $0.month == monthlyData.month }) {
                monthlyDataList.append(monthlyData)
            }
            
            monthlyDataList.sort { ($0.year, $0.month) > ($1.year, $1.month) }
            if monthlyDataList.count > 12 {
                monthlyDataList.removeSubrange(12...)
            }
            
            let keys = monthlyDataList.map { "monthlyData-\($0.year)-\($0.month)" }
            userDefaults.set(keys, forKey: "monthlyDataKeys")
        }
    }
    
    func clearAllMonthlyData() {
        let userDefaults = UserDefaults.standard
        
        if let monthlyDataKeys = userDefaults.array(forKey: "monthlyDataKeys") as? [String] {
            for key in monthlyDataKeys {
                userDefaults.removeObject(forKey: key)
            }
        }
        
        userDefaults.set([], forKey: "monthlyDataKeys")
        
        monthlyDataList.removeAll()
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
        loadAllMonthlyData()
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

func monthName(from monthNumber: Int) -> String {
    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "MMMM"
    let date = Calendar.current.date(from: DateComponents(month: monthNumber))!
    return dateFormatter.string(from: date)
}
