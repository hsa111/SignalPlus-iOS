//
//  Copyright (c) 2021 Open Whisper Systems. All rights reserved.
//

import Foundation

public struct ChatColor: Equatable, Codable {
    public let id: String
    public let setting: ColorOrGradientSetting
    public let isBuiltIn: Bool
    public let creationTimestamp: UInt64
    public let updateTimestamp: UInt64

    public init(id: String,
                setting: ColorOrGradientSetting,
                isBuiltIn: Bool = false,
                creationTimestamp: UInt64 = NSDate.ows_millisecondTimeStamp()) {
        self.id = id
        self.setting = setting
        self.isBuiltIn = isBuiltIn
        self.creationTimestamp = creationTimestamp
        self.updateTimestamp = NSDate.ows_millisecondTimeStamp()
    }

    public static var randomId: String {
        UUID().uuidString
    }

    public static var placeholderValue: ChatColor {
        ChatColors.defaultChatColor
    }

    // MARK: - Equatable

    public static func == (lhs: ChatColor, rhs: ChatColor) -> Bool {
        // Ignore timestamps, etc.
        (lhs.id == rhs.id) && (lhs.setting == rhs.setting)
    }
}

// MARK: -

@objc
public class ChatColors: NSObject, Dependencies {
    @objc
    public override init() {
        super.init()

        SwiftSingletons.register(self)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(warmCaches),
            name: .WarmCaches,
            object: nil
        )
    }

    // The cache should contain all current values at all times.
    @objc
    private func warmCaches() {
        var valueCache = [String: ChatColor]()

        // Load built-in colors.
        for value in Self.builtInValues {
            guard valueCache[value.id] == nil else {
                owsFailDebug("Duplicate value: \(value.id).")
                continue
            }
            valueCache[value.id] = value
        }

        // Load custom colors.
        Self.databaseStorage.read { transaction in
            let keys = Self.customColorsStore.allKeys(transaction: transaction)
            for key in keys {
                func loadValue() -> ChatColor? {
                    do {
                        return try Self.customColorsStore.getCodableValue(forKey: key, transaction: transaction)
                    } catch {
                        owsFailDebug("Error: \(error)")
                        return nil
                    }
                }
                guard let value = loadValue() else {
                    owsFailDebug("Missing value: \(key)")
                    continue
                }
                guard valueCache[value.id] == nil else {
                    owsFailDebug("Duplicate value: \(value.id).")
                    continue
                }
                valueCache[value.id] = value
            }
        }

        Self.unfairLock.withLock {
            self.valueCache = valueCache
        }
    }

    // Represents the current "chat color" setting for a given thread
    // or the default.  "Custom chat colors" have a lifecycle independent
    // from the conversations/global defaults which use them.
    //
    // The keys in this store are thread unique ids _OR_ defaultKey (String).
    // The values are ChatColor.id (String).
    private static let chatColorSettingStore = SDSKeyValueStore(collection: "chatColorSettingStore")

    // The keys in this store are ChatColor.id (String).
    // The values are ChatColors.
    private static let customColorsStore = SDSKeyValueStore(collection: "customColorsStore.3")

    private static let defaultKey = "defaultKey"

    private static let unfairLock = UnfairLock()
    private var valueCache = [String: ChatColor]()

    public func upsertCustomValue(_ value: ChatColor, transaction: SDSAnyWriteTransaction) {
        Self.unfairLock.withLock {
            self.valueCache[value.id] = value
            do {
                try Self.customColorsStore.setCodable(value, key: value.id, transaction: transaction)
            } catch {
                owsFailDebug("Error: \(error)")
            }
        }
        transaction.addAsyncCompletionOffMain {
            self.fireChatColorsDidChange()
        }
    }

    public func deleteCustomValue(_ value: ChatColor, transaction: SDSAnyWriteTransaction) {
        Self.unfairLock.withLock {
            self.valueCache.removeValue(forKey: value.id)
            Self.customColorsStore.removeValue(forKey: value.id, transaction: transaction)
        }
        transaction.addAsyncCompletionOffMain {
            self.fireChatColorsDidChange()
        }
    }

    private func fireChatColorsDidChange() {
        NotificationCenter.default.postNotificationNameAsync(
            Self.chatColorsDidChange,
            object: nil,
            userInfo: nil
        )
    }

    private func value(forValueId valueId: String) -> ChatColor? {
        Self.unfairLock.withLock {
            self.valueCache[valueId]
        }
    }

    private var allValues: [ChatColor] {
        Self.unfairLock.withLock {
            Array(self.valueCache.values)
        }
    }

    public var allValuesSorted: [ChatColor] {
        allValues.sorted { (left, right) -> Bool in
            left.creationTimestamp < right.creationTimestamp
        }
    }
    public static var allValuesSorted: [ChatColor] { Self.chatColors.allValuesSorted }

    public static var defaultChatColor: ChatColor { Values.ultramarine }

    public static func autoChatColorForRendering(forThread thread: TSThread?,
                                                 transaction: SDSAnyReadTransaction) -> ChatColor {
        if let value = defaultChatColorSetting(transaction: transaction) {
            return value
        } else if let wallpaper = Wallpaper.wallpaperForRendering(for: thread,
                                                                  transaction: transaction) {
            return autoChatColorForRendering(forWallpaper: wallpaper)
        } else {
            return Self.defaultChatColor
        }
    }

    public static func autoChatColorForRendering(forWallpaper wallpaper: Wallpaper) -> ChatColor {
        wallpaper.defaultChatColor
    }

    // Returns nil for default/auto.
    public static func defaultChatColorSetting(transaction: SDSAnyReadTransaction) -> ChatColor? {
        chatColorSetting(key: defaultKey, transaction: transaction)
    }

    public static func defaultChatColorForRendering(transaction: SDSAnyReadTransaction) -> ChatColor {
        autoChatColorForRendering(forThread: nil, transaction: transaction)
    }

    public static func setDefaultChatColorSetting(_ value: ChatColor?,
                                                  transaction: SDSAnyWriteTransaction) {
        setChatColorSetting(key: defaultKey, value: value, transaction: transaction)
    }

    // Returns nil for default/auto.
    public static func chatColorSetting(thread: TSThread,
                                        transaction: SDSAnyReadTransaction) -> ChatColor? {
        if let value = chatColorSetting(key: thread.uniqueId, transaction: transaction) {
            return value
        }
        return ChatColors.defaultChatColorSetting(transaction: transaction)
    }

    public static func chatColorForRendering(thread: TSThread,
                                             transaction: SDSAnyReadTransaction) -> ChatColor {
        if let value = chatColorSetting(thread: thread, transaction: transaction) {
            return value
        } else {
            return autoChatColorForRendering(forThread: thread, transaction: transaction)
        }
    }

    public static func chatColorForRendering(address: SignalServiceAddress,
                                             transaction: SDSAnyReadTransaction) -> ChatColor {
        guard let thread = TSContactThread.getWithContactAddress(address, transaction: transaction) else {
            return Self.defaultChatColor
        }
        return chatColorForRendering(thread: thread, transaction: transaction)
    }

    public static func setChatColorSetting(_ value: ChatColor?,
                                           thread: TSThread,
                                           transaction: SDSAnyWriteTransaction) {
        setChatColorSetting(key: thread.uniqueId, value: value, transaction: transaction)
    }

    // Returns nil for default/auto.
    private static func chatColorSetting(key: String,
                                         transaction: SDSAnyReadTransaction) -> ChatColor? {
        guard let valueId = Self.chatColorSettingStore.getString(key, transaction: transaction) else {
            return nil
        }
        guard let value = Self.chatColors.value(forValueId: valueId) else {
            // This isn't necessarily an error.  A user might apply a custom
            // chat color value to a conversation (or the global default),
            // then delete the custom chat color value.  In that case, all
            // references to the value should behave as "auto" (the default).
            Logger.warn("Missing value: \(valueId).")
            return nil
        }
        return value
    }

    // Returns the number of conversations that use a given value.
    public static func usageCount(forValue value: ChatColor,
                                  transaction: SDSAnyReadTransaction) -> Int {
        let keys = chatColorSettingStore.allKeys(transaction: transaction)
        var count: Int = 0
        for key in keys {
            if value.id == Self.chatColorSettingStore.getString(key, transaction: transaction) {
                count += 1
            }
        }
        return count
    }

    public static let chatColorsDidChange = NSNotification.Name("chatColorsDidChange")
    public static let chatColorSettingDidChange = NSNotification.Name("chatColorSettingDidChange")
    public static let chatColorSettingDidChangeThreadUniqueIdKey = "chatColorSettingDidChangeThreadUniqueIdKey"

    private static func setChatColorSetting(key: String,
                                            value: ChatColor?,
                                            transaction: SDSAnyWriteTransaction) {
        if let value = value {
            // Ensure the value is already in the cache.
            if nil == Self.chatColors.value(forValueId: value.id) {
                owsFailDebug("Unknown value: \(value.id).")
            }

            Self.chatColorSettingStore.setString(value.id, key: key, transaction: transaction)
        } else {
            Self.chatColorSettingStore.removeValue(forKey: key, transaction: transaction)
        }

        transaction.addAsyncCompletionOffMain {
            if key == defaultKey {
                Self.chatColors.fireChatColorsDidChange()
            } else {
                NotificationCenter.default.postNotificationNameAsync(
                    Self.chatColorSettingDidChange,
                    object: nil,
                    userInfo: [
                        chatColorSettingDidChangeThreadUniqueIdKey: key
                    ]
                )
            }
        }
    }

    public static func resetAllSettings(transaction: SDSAnyWriteTransaction) {
        Self.chatColorSettingStore.removeAll(transaction: transaction)
    }

    // MARK: -

    public class Values {
        @available(*, unavailable, message: "Do not instantiate this class.")
        private init() {}

        // Default Gradient
        static let ultramarine = ChatColor(
            id: "Ultramarine",
            setting: .gradient(gradientColor1: UIColor(rgbHex: 0x0552F0).asOWSColor,
                               gradientColor2: UIColor(rgbHex: 0x2C6BED).asOWSColor,
                               angleRadians: CGFloat.pi * 0),
            isBuiltIn: true,
            creationTimestamp: 0
        )

        // Solid Colors
        static let crimson = ChatColor(
            id: "Crimson",
            setting: .solidColor(color: UIColor(rgbHex: 0xCF163E).asOWSColor),
            isBuiltIn: true,
            creationTimestamp: 1
        )
        static let vermilion = ChatColor(
            id: "Vermilion",
            setting: .solidColor(color: UIColor(rgbHex: 0xC73F0A).asOWSColor),
            isBuiltIn: true,
            creationTimestamp: 2
        )
        static let burlap = ChatColor(
            id: "Burlap",
            setting: .solidColor(color: UIColor(rgbHex: 0x6F6A58).asOWSColor),
            isBuiltIn: true,
            creationTimestamp: 3
        )
        static let forest = ChatColor(
            id: "Forest",
            setting: .solidColor(color: UIColor(rgbHex: 0x3B7845).asOWSColor),
            isBuiltIn: true,
            creationTimestamp: 4
        )
        static let wintergreen = ChatColor(
            id: "Wintergreen",
            setting: .solidColor(color: UIColor(rgbHex: 0x1D8663).asOWSColor),
            isBuiltIn: true,
            creationTimestamp: 5
        )
        static let teal = ChatColor(
            id: "Teal",
            setting: .solidColor(color: UIColor(rgbHex: 0x077D92).asOWSColor),
            isBuiltIn: true,
            creationTimestamp: 6
        )
        static let blue = ChatColor(
            id: "Blue",
            setting: .solidColor(color: UIColor(rgbHex: 0x336BA3).asOWSColor),
            isBuiltIn: true,
            creationTimestamp: 7
        )
        static let indigo = ChatColor(
            id: "Indigo",
            setting: .solidColor(color: UIColor(rgbHex: 0x6058CA).asOWSColor),
            isBuiltIn: true,
            creationTimestamp: 8
        )
        static let violet = ChatColor(
            id: "Violet",
            setting: .solidColor(color: UIColor(rgbHex: 0x9932C8).asOWSColor),
            isBuiltIn: true,
            creationTimestamp: 9
        )
        static let plum = ChatColor(
            id: "Plum",
            setting: .solidColor(color: UIColor(rgbHex: 0xAA377A).asOWSColor),
            isBuiltIn: true,
            creationTimestamp: 10
        )
        static let taupe = ChatColor(
            id: "Taupe",
            setting: .solidColor(color: UIColor(rgbHex: 0x8F616A).asOWSColor),
            isBuiltIn: true,
            creationTimestamp: 11
        )
        static let steel = ChatColor(
            id: "Steel",
            setting: .solidColor(color: UIColor(rgbHex: 0x71717F).asOWSColor),
            isBuiltIn: true,
            creationTimestamp: 12
        )

        // Gradients
        static let ember = ChatColor(
            id: "Ember",
            setting: .gradient(gradientColor1: UIColor(rgbHex: 0xE57C00).asOWSColor,
                               gradientColor2: UIColor(rgbHex: 0x5E0000).asOWSColor,
                               angleRadians: parseAngleDegreesFromSpec(168)),
            isBuiltIn: true,
            creationTimestamp: 13
        )
        static let midnight = ChatColor(
            id: "Midnight",
            setting: .gradient(gradientColor1: UIColor(rgbHex: 0x2C2C3A).asOWSColor,
                               gradientColor2: UIColor(rgbHex: 0x787891).asOWSColor,
                               angleRadians: parseAngleDegreesFromSpec(180)),
            isBuiltIn: true,
            creationTimestamp: 14
        )
        static let infrared = ChatColor(
            id: "Infrared",
            setting: .gradient(gradientColor1: UIColor(rgbHex: 0xF65560).asOWSColor,
                               gradientColor2: UIColor(rgbHex: 0x442CED).asOWSColor,
                               angleRadians: parseAngleDegreesFromSpec(192)),
            isBuiltIn: true,
            creationTimestamp: 15
        )
        static let lagoon = ChatColor(
            id: "Lagoon",
            setting: .gradient(gradientColor1: UIColor(rgbHex: 0x004066).asOWSColor,
                               gradientColor2: UIColor(rgbHex: 0x32867D).asOWSColor,
                               angleRadians: parseAngleDegreesFromSpec(180)),
            isBuiltIn: true,
            creationTimestamp: 16
        )
        static let fluorescent = ChatColor(
            id: "Fluorescent",
            setting: .gradient(gradientColor1: UIColor(rgbHex: 0xEC13DD).asOWSColor,
                               gradientColor2: UIColor(rgbHex: 0x1B36C6).asOWSColor,
                               angleRadians: parseAngleDegreesFromSpec(192)),
            isBuiltIn: true,
            creationTimestamp: 17
        )
        static let basil = ChatColor(
            id: "Basil",
            setting: .gradient(gradientColor1: UIColor(rgbHex: 0x2F9373).asOWSColor,
                               gradientColor2: UIColor(rgbHex: 0x077343).asOWSColor,
                               angleRadians: parseAngleDegreesFromSpec(180)),
            isBuiltIn: true,
            creationTimestamp: 18
        )
        static let sublime = ChatColor(
            id: "Sublime",
            setting: .gradient(gradientColor1: UIColor(rgbHex: 0x6281D5).asOWSColor,
                               gradientColor2: UIColor(rgbHex: 0x974460).asOWSColor,
                               angleRadians: parseAngleDegreesFromSpec(180)),
            isBuiltIn: true,
            creationTimestamp: 19
        )
        static let sea = ChatColor(
            id: "Sea",
            setting: .gradient(gradientColor1: UIColor(rgbHex: 0x498FD4).asOWSColor,
                               gradientColor2: UIColor(rgbHex: 0x2C66A0).asOWSColor,
                               angleRadians: parseAngleDegreesFromSpec(180)),
            isBuiltIn: true,
            creationTimestamp: 20
        )
        static let tangerine = ChatColor(
            id: "Tangerine",
            setting: .gradient(gradientColor1: UIColor(rgbHex: 0xDB7133).asOWSColor,
                               gradientColor2: UIColor(rgbHex: 0x911231).asOWSColor,
                               angleRadians: parseAngleDegreesFromSpec(192)),
            isBuiltIn: true,
            creationTimestamp: 21
        )

        private static func parseAngleDegreesFromSpec(_ angleDegreesFromSpec: CGFloat) -> CGFloat {
            // In our models:
            // If angleRadians = 0, gradientColor1 is N.
            // If angleRadians = PI / 2, gradientColor1 is E.
            // etc.
            //
            // In the spec:
            // If angleDegrees = 180, gradientColor1 is N.
            // If angleDegrees = 270, gradientColor1 is E.
            // etc.
            return ((angleDegreesFromSpec - 180) / 180) * CGFloat.pi
        }
    }

    private static var builtInValues: [ChatColor] {
        return [
            // We use fixed timestamps to ensure that built-in values
            // appear before custom values and to control their relative ordering.

            // Default Gradient
            Values.ultramarine,

            // Solid Colors
            Values.crimson,
            Values.vermilion,
            Values.burlap,
            Values.forest,
            Values.wintergreen,
            Values.teal,
            Values.blue,
            Values.indigo,
            Values.violet,
            Values.plum,
            Values.taupe,
            Values.steel,

            // Gradients
            Values.ember,
            Values.midnight,
            Values.infrared,
            Values.lagoon,
            Values.fluorescent,
            Values.basil,
            Values.sublime,
            Values.sea,
            Values.tangerine
        ]
    }
}

