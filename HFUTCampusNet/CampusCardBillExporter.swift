import Foundation

public enum CampusCardBillDirectionFilter: Int, CaseIterable {
    case all = 0
    case expenseOnly = 1
    case incomeAndRefund = 2
    case rechargeOnly = 3

    public var displayName: String {
        switch self {
        case .all: return "全部"
        case .expenseOnly: return "支出"
        case .incomeAndRefund: return "收入与退款"
        case .rechargeOnly: return "圈存充值"
        }
    }
}

public enum CampusCardBillExportFormat: Int, CaseIterable {
    case wechatCSV = 0
    case standardCSV = 1
    case json = 2

    public var displayName: String {
        switch self {
        case .wechatCSV: return "微信账单兼容格式 (.csv)"
        case .standardCSV: return "通用详细账单 (.csv)"
        case .json: return "JSON 数据 (.json)"
        }
    }

    public var fileExtension: String {
        switch self {
        case .wechatCSV, .standardCSV: return "csv"
        case .json: return "json"
        }
    }

    public var filenameTag: String {
        switch self {
        case .wechatCSV: return "微信兼容"
        case .standardCSV: return "详细明细"
        case .json: return "JSON"
        }
    }
}

public struct CampusCardBillFilter: Equatable {
    public var startDateString: String?
    public var endDateString: String?
    public var merchantKeyword: String
    public var sceneTag: String?
    public var direction: CampusCardBillDirectionFilter

    public init(
        startDateString: String? = nil,
        endDateString: String? = nil,
        merchantKeyword: String = "",
        sceneTag: String? = nil,
        direction: CampusCardBillDirectionFilter = .all
    ) {
        self.startDateString = startDateString
        self.endDateString = endDateString
        self.merchantKeyword = merchantKeyword
        self.sceneTag = sceneTag
        self.direction = direction
    }

    public func matches(_ tx: CampusCardTransaction) -> Bool {
        let txDate = tx.dateOnlyString
        if let start = startDateString, !start.isEmpty, txDate < start {
            return false
        }
        if let end = endDateString, !end.isEmpty, txDate > end {
            return false
        }

        if let tag = sceneTag, !tag.isEmpty, tag != "全部分类" {
            if tx.sceneCategoryTag != tag {
                return false
            }
        }

        switch direction {
        case .all:
            break
        case .expenseOnly:
            if !tx.isExpense { return false }
        case .incomeAndRefund:
            if !tx.isRefund && !tx.isRecharge { return false }
        case .rechargeOnly:
            if !tx.isRecharge { return false }
        }

        let keyword = merchantKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        if !keyword.isEmpty {
            let candidates = [
                tx.cleanMerchantName,
                tx.merchantName,
                tx.turnoverType,
                tx.sceneCategoryTag,
                tx.id
            ]
            if !candidates.contains(where: { $0.localizedCaseInsensitiveContains(keyword) }) {
                return false
            }
        }

        return true
    }

    public func apply(to transactions: [CampusCardTransaction]) -> [CampusCardTransaction] {
        transactions
            .filter { matches($0) }
            .sorted { $0.dateTimeString > $1.dateTimeString }
    }
}

public struct CampusCardBillExportOptions {
    public var format: CampusCardBillExportFormat
    public var treatRechargeAsNeutral: Bool
    public var exportDate: Date

    public init(
        format: CampusCardBillExportFormat = .wechatCSV,
        treatRechargeAsNeutral: Bool = true,
        exportDate: Date = Date()
    ) {
        self.format = format
        self.treatRechargeAsNeutral = treatRechargeAsNeutral
        self.exportDate = exportDate
    }
}

public struct CampusCardBillSummary: Equatable {
    public let count: Int
    public let expenseCount: Int
    public let expenseRMB: Double
    public let incomeCount: Int
    public let incomeRMB: Double
    public let neutralCount: Int
    public let neutralRMB: Double
}

private struct CampusCardBillJSONPayload: Codable {
    let exportedAt: String
    let cardAccount: String
    let holderName: String
    let count: Int
    let transactions: [CampusCardTransaction]
}

