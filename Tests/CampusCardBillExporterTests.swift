import Foundation

private func assertTrue(_ condition: Bool, _ message: String) {
    if !condition {
        fputs("❌ Assertion failed: \(message)\n", stderr)
        exit(1)
    }
}

private func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    if actual != expected {
        fputs("❌ Assertion failed: \(message)\n   actual:   \(actual)\n   expected: \(expected)\n", stderr)
        exit(1)
    }
}

@main
struct CampusCardBillExporterTests {
    static func main() {
        let sampleTransactions: [CampusCardTransaction] = [
            CampusCardTransaction(
                id: "ORD-001",
                merchantName: "合肥黄山大厦餐饮-持卡人消费",
                amountRMB: 12.50,
                balanceAfterRMB: 187.50,
                turnoverType: "消费",
                dateTimeString: "2026-11-10 12:15:00"
            ),
            CampusCardTransaction(
                id: "ORD-002",
                merchantName: "教育超市,屯溪路店-持卡人消费",
                amountRMB: 8.00,
                balanceAfterRMB: 179.50,
                turnoverType: "消费",
                dateTimeString: "2026-11-12 18:30:00"
            ),
            CampusCardTransaction(
                id: "ORD-003",
                merchantName: "支付宝圈存充值",
                amountRMB: 100.00,
                balanceAfterRMB: 279.50,
                turnoverType: "充值",
                dateTimeString: "2026-11-13 09:00:00"
            ),
            CampusCardTransaction(
                id: "ORD-004",
                merchantName: "食堂窗口退费",
                amountRMB: 5.00,
                balanceAfterRMB: 284.50,
                turnoverType: "退款",
                dateTimeString: "2026-11-14 13:10:00"
            )
        ]

        let cardData = CampusCardData(
            cardAccount: "57919",
            holderName: "张三",
            balanceRMB: 284.50,
            transactions: sampleTransactions
        )

        // 1. 日期筛选
        let dateFilter = CampusCardBillFilter(startDateString: "2026-11-12", endDateString: "2026-11-13")
        let dateMatched = dateFilter.apply(to: sampleTransactions)
        assertEqual(dateMatched.map(\.id), ["ORD-003", "ORD-002"], "Date range filter should match inclusive bounds sorted descending")

        // 2. 商家关键字筛选
        let merchantFilter = CampusCardBillFilter(merchantKeyword: "黄山大厦")
        let merchantMatched = merchantFilter.apply(to: sampleTransactions)
        assertEqual(merchantMatched.map(\.id), ["ORD-001"], "Merchant keyword should match cleanMerchantName")

        // 3. 收支方向筛选
        let expenseFilter = CampusCardBillFilter(direction: .expenseOnly)
        assertEqual(expenseFilter.apply(to: sampleTransactions).map(\.id), ["ORD-002", "ORD-001"], "Expense filter should exclude recharge and refund")

        let incomeFilter = CampusCardBillFilter(direction: .incomeAndRefund)
        assertEqual(incomeFilter.apply(to: sampleTransactions).map(\.id), ["ORD-004", "ORD-003"], "Income/refund filter should include recharge and refund")

        // 4. 场景分类筛选
        let sceneFilter = CampusCardBillFilter(sceneTag: "超市购物")
        assertEqual(sceneFilter.apply(to: sampleTransactions).map(\.id), ["ORD-002"], "Scene tag filter should match 超市购物")

        // 5. 微信账单兼容 CSV 格式验证（圈存记为不计收支）
        let fixedDate = Date(timeIntervalSince1970: 1794715200)
        let wechatData = CampusCardBillExporter.exportData(
            transactions: sampleTransactions,
            cardData: cardData,
            filter: CampusCardBillFilter(),
            options: CampusCardBillExportOptions(format: .wechatCSV, treatRechargeAsNeutral: true, exportDate: fixedDate)
        )
        assertEqual(Array(wechatData.prefix(3)), [0xEF, 0xBB, 0xBF], "WeChat CSV should start with UTF-8 BOM bytes")
        let wechatStr = String(data: wechatData, encoding: .utf8) ?? ""
        assertTrue(wechatStr.contains("微信支付账单明细"), "WeChat CSV should contain WeChat header")
        assertTrue(wechatStr.contains("----------------------微信支付账单明细列表--------------------"), "WeChat CSV should contain list separator")
        assertTrue(wechatStr.contains("交易时间,交易类型,交易对方,商品,收/支,金额(元),支付方式,当前状态,交易单号,商户单号,备注"), "WeChat CSV should contain exact 11-column header")
        assertTrue(wechatStr.contains("支出：2笔 20.50元"), "Summary should sum expenses")
        assertTrue(wechatStr.contains("收入：1笔 5.00元"), "Summary should sum refunds as income")
        assertTrue(wechatStr.contains("中性交易：1笔 100.00元"), "Summary should count recharge as neutral")
        assertTrue(wechatStr.contains("\"教育超市,屯溪路店\""), "CSV fields with commas should be quoted")
        assertTrue(wechatStr.contains("2026-11-13 09:00:00,充值,支付宝圈存充值,圈存充值,不计收支,¥100.00,校园一卡通(57919),已存入,ORD-003,/,"), "Recharge row should match WeChat format")

        // 6. 微信账单兼容 CSV（圈存记为收入）
        let wechatIncomeStr = CampusCardBillExporter.exportString(
            transactions: sampleTransactions,
            cardData: cardData,
            filter: CampusCardBillFilter(),
            options: CampusCardBillExportOptions(format: .wechatCSV, treatRechargeAsNeutral: false, exportDate: fixedDate)
        )
        assertTrue(wechatIncomeStr.contains("收入：2笔 105.00元"), "Recharge as income should add to income summary")
        assertTrue(wechatIncomeStr.contains("中性交易：0笔 0.00元"), "Neutral summary should be 0 when recharge is income")

        // 7. JSON 导出验证
        let jsonStr = CampusCardBillExporter.exportString(
            transactions: sampleTransactions,
            cardData: cardData,
            filter: merchantFilter,
            options: CampusCardBillExportOptions(format: .json, exportDate: fixedDate)
        )
        assertTrue(jsonStr.contains("\"cardAccount\" : \"57919\""), "JSON should include cardAccount")
        assertTrue(jsonStr.contains("\"count\" : 1"), "JSON should include filtered count")
        assertTrue(jsonStr.contains("\"ORD-001\""), "JSON should include matched transaction")

        print("✅ All CampusCardBillExporter tests passed!")
    }
}