// MARK: -

public extension ChatColors {

    // Represents the "message sender" to "group name color" mapping
    // for a given CVC load.
    struct GroupNameColors {
        fileprivate let colorMap: [SignalServiceAddress: UIColor]
        // TODO: Pending design.
        fileprivate let defaultColor: UIColor

        public func color(for address: SignalServiceAddress) -> UIColor {
            colorMap[address] ?? defaultColor
        }

        fileprivate static var defaultColors: GroupNameColors {
            GroupNameColors(colorMap: [:], defaultColor: Theme.primaryTextColor)
        }
    }

    static func groupNameColors(forThread thread: TSThread) -> GroupNameColors {
        guard let groupThread = thread as? TSGroupThread else {
            return .defaultColors
        }
        let groupMembership = groupThread.groupMembership
        let values = Self.groupNameColorValues
        let isDarkThemeEnabled = Theme.isDarkThemeEnabled
        var lastIndex: Int = 0
        var colorMap = [SignalServiceAddress: UIColor]()
        let addresses = Array(groupMembership.fullMembers).stableSort()
        for (index, address) in addresses.enumerated() {
            let valueIndex = index % values.count
            guard let value = values[safe: valueIndex] else {
                owsFailDebug("Invalid values.")
                return .defaultColors
            }
            colorMap[address] = value.color(isDarkThemeEnabled: isDarkThemeEnabled)
            lastIndex = index
        }
        let defaultValueIndex = (lastIndex + 1) % values.count
        guard let defaultValue = values[safe: defaultValueIndex] else {
            owsFailDebug("Invalid values.")
            return .defaultColors
        }
        let defaultColor = defaultValue.color(isDarkThemeEnabled: isDarkThemeEnabled)
        return GroupNameColors(colorMap: colorMap, defaultColor: defaultColor)
    }

