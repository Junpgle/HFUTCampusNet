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
            && components.queryItems?.contains(where: { $0.name == "forceIndex" && $0.value == "1" }) == true
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
                    if (url.pathname === '/index' && url.searchParams.get('forceIndex') === '1') {
                      window.clearInterval(routeTimer);
                      if (__CAMPUS_AI_AUTO_OPEN_ADVISOR__) {
                      report('opened');
                      let cardAttempts = 0;
                      const cardTimer = window.setInterval(() => {
                        cardAttempts += 1;
                        const card = [...document.querySelectorAll('.title')].find(element => normalize(element.textContent) === '合工大AI辅导员' && visible(element));
                        if (card) {
                          window.clearInterval(cardTimer);
                          if (!window.__campusAIAutoAdvisorClicking) {
                            window.__campusAIAutoAdvisorClicking = true;
                            card.click();
                            const bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.campusAIAutoNavigation;
                            if (bridge) bridge.postMessage({event: 'autoNavigation', step: 'advisor', result: 'clicked'});
                          }
                        } else if (cardAttempts >= 40) {
                          window.clearInterval(cardTimer);
                          const bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.campusAIAutoNavigation;
                          if (bridge) bridge.postMessage({event: 'autoNavigation', step: 'advisor', result: 'missing'});
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
            )
        case .clickCampusAdvisor:
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
                if (bridge) bridge.postMessage({event: 'autoNavigation', step: 'advisor', result});
              };
              let attempts = 0;
              const timer = window.setInterval(() => {
                attempts += 1;
                const card = [...document.querySelectorAll('.title')].find(element => normalize(element.textContent) === '合工大AI辅导员' && visible(element));
                if (card) {
                  window.clearInterval(timer);
                  if (!window.__campusAIAutoAdvisorClicking) {
                    window.__campusAIAutoAdvisorClicking = true;
                    card.click();
                    report('clicked');
                  }
                } else if (attempts >= 40) {
                  window.clearInterval(timer);
                  report('missing');
                }
              }, 400);
              return true;
            })()
            """#
        }
    }
}
