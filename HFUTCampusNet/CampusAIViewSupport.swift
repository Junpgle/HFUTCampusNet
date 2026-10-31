import AppKit

enum CampusAIInputActionSource {
    case keyboardReturn
    case sendButton
}

enum CampusAIInputActionDecision: Equatable {
    case submit
    case cancel
    case ignore
}

enum CampusAIInputActionPolicy {
    static func decision(for source: CampusAIInputActionSource, isSending: Bool) -> CampusAIInputActionDecision {
        switch (source, isSending) {
        case (.keyboardReturn, false), (.sendButton, false):
            return .submit
        case (.keyboardReturn, true):
            return .ignore
        case (.sendButton, true):
            return .cancel
        }
    }
}

enum CampusAITranscriptStyle {
    static func attributedString(_ string: String, font: NSFont) -> NSAttributedString {
        NSAttributedString(
            string: string,
            attributes: [
                .font: font,
                .foregroundColor: NSColor.labelColor
            ]
        )
    }

    /// 净化流式返回中的系统占位符、时间戳与标签残片
    static func sanitize(_ text: String) -> String {
        var result = text
        // 清理 <timestamp>...</timestamp> 标签及其内容
        if let regex = try? NSRegularExpression(pattern: "<timestamp>[\\s\\S]*?</timestamp>", options: .caseInsensitive) {
            result = regex.stringByReplacingMatches(in: result, range: NSRange(location: 0, length: (result as NSString).length), withTemplate: "")
        }
        // 清理 @@@CurrentTime / @@CurrentTime 占位符
        if let regex = try? NSRegularExpression(pattern: "@@+CurrentTime", options: .caseInsensitive) {
            result = regex.stringByReplacingMatches(in: result, range: NSRange(location: 0, length: (result as NSString).length), withTemplate: "")
        }
        // 清理残留的思考标签碎片如 nk</thi nk>, </thi nk>, <think>, </think>, <thi nk>
        if let regex = try? NSRegularExpression(pattern: "(?:nk)?</?thi\\s*nk>|/thi\\s*nk>|/think>", options: .caseInsensitive) {
            result = regex.stringByReplacingMatches(in: result, range: NSRange(location: 0, length: (result as NSString).length), withTemplate: "")
        }
        if let regex = try? NSRegularExpression(pattern: "</?think>", options: .caseInsensitive) {
            result = regex.stringByReplacingMatches(in: result, range: NSRange(location: 0, length: (result as NSString).length), withTemplate: "")
        }
        return result
    }

    /// 将 Markdown 解析为结构清晰、保留换行、支持列表与加粗的富文本
    static func markdownAttributedString(_ markdown: String, font: NSFont, isThinking: Bool = false) -> NSAttributedString {
        guard !markdown.isEmpty else { return NSAttributedString() }
        let cleanText = isThinking ? sanitize(markdown) : markdown
        let result = NSMutableAttributedString()

        let baseFontSize = isThinking ? max(11.0, font.pointSize - 1.0) : font.pointSize
        let bodyFont = NSFont.systemFont(ofSize: baseFontSize)
        let boldFont = NSFont.boldSystemFont(ofSize: baseFontSize)
        let headingFont = NSFont.systemFont(ofSize: baseFontSize + 1.5, weight: .semibold)
        let codeFont = NSFont.monospacedSystemFont(ofSize: max(11.0, baseFontSize - 1.0), weight: .regular)

        let foregroundColor: NSColor = isThinking ? .secondaryLabelColor : .labelColor

        let bodyPara = NSMutableParagraphStyle()
        bodyPara.lineSpacing = isThinking ? 1.5 : 3.0
        bodyPara.paragraphSpacing = isThinking ? 3.0 : 6.0
        if isThinking {
            bodyPara.headIndent = 12
            bodyPara.firstLineHeadIndent = 12
        }

        let headingPara = NSMutableParagraphStyle()
        headingPara.lineSpacing = 2.0
        headingPara.paragraphSpacing = 6.0
        headingPara.paragraphSpacingBefore = 8.0

        let listPara = NSMutableParagraphStyle()
        listPara.lineSpacing = isThinking ? 1.5 : 3.0
        listPara.paragraphSpacing = isThinking ? 2.0 : 4.0
        listPara.headIndent = isThinking ? 24 : 18
        listPara.firstLineHeadIndent = isThinking ? 12 : 0

        func appendInline(_ text: String, base: NSFont, para: NSParagraphStyle) {
            let pattern = "(\\*\\*[^*]+\\*\\*|`[^`]+`|\\[[^\\]]+\\]\\(https?://[^\\s\\)]+\\))"
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                result.append(NSAttributedString(string: text, attributes: [
                    .font: base, .foregroundColor: foregroundColor, .paragraphStyle: para
                ]))
                return
            }
            let ns = text as NSString
            let full = NSRange(location: 0, length: ns.length)
            var lastEnd = 0
            for match in regex.matches(in: text, range: full) {
                if match.range.location > lastEnd {
                    let plain = ns.substring(with: NSRange(location: lastEnd, length: match.range.location - lastEnd))
                    result.append(NSAttributedString(string: plain, attributes: [
                        .font: base, .foregroundColor: foregroundColor, .paragraphStyle: para
                    ]))
                }
                let token = ns.substring(with: match.range)
                if token.hasPrefix("**") && token.count >= 4 {
                    let inner = String(token.dropFirst(2).dropLast(2))
                    result.append(NSAttributedString(string: inner, attributes: [
                        .font: boldFont, .foregroundColor: foregroundColor, .paragraphStyle: para
                    ]))
                } else if token.hasPrefix("`") && token.count >= 2 {
                    let inner = String(token.dropFirst().dropLast())
                    result.append(NSAttributedString(string: inner, attributes: [
                        .font: codeFont, .foregroundColor: foregroundColor, .paragraphStyle: para
                    ]))
                } else if token.hasPrefix("["),
                          let openRange = token.range(of: "]("),
                          let closeRange = token.range(of: ")") {
                    let linkText = String(token[token.index(token.startIndex, offsetBy: 1)..<openRange.lowerBound])
                    let urlStr = String(token[openRange.upperBound..<closeRange.lowerBound])
                    result.append(NSAttributedString(string: linkText, attributes: [
                        .font: base,
                        .foregroundColor: NSColor.linkColor,
                        .underlineStyle: NSUnderlineStyle.single.rawValue,
                        .link: URL(string: urlStr) as Any,
                        .paragraphStyle: para
                    ]))
                }
                lastEnd = match.range.location + match.range.length
            }
            if lastEnd < ns.length {
                let plain = ns.substring(from: lastEnd)
                result.append(NSAttributedString(string: plain, attributes: [
                    .font: base, .foregroundColor: foregroundColor, .paragraphStyle: para
                ]))
            }
        }

        let lines = cleanText.components(separatedBy: .newlines)
        for (index, rawLine) in lines.enumerated() {
            let isLastLine = index == lines.count - 1
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.isEmpty {
                result.append(NSAttributedString(string: "\n", attributes: [
                    .font: bodyFont, .paragraphStyle: bodyPara
                ]))
                continue
            }

            if line.hasPrefix("---") || line.hasPrefix("***") || line.hasPrefix("___") {
                let sep = String(repeating: "─", count: 36)
                result.append(NSAttributedString(string: sep + "\n", attributes: [
                    .font: bodyFont, .foregroundColor: NSColor.separatorColor, .paragraphStyle: bodyPara
                ]))
                continue
            }

            if let hashRange = line.range(of: "^#{1,6}\\s+", options: .regularExpression) {
                let text = String(line[hashRange.upperBound...])
                appendInline(text, base: headingFont, para: headingPara)
                if !isLastLine {
                    result.append(NSAttributedString(string: "\n", attributes: [
                        .font: headingFont, .paragraphStyle: headingPara
                    ]))
                }
                continue
            }

            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                result.append(NSAttributedString(string: "• ", attributes: [
                    .font: bodyFont, .foregroundColor: foregroundColor, .paragraphStyle: listPara
                ]))
                appendInline(String(line.dropFirst(2)), base: bodyFont, para: listPara)
                if !isLastLine {
                    result.append(NSAttributedString(string: "\n", attributes: [
                        .font: bodyFont, .paragraphStyle: listPara
                    ]))
                }
                continue
            }

            if let numMatch = line.range(of: "^\\d+\\.\\s+", options: .regularExpression) {
                let numPrefix = String(line[..<numMatch.upperBound])
                let rest = String(line[numMatch.upperBound...])
                result.append(NSAttributedString(string: numPrefix, attributes: [
                    .font: bodyFont, .foregroundColor: foregroundColor, .paragraphStyle: listPara
                ]))
                appendInline(rest, base: bodyFont, para: listPara)
                if !isLastLine {
                    result.append(NSAttributedString(string: "\n", attributes: [
                        .font: bodyFont, .paragraphStyle: listPara
                    ]))
                }
                continue
            }

            if line.hasPrefix("> ") {
                let quoteText = String(line.dropFirst(2))
                result.append(NSAttributedString(string: "▎ ", attributes: [
                    .font: bodyFont, .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: bodyPara
                ]))
                appendInline(quoteText, base: bodyFont, para: bodyPara)
                if !isLastLine {
                    result.append(NSAttributedString(string: "\n", attributes: [
                        .font: bodyFont, .paragraphStyle: bodyPara
                    ]))
                }
                continue
            }

            appendInline(line, base: bodyFont, para: bodyPara)
            if !isLastLine {
                result.append(NSAttributedString(string: "\n", attributes: [
                    .font: bodyFont, .paragraphStyle: bodyPara
                ]))
            }
        }

        return result
    }

    /// 用户提问富文本块
    static func userBlock(question: String, attachments: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let titlePara = NSMutableParagraphStyle()
        titlePara.paragraphSpacing = 4
        titlePara.paragraphSpacingBefore = 12

        let contentPara = NSMutableParagraphStyle()
        contentPara.lineSpacing = 3
        contentPara.paragraphSpacing = 10

        result.append(NSAttributedString(string: "\n👤 你\n", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .bold),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: titlePara
        ]))

        let suffix = attachments.isEmpty ? "" : "\n📎 附件：\(attachments)"
        result.append(NSAttributedString(string: "\(question)\(suffix)\n\n", attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: contentPara
        ]))
        return result
    }

    /// 思考过程头部
    static func thinkingHeader() -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.paragraphSpacing = 4
        para.paragraphSpacingBefore = 8
        return NSAttributedString(string: "💭 思考过程\n", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: para
        ])
    }

    /// 思考过程结束标线
    static func thinkingFooter() -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.paragraphSpacing = 10
        para.paragraphSpacingBefore = 6
        return NSAttributedString(string: "\n💭 思考结束 · 已完成推理\n\n", attributes: [
            .font: NSFont.systemFont(ofSize: 11.5),
            .foregroundColor: NSColor.tertiaryLabelColor,
            .paragraphStyle: para
        ])
    }

    /// 工具调用状态指示
    static func toolCallStatus(result: Bool?) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.paragraphSpacing = 6
        para.paragraphSpacingBefore = 6
        let (icon, text, color): (String, String, NSColor) = {
            switch result {
            case .none:
                return ("⚙️", "正在调用智能体工具…", .systemOrange)
            case .some(true):
                return ("✓", "工具调用完成", .systemGreen)
            case .some(false):
                return ("✕", "工具调用未完成", .systemRed)
            }
        }()
        return NSAttributedString(string: "\(icon) [工具调用] \(text)\n\n", attributes: [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
            .foregroundColor: color,
            .paragraphStyle: para
        ])
    }

    /// 正式回复头部
    static func assistantHeader() -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.paragraphSpacing = 6
        para.paragraphSpacingBefore = 8
        return NSAttributedString(string: "🤖 合工大 AI 辅导员\n\n", attributes: [
            .font: NSFont.systemFont(ofSize: 13.5, weight: .bold),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: para
        ])
    }
}

enum CampusAIEntryNavigationStep: String, Equatable {
    case clickPortalAIPlatform
    case clickAIPlaza
    case clickCampusAdvisor
}

enum CampusAIEntryNavigation {
    static func step(for url: URL?, agentID: String) -> CampusAIEntryNavigationStep? {
        guard CampusAIEndpoint.validID(agentID),
              let url = url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.user == nil, components.password == nil,
              components.port == nil || components.port == 443,
              let host = components.host?.lowercased() else { return nil }

        switch host {
        case "one.hfut.edu.cn" where components.path == "/" || components.path == "/home/index":
            return .clickPortalAIPlatform
        case CampusAIEndpoint.host where components.path == "/index/agent":
            return .clickAIPlaza
        case CampusAIEndpoint.host where components.path == "/index"
            && agentID == CampusAIEndpoint.defaultAgentID:
            return .clickCampusAdvisor
        default:
            return nil
        }
    }

    static func script(for step: CampusAIEntryNavigationStep, agentID: String) -> String {
        switch step {
        case .clickPortalAIPlatform:
            return #"""
            (() => {
              const normalize = value => (value || '').replace(/\s+/g, '').trim();
              const visible = element => {
                const rect = element.getBoundingClientRect();
                const style = getComputedStyle(element);
                return rect.width > 0 && rect.height > 0 && style.display !== 'none' && style.visibility !== 'hidden';
              };
              const report = result => {
                const bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.campusAIAutoNavigation;
                if (bridge) bridge.postMessage({event: 'autoNavigation', step: 'portal', result});
              };
              let attempts = 0;
              const timer = window.setInterval(() => {
                attempts += 1;
                const label = [...document.querySelectorAll('p')].find(element => normalize(element.textContent) === 'AI中台' && visible(element));
                if (label) {
                  window.clearInterval(timer);
                  label.click();
                  report('clicked');
                } else if (attempts >= 40) {
                  window.clearInterval(timer);
                  report('missing');
                }
              }, 400);
              return true;
            })()
            """#
        case .clickAIPlaza:
            let script = #"""
            (() => {
              const normalize = value => (value || '').replace(/\s+/g, '').trim();
              const visible = element => {
                const rect = element.getBoundingClientRect();
                const style = getComputedStyle(element);
                return rect.width > 0 && rect.height > 0 && style.display !== 'none' && style.visibility !== 'hidden';
              };
              const findAdvisorLabel = () => {
                const walker = document.createTreeWalker(document.body || document.documentElement, NodeFilter.SHOW_TEXT);
                let node;
                while ((node = walker.nextNode())) {
                  if ((node.nodeValue || '').replace(/\s+/g, '').trim() !== '合工大AI辅导员') continue;
                  const element = node.parentElement;
                  if (element && visible(element)) return element;
                }
                return null;
              };
              const report = result => {
                const bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.campusAIAutoNavigation;
                if (bridge) bridge.postMessage({event: 'autoNavigation', step: 'plaza', result});
              };
              let attempts = 0;
              const timer = window.setInterval(() => {
                attempts += 1;
                const plaza = [...document.querySelectorAll('.menu-item')].find(element => normalize(element.textContent) === '广场' && visible(element));
                if (plaza) {
                  window.clearInterval(timer);
                  plaza.click();
                  let routeAttempts = 0;
                  const routeTimer = window.setInterval(() => {
                    routeAttempts += 1;
                    const url = new URL(window.location.href);
                    if (url.pathname === '/index') {
                      window.clearInterval(routeTimer);
                      if (__CAMPUS_AI_AUTO_OPEN_ADVISOR__) {
                      report('opened');
                      let cardAttempts = 0;
                      const cardTimer = window.setInterval(() => {
                        cardAttempts += 1;
                        const card = findAdvisorLabel();
                        if (card) {
                          window.clearInterval(cardTimer);
                          card.scrollIntoView({block: 'center', inline: 'nearest', behavior: 'auto'});
                          if (!window.__campusAIAutoAdvisorClicking) {
                            window.__campusAIAutoAdvisorClicking = true;
                            card.click();
                            const bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.campusAIAutoNavigation;
                            if (bridge) bridge.postMessage({event: 'autoNavigation', step: 'advisor', result: 'clicked'});
                            let detailAttempts = 0;
                            const detailTimer = window.setInterval(() => {
                              detailAttempts += 1;
                              const detailURL = new URL(window.location.href);
                              if (detailURL.pathname === '/agent-detail' && detailURL.searchParams.get('id') === '__AGENT_ID__') {
                                window.clearInterval(detailTimer);
                                if (bridge) bridge.postMessage({event: 'autoNavigation', step: 'advisor', result: 'opened'});
                              } else if (detailAttempts >= 40) {
                                window.clearInterval(detailTimer);
                                if (bridge) bridge.postMessage({event: 'autoNavigation', step: 'advisor', result: 'open-failed'});
                              }
                            }, 400);
                          }
                        } else if (cardAttempts >= 80) {
                          window.clearInterval(cardTimer);
                          const bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.campusAIAutoNavigation;
                          if (bridge) bridge.postMessage({event: 'autoNavigation', step: 'advisor', result: 'missing'});
                        } else {
                          const roots = [document.scrollingElement, ...document.querySelectorAll('*')];
                          for (const root of roots) {
                            if (!root || root.scrollHeight <= root.clientHeight + 24) continue;
                            const style = getComputedStyle(root);
                            if (style.overflowY === 'hidden' || style.overflowY === 'clip') continue;
                            const step = Math.max(240, root.clientHeight * 0.7);
                            root.scrollTop = Math.min(root.scrollTop + step, root.scrollHeight);
                          }
                          window.scrollBy(0, Math.max(240, window.innerHeight * 0.7));
                        }
                      }, 400);
                      } else {
                        report('manual');
                      }
                    } else if (routeAttempts >= 40) {
                      window.clearInterval(routeTimer);
                      report('missing');
                    }
                  }, 400);
                } else if (attempts >= 40) {
                  window.clearInterval(timer);
                  report('missing');
                }
              }, 400);
              return true;
            })()
            """#
            return script.replacingOccurrences(
                of: "__CAMPUS_AI_AUTO_OPEN_ADVISOR__",
                with: agentID == CampusAIEndpoint.defaultAgentID ? "true" : "false"
            ).replacingOccurrences(of: "__AGENT_ID__", with: agentID)
        case .clickCampusAdvisor:
            return #"""
            (() => {
              const visible = element => {
                const rect = element.getBoundingClientRect();
                const style = getComputedStyle(element);
                return rect.width > 0 && rect.height > 0 && style.display !== 'none' && style.visibility !== 'hidden';
              };
              const findAdvisorLabel = () => {
                const walker = document.createTreeWalker(document.body || document.documentElement, NodeFilter.SHOW_TEXT);
                let node;
                while ((node = walker.nextNode())) {
                  if ((node.nodeValue || '').replace(/\s+/g, '').trim() !== '合工大AI辅导员') continue;
                  const element = node.parentElement;
                  if (element && visible(element)) return element;
                }
                return null;
              };
              const report = result => {
                const bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.campusAIAutoNavigation;
                if (bridge) bridge.postMessage({event: 'autoNavigation', step: 'advisor', result});
              };
              let attempts = 0;
              const timer = window.setInterval(() => {
                attempts += 1;
                const card = findAdvisorLabel();
                if (card) {
                  window.clearInterval(timer);
                  card.scrollIntoView({block: 'center', inline: 'nearest', behavior: 'auto'});
                  if (!window.__campusAIAutoAdvisorClicking) {
                    window.__campusAIAutoAdvisorClicking = true;
                    card.click();
                    report('clicked');
                    let detailAttempts = 0;
                    const detailTimer = window.setInterval(() => {
                      detailAttempts += 1;
                      const detailURL = new URL(window.location.href);
                      if (detailURL.pathname === '/agent-detail' && detailURL.searchParams.get('id') === '__AGENT_ID__') {
                        window.clearInterval(detailTimer);
                        report('opened');
                      } else if (detailAttempts >= 40) {
                        window.clearInterval(detailTimer);
                        report('open-failed');
                      }
                    }, 400);
                  }
                } else if (attempts >= 80) {
                  window.clearInterval(timer);
                  report('missing');
                } else {
                  const roots = [document.scrollingElement, ...document.querySelectorAll('*')];
                  for (const root of roots) {
                    if (!root || root.scrollHeight <= root.clientHeight + 24) continue;
                    const style = getComputedStyle(root);
                    if (style.overflowY === 'hidden' || style.overflowY === 'clip') continue;
                    const step = Math.max(240, root.clientHeight * 0.7);
                    root.scrollTop = Math.min(root.scrollTop + step, root.scrollHeight);
                  }
                  window.scrollBy(0, Math.max(240, window.innerHeight * 0.7));
                }
              }, 400);
              return true;
            })()
            """#.replacingOccurrences(of: "__AGENT_ID__", with: agentID)
        }
    }
}