    private static var defaultGroupNameColor: UIColor {
        let isDarkThemeEnabled = Theme.isDarkThemeEnabled
        return Self.groupNameColorValues.first!.color(isDarkThemeEnabled: isDarkThemeEnabled)
    }

    fileprivate struct GroupNameColorValue {
        let lightTheme: UIColor
        let darkTheme: UIColor

        func color(isDarkThemeEnabled: Bool) -> UIColor {
            isDarkThemeEnabled ? darkTheme : lightTheme
        }
    }

    // In descending order of contrast with the other values.
    fileprivate static let groupNameColorValues: [GroupNameColorValue] = [
        GroupNameColorValue(lightTheme: UIColor(rgbHex: 0xD00B0B),
                            darkTheme: UIColor(rgbHex: 0xF76E6E)),
        GroupNameColorValue(lightTheme: UIColor(rgbHex: 0x067906),
                            darkTheme: UIColor(rgbHex: 0x0AB80A)),
        GroupNameColorValue(lightTheme: UIColor(rgbHex: 0x5151F6),
                            darkTheme: UIColor(rgbHex: 0x8B8BF9)),
        GroupNameColorValue(lightTheme: UIColor(rgbHex: 0x866118),
                            darkTheme: UIColor(rgbHex: 0xD08F0B)),
        GroupNameColorValue(lightTheme: UIColor(rgbHex: 0x067953),
                            darkTheme: UIColor(rgbHex: 0x09B37B)),
        GroupNameColorValue(lightTheme: UIColor(rgbHex: 0xA20CED),
                            darkTheme: UIColor(rgbHex: 0xCB72F8)),
        GroupNameColorValue(lightTheme: UIColor(rgbHex: 0x507406),
                            darkTheme: UIColor(rgbHex: 0x77AE09)),
        GroupNameColorValue(lightTheme: UIColor(rgbHex: 0x086DA0),
                            darkTheme: UIColor(rgbHex: 0x0DA6F2)),
        GroupNameColorValue(lightTheme: UIColor(rgbHex: 0xC70A88),
                            darkTheme: UIColor(rgbHex: 0xF76EC9)),
        GroupNameColorValue(lightTheme: UIColor(rgbHex: 0xB34209),
                            darkTheme: UIColor(rgbHex: 0xF4702F)),
        GroupNameColorValue(lightTheme: UIColor(rgbHex: 0x06792D),
                            darkTheme: UIColor(rgbHex: 0x0AB844)),
        GroupNameColorValue(lightTheme: UIColor(rgbHex: 0x7A3DF5),
                            darkTheme: UIColor(rgbHex: 0xAC86F9)),
        GroupNameColorValue(lightTheme: UIColor(rgbHex: 0x6C6C13),
                            darkTheme: UIColor(rgbHex: 0xA5A509)),
        GroupNameColorValue(lightTheme: UIColor(rgbHex: 0x067474),
                            darkTheme: UIColor(rgbHex: 0x09AEAE)),
        GroupNameColorValue(lightTheme: UIColor(rgbHex: 0xB80AB8),
                            darkTheme: UIColor(rgbHex: 0xF75FF7)),
        GroupNameColorValue(lightTheme: UIColor(rgbHex: 0x2D7906),
                            darkTheme: UIColor(rgbHex: 0x42B309)),
        GroupNameColorValue(lightTheme: UIColor(rgbHex: 0x0D59F2),
                            darkTheme: UIColor(rgbHex: 0x6495F7)),
        GroupNameColorValue(lightTheme: UIColor(rgbHex: 0xD00B4D),
                            darkTheme: UIColor(rgbHex: 0xF76998)),
        GroupNameColorValue(lightTheme: UIColor(rgbHex: 0xC72A0A),
                            darkTheme: UIColor(rgbHex: 0xF67055)),
        GroupNameColorValue(lightTheme: UIColor(rgbHex: 0x067919),
                            darkTheme: UIColor(rgbHex: 0x0AB827)),
        GroupNameColorValue(lightTheme: UIColor(rgbHex: 0x6447F5),
                            darkTheme: UIColor(rgbHex: 0x9986F9)),
        GroupNameColorValue(lightTheme: UIColor(rgbHex: 0x76681E),
                            darkTheme: UIColor(rgbHex: 0xB89B0A)),
        GroupNameColorValue(lightTheme: UIColor(rgbHex: 0x067462),
                            darkTheme: UIColor(rgbHex: 0x09B397)),
        GroupNameColorValue(lightTheme: UIColor(rgbHex: 0xAF0BD0),
                            darkTheme: UIColor(rgbHex: 0xE06EF7)),
        GroupNameColorValue(lightTheme: UIColor(rgbHex: 0x3D7406),
                            darkTheme: UIColor(rgbHex: 0x5EB309)),
        GroupNameColorValue(lightTheme: UIColor(rgbHex: 0x0A69C7),
                            darkTheme: UIColor(rgbHex: 0x429CF5)),
        GroupNameColorValue(lightTheme: UIColor(rgbHex: 0xCB0B6B),
                            darkTheme: UIColor(rgbHex: 0xF76EB2)),
        GroupNameColorValue(lightTheme: UIColor(rgbHex: 0x9C5711),
                            darkTheme: UIColor(rgbHex: 0xE97A0C)),
        GroupNameColorValue(lightTheme: UIColor(rgbHex: 0x067940),
                            darkTheme: UIColor(rgbHex: 0x09B35E)),
        GroupNameColorValue(lightTheme: UIColor(rgbHex: 0x8F2AF4),
                            darkTheme: UIColor(rgbHex: 0xBD81F8)),
        GroupNameColorValue(lightTheme: UIColor(rgbHex: 0x5E6E0C),
                            darkTheme: UIColor(rgbHex: 0x8FAA09)),
        GroupNameColorValue(lightTheme: UIColor(rgbHex: 0x077288),
                            darkTheme: UIColor(rgbHex: 0x0BABCB)),
        GroupNameColorValue(lightTheme: UIColor(rgbHex: 0xC20AA3),
                            darkTheme: UIColor(rgbHex: 0xF75FDD)),
        GroupNameColorValue(lightTheme: UIColor(rgbHex: 0x1A7906),
                            darkTheme: UIColor(rgbHex: 0x27B80A)),
        GroupNameColorValue(lightTheme: UIColor(rgbHex: 0x3454F4),
                            darkTheme: UIColor(rgbHex: 0x778DF8)),
        GroupNameColorValue(lightTheme: UIColor(rgbHex: 0xD00B2C),
                            darkTheme: UIColor(rgbHex: 0xF76E85))
    ]
}

