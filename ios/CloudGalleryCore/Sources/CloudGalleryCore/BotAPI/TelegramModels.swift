import Foundation

/// Envelope returned by every Telegram Bot API method.
public struct TGResponse<T: Decodable>: Decodable {
    public let ok: Bool
    public let result: T?
    public let description: String?
    public let errorCode: Int?
    public let parameters: TGResponseParameters?

    enum CodingKeys: String, CodingKey {
        case ok, result, description, parameters
        case errorCode = "error_code"
    }
}

public struct TGResponseParameters: Decodable, Equatable {
    public let retryAfter: Int?
    public let migrateToChatId: Int64?

    enum CodingKeys: String, CodingKey {
        case retryAfter = "retry_after"
        case migrateToChatId = "migrate_to_chat_id"
    }
}

public struct TGUser: Decodable, Equatable {
    public let id: Int64
    public let isBot: Bool
    public let firstName: String
    public let username: String?

    enum CodingKeys: String, CodingKey {
        case id, username
        case isBot = "is_bot"
        case firstName = "first_name"
    }
}

public struct TGChat: Decodable, Equatable {
    public let id: Int64
    public let type: String
    public let title: String?
    public let username: String?
    public let pinnedMessage: Box<TGMessage>?

    enum CodingKeys: String, CodingKey {
        case id, type, title, username
        case pinnedMessage = "pinned_message"
    }

    public var isChannelOrGroup: Bool { type == "channel" || type == "supergroup" || type == "group" }
}

/// Indirection so `TGChat` can contain a `TGMessage` that itself contains a `TGChat`.
public final class Box<T: Decodable & Equatable>: Decodable, Equatable {
    public let value: T
    public init(_ value: T) { self.value = value }
    public required init(from decoder: Decoder) throws { value = try T(from: decoder) }
    public static func == (lhs: Box<T>, rhs: Box<T>) -> Bool { lhs.value == rhs.value }
}

public struct TGDocument: Decodable, Equatable {
    public let fileId: String
    public let fileUniqueId: String
    public let fileName: String?
    public let mimeType: String?
    public let fileSize: Int64?

    enum CodingKeys: String, CodingKey {
        case fileId = "file_id"
        case fileUniqueId = "file_unique_id"
        case fileName = "file_name"
        case mimeType = "mime_type"
        case fileSize = "file_size"
    }
}

public struct TGMessage: Decodable, Equatable {
    public let messageId: Int64
    public let date: Int
    public let chat: TGChat
    public let caption: String?
    public let text: String?
    public let document: TGDocument?

    enum CodingKeys: String, CodingKey {
        case date, chat, caption, text, document
        case messageId = "message_id"
    }
}

public struct TGChatMemberUpdated: Decodable, Equatable {
    public let chat: TGChat
}

public struct TGUpdate: Decodable, Equatable {
    public let updateId: Int64
    public let message: TGMessage?
    public let channelPost: TGMessage?
    public let myChatMember: TGChatMemberUpdated?

    enum CodingKeys: String, CodingKey {
        case message
        case updateId = "update_id"
        case channelPost = "channel_post"
        case myChatMember = "my_chat_member"
    }

    /// The chat this update refers to, whichever field carries it.
    public var chat: TGChat? { channelPost?.chat ?? message?.chat ?? myChatMember?.chat }
}

public struct TGChatMember: Decodable, Equatable {
    public let status: String
    public let canPostMessages: Bool?
    public let canEditMessages: Bool?
    public let canDeleteMessages: Bool?
    public let canPinMessages: Bool?

    enum CodingKeys: String, CodingKey {
        case status
        case canPostMessages = "can_post_messages"
        case canEditMessages = "can_edit_messages"
        case canDeleteMessages = "can_delete_messages"
        case canPinMessages = "can_pin_messages"
    }

    public init(status: String, canPostMessages: Bool?, canEditMessages: Bool?, canDeleteMessages: Bool?, canPinMessages: Bool?) {
        self.status = status
        self.canPostMessages = canPostMessages
        self.canEditMessages = canEditMessages
        self.canDeleteMessages = canDeleteMessages
        self.canPinMessages = canPinMessages
    }
}

public struct TGFile: Decodable, Equatable {
    public let fileId: String
    public let fileUniqueId: String
    public let fileSize: Int64?
    public let filePath: String?

    enum CodingKeys: String, CodingKey {
        case fileId = "file_id"
        case fileUniqueId = "file_unique_id"
        case fileSize = "file_size"
        case filePath = "file_path"
    }
}

/// Result of checking the bot's admin rights in the backup chat.
public struct BotPermissionReport: Equatable {
    public let isAdmin: Bool
    public let canPost: Bool
    public let canDelete: Bool
    public let canPin: Bool
    public let canEdit: Bool
    public let chatType: String

    public var missing: [String] {
        var m: [String] = []
        if !isAdmin { m.append("administrator") }
        if !canPost { m.append("post messages") }
        if !canDelete { m.append("delete messages") }
        if !canPin { m.append("pin messages") }
        return m
    }

    public var isSufficient: Bool { missing.isEmpty }

    public init(member: TGChatMember, chatType: String) {
        self.chatType = chatType
        isAdmin = member.status == "administrator" || member.status == "creator"
        let isChannel = chatType == "channel"
        // In supergroups admins can always post; channels expose an explicit flag.
        canPost = isAdmin && (isChannel ? (member.canPostMessages ?? false) : true)
        canDelete = isAdmin && (member.canDeleteMessages ?? false)
        // Channel admins pin via can_edit_messages; supergroups expose can_pin_messages.
        canPin = isAdmin && (member.canPinMessages ?? (isChannel ? (member.canEditMessages ?? false) : false))
        canEdit = isAdmin && (isChannel ? (member.canEditMessages ?? false) : true)
    }
}
