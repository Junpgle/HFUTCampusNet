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

    static func markdownAttributedString(_ markdown: String, font: NSFont) -> NSAttributedString {
        guard !markdown.isEmpty,
              let parsed = try? NSAttributedString(
                markdown: markdown,
                options: .init(interpretedSyntax: .full)
              ) else {
            return attributedString(markdown, font: font)
        }

        let result = NSMutableAttributedString(attributedString: parsed)
        let range = NSRange(location: 0, length: result.length)
        result.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range)
        var missingFontRanges: [NSRange] = []
        result.enumerateAttribute(.font, in: range) { value, subrange, _ in
            if value == nil { missingFontRanges.append(subrange) }
        }
        for subrange in missingFontRanges {
            result.addAttribute(.font, value: font, range: subrange)
        }
        return result
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