// MARK: - Avatar Colors

@objc
public extension ChatColors {
    static var defaultAvatarColor: UIColor {
        Self.groupNameColorValues.first!.lightTheme
    }

    static func avatarColor(forThread thread: TSThread) -> UIColor {
        if let contactThread = thread as? TSContactThread {
            return avatarColor(forAddress: contactThread.contactAddress)
        } else if let groupThread = thread as? TSGroupThread {
            return avatarColor(forGroupId: groupThread.groupId)
        } else {
            owsFailDebug("Invalid thread.")
            return Self.defaultAvatarColor
        }
    }

    static func avatarColor(forGroupModel groupModel: TSGroupModel) -> UIColor {
        avatarColor(forGroupId: groupModel.groupId)
    }

    static func avatarColor(forGroupId groupId: Data) -> UIColor {
        avatarColor(forData: groupId)
    }

    static func avatarColor(forAddress address: SignalServiceAddress) -> UIColor {
        guard let seed = address.serviceIdentifier else {
            owsFailDebug("Missing serviceIdentifier.")
            return Self.defaultAvatarColor
        }
        return avatarColor(forSeed: seed)
    }

    static func avatarColor(forSeed seed: String) -> UIColor {
        guard let data = seed.data(using: .utf8) else {
            owsFailDebug("Invalid seed.")
            return Self.defaultAvatarColor
        }
        return avatarColor(forData: data)
    }

    private static func avatarColor(forData data: Data) -> UIColor {
        var hash: UInt = 0
        for value in data {
            // A primitive hashing function.
            // We only require it to be stable and fast.
            hash = hash.rotateLeft(3) ^ UInt(value)
        }
        let values = Self.groupNameColorValues
        guard let value = values[safe: Int(hash % UInt(values.count))] else {
            owsFailDebug("Could not determine avatar color.")
            return Self.defaultAvatarColor
        }
        return value.lightTheme
    }
}

// MARK: -

extension UInt {
    public static let is64bit = { UInt.bitWidth == UInt64.bitWidth }()
    public static let is32bit = { UInt.bitWidth == UInt32.bitWidth }()

    public static let highestBit: UInt = {
        if is32bit {
            return UInt(1).rotateLeft(31)
        } else if is64bit {
            return UInt(1).rotateLeft(63)
        } else {
            owsFail("Unexpected UInt width.")
        }
    }()

    // <<<
    public func rotateLeft(_ count: Int) -> UInt {
        let count = count % UInt.bitWidth
        return (self << count) | (self >> (UInt.bitWidth - count))
    }
}