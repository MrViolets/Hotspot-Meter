//
//  SystemDataUsage.swift
//  Hotspot Meter
//
//  Created by Sylvester Wilmott on 13/12/2023.
//

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
