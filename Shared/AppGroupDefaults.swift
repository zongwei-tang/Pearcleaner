//
//  AppGroupDefaults.swift
//  Pearcleaner
//
//  Created by Alin Lupascu on 9/30/25.
//

import Foundation

extension UserDefaults {
    // Team-prefixed group ("TEAMID.com.alienator88.Pearcleaner") set at build time in the PearcleanerAppGroup
    // Info.plist key, matching the entitlements; needs no provisioning profile. Falls back to the upstream group.
    static let appGroupIdentifier: String = {
        if let id = Bundle.main.object(forInfoDictionaryKey: "PearcleanerAppGroup") as? String,
           !id.isEmpty, !id.contains("$("), !id.hasPrefix(".") {
            return id
        }
        return "group.com.alienator88.Pearcleaner"
    }()

    static let appGroup = UserDefaults(suiteName: appGroupIdentifier)!

    struct Keys {
        static let showAppIconInMenu = "showAppIconInMenu"
    }

    // Setting for showing app icon in context menu
    static var showAppIconInMenu: Bool {
        get {
            return appGroup.bool(forKey: Keys.showAppIconInMenu)
        }
        set {
            appGroup.set(newValue, forKey: Keys.showAppIconInMenu)
        }
    }
}