public enum CampusCardBillExporter {
    private static let exportTimestampFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return df
    }()

    private static let filenameDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyyMMdd"
        return df
    }()

    public static func dateString(from date: Date) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        return df.string(from: date)
    }

    public static func availableSceneTags(from transactions: [CampusCardTransaction]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for tx in transactions {
            let tag = tx.sceneCategoryTag
            if !seen.contains(tag) {
                seen.insert(tag)
                result.append(tag)
            }
        }
        return result.sorted()
    }

    public static func summarize(
        _ transactions: [CampusCardTransaction],
        treatRechargeAsNeutral: Bool = true
    ) -> CampusCardBillSummary {
        var expenseCount = 0
        var expenseRMB = 0.0
        var incomeCount = 0
        var incomeRMB = 0.0
        var neutralCount = 0
        var neutralRMB = 0.0

        for tx in transactions {
            let amount = abs(tx.amountRMB)
            switch wechatDirection(for: tx, treatRechargeAsNeutral: treatRechargeAsNeutral) {
            case "支出":
                expenseCount += 1
                expenseRMB += amount
            case "收入":
                incomeCount += 1
                incomeRMB += amount
            default:
                neutralCount += 1
                neutralRMB += amount
            }
        }

        return CampusCardBillSummary(
            count: transactions.count,
            expenseCount: expenseCount,
            expenseRMB: expenseRMB,
            incomeCount: incomeCount,
            incomeRMB: incomeRMB,
            neutralCount: neutralCount,
            neutralRMB: neutralRMB
        )
    }

    public static func suggestedFilename(
        format: CampusCardBillExportFormat,
        filter: CampusCardBillFilter,
        date: Date = Date()
    ) -> String {
        let stamp = filenameDateFormatter.string(from: date)
        let keyword = filter.merchantKeyword
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        if keyword.isEmpty {
            return "校园一卡通账单_\(format.filenameTag)_\(stamp).\(format.fileExtension)"
        }
        return "校园一卡通账单_\(format.filenameTag)_\(keyword)_\(stamp).\(format.fileExtension)"
    }

    public static func exportData(
        transactions: [CampusCardTransaction],
        cardData: CampusCardData?,
        filter: CampusCardBillFilter = CampusCardBillFilter(),
        options: CampusCardBillExportOptions = CampusCardBillExportOptions()
    ) -> Data {
        let text = exportString(
            transactions: transactions,
            cardData: cardData,
            filter: filter,
            options: options
        )
        switch options.format {
        case .wechatCSV, .standardCSV:
            // UTF-8 BOM 确保 Excel / Numbers / 记账软件直接打开无中文乱码
            let bom = "\u{FEFF}"
            return Data((bom + text).utf8)
        case .json:
            return Data(text.utf8)
        }
    }

    public static func exportString(
        transactions: [CampusCardTransaction],
        cardData: CampusCardData?,
        filter: CampusCardBillFilter = CampusCardBillFilter(),
        options: CampusCardBillExportOptions = CampusCardBillExportOptions()
    ) -> String {
        let filtered = filter.apply(to: transactions)
        switch options.format {
        case .wechatCSV:
            return buildWeChatCSV(
                transactions: filtered,
                cardData: cardData,
                filter: filter,
                options: options
            )
        case .standardCSV:
            return buildStandardCSV(
                transactions: filtered,
                treatRechargeAsNeutral: options.treatRechargeAsNeutral
            )
        case .json:
            return buildJSON(
                transactions: filtered,
                cardData: cardData,
                exportDate: options.exportDate
            )
        }
    }

    private static func wechatDirection(
        for tx: CampusCardTransaction,
        treatRechargeAsNeutral: Bool
    ) -> String {
        if tx.isRefund {
            return "收入"
        }
        if tx.isRecharge {
            return treatRechargeAsNeutral ? "不计收支" : "收入"
        }
        return "支出"
    }

    private static func wechatStatus(for tx: CampusCardTransaction) -> String {
        if tx.isRefund {
            return "已退款"
        }
        if tx.isRecharge {
            return "已存入"
        }
        return "支付成功"
    }

    private static func buildWeChatCSV(
        transactions: [CampusCardTransaction],
        cardData: CampusCardData?,
        filter: CampusCardBillFilter,
        options: CampusCardBillExportOptions
    ) -> String {
        let summary = summarize(transactions, treatRechargeAsNeutral: options.treatRechargeAsNeutral)
        let holderPart: String
        if let card = cardData {
            let name = card.holderName.isEmpty ? "校园卡用户" : card.holderName
            holderPart = card.cardAccount.isEmpty ? "一卡通 · \(name)" : "一卡通 · \(name)(\(card.cardAccount))"
        } else {
            holderPart = "校园一卡通"
        }

        let today = dateString(from: options.exportDate)
        let minDate = transactions.map(\.dateOnlyString).min() ?? today
        let maxDate = transactions.map(\.dateOnlyString).max() ?? today
        let startStr = (filter.startDateString?.isEmpty == false) ? filter.startDateString! : minDate
        let endStr = (filter.endDateString?.isEmpty == false) ? filter.endDateString! : maxDate
        let exportTimeStr = exportTimestampFormatter.string(from: options.exportDate)

        var lines: [String] = [
            "微信支付账单明细,,,,,,,,",
            "微信昵称：[\(holderPart)],,,,,,,,",
            "起始时间：[\(startStr) 00:00:00] 终止时间：[\(endStr) 23:59:59],,,,,,,,",
            "导出类型：[\(filter.direction.displayName)],,,,,,,,",
            "导出时间：[\(exportTimeStr)],,,,,,,,",
            "共\(summary.count)笔记录,,,,,,,,",
            String(format: "支出：%d笔 %.2f元,,,,,,,,", summary.expenseCount, summary.expenseRMB),
            String(format: "收入：%d笔 %.2f元,,,,,,,,", summary.incomeCount, summary.incomeRMB),
            String(format: "中性交易：%d笔 %.2f元,,,,,,,,", summary.neutralCount, summary.neutralRMB),
            "注：由 HFUT校园网助手 导出（兼容微信账单格式）,,,,,,,,",
            "----------------------微信支付账单明细列表--------------------,,,,,,,,",
            "交易时间,交易类型,交易对方,商品,收/支,金额(元),支付方式,当前状态,交易单号,商户单号,备注"
        ]

        let paymentMethod: String
        if let acc = cardData?.cardAccount, !acc.isEmpty {
            paymentMethod = "校园一卡通(\(acc))"
        } else {
            paymentMethod = "校园一卡通"
        }

        for tx in transactions {
            let typeText = tx.turnoverType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "商户消费"
                : tx.turnoverType
            let counterparty = tx.cleanMerchantName
            let product = tx.sceneCategoryTag
            let direction = wechatDirection(for: tx, treatRechargeAsNeutral: options.treatRechargeAsNeutral)
            let amountText = String(format: "¥%.2f", abs(tx.amountRMB))
            let status = wechatStatus(for: tx)
            let note: String
            if let balance = tx.balanceAfterRMB {
                note = String(format: "余额 ¥%.2f | %@", balance, tx.merchantName)
            } else {
                note = tx.merchantName.isEmpty ? "/" : tx.merchantName
            }

            let row = [
                tx.dateTimeString,
                typeText,
                counterparty,
                product,
                direction,
                amountText,
                paymentMethod,
                status,
                tx.id,
                "/",
                note
            ].map(csvEscape).joined(separator: ",")
            lines.append(row)
        }

        return lines.joined(separator: "\r\n")
    }

    private static func buildStandardCSV(
        transactions: [CampusCardTransaction],
        treatRechargeAsNeutral: Bool
    ) -> String {
        var lines: [String] = [
            "交易时间,订单号,交易类型,消费场景,商户名称,原始摘要,收支方向,金额(元),交易后余额(元)"
        ]

        for tx in transactions {
            let direction = wechatDirection(for: tx, treatRechargeAsNeutral: treatRechargeAsNeutral)
            let amountText = String(format: "%.2f", abs(tx.amountRMB))
            let balanceText = tx.balanceAfterRMB.map { String(format: "%.2f", $0) } ?? ""
            let row = [
                tx.dateTimeString,
                tx.id,
                tx.turnoverType,
                tx.sceneCategoryTag,
                tx.cleanMerchantName,
                tx.merchantName,
                direction,
                amountText,
                balanceText
            ].map(csvEscape).joined(separator: ",")
            lines.append(row)
        }

        return lines.joined(separator: "\r\n")
    }

    private static func buildJSON(
        transactions: [CampusCardTransaction],
        cardData: CampusCardData?,
        exportDate: Date
    ) -> String {
        let payload = CampusCardBillJSONPayload(
            exportedAt: exportTimestampFormatter.string(from: exportDate),
            cardAccount: cardData?.cardAccount ?? "",
            holderName: cardData?.holderName ?? "",
            count: transactions.count,
            transactions: transactions
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(payload),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }

    private static func csvEscape(_ value: String) -> String {
        let needsQuotes = value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r")
        guard needsQuotes else { return value }
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }
}
