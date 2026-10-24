import Foundation

enum HFUTCASLoginSupport {
    static let messageName = "campusAICaptcha"

    static func isCASHost(_ url: URL?) -> Bool {
        url?.host?.lowercased() == "cas.hfut.edu.cn"
    }

    static func isLoginPage(_ url: URL?) -> Bool {
        guard let url = url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return components.scheme?.lowercased() == "https"
            && isCASHost(url)
            && components.path == "/cas/login"
    }

    static func isEamsLoginPage(_ url: URL?) -> Bool {
        guard let url,
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "jxglstu.hfut.edu.cn" else { return false }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        return path == "eams5-student/neusoft-sso/login"
    }

    static func tgcCookieValue(from cookies: [HTTPCookie], now: Date = Date()) -> String? {
        let casCookies = cookies.filter { cookie in
            let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let name = cookie.name.uppercased()
            let isCASDomain = domain == "cas.hfut.edu.cn" || domain == "hfut.edu.cn"
            let isTicketCookie = name == "CASTGC" || name == "TGC"
            let isUnexpired = cookie.expiresDate.map { $0 > now } ?? true
            return isCASDomain && isTicketCookie && isUnexpired && !cookie.value.isEmpty
        }
        return casCookies.first(where: { $0.name.caseInsensitiveCompare("CASTGC") == .orderedSame })?.value
            ?? casCookies.first(where: { $0.name.caseInsensitiveCompare("TGC") == .orderedSame })?.value
    }

    static func credentialsLiteral(username: String, password: String, captcha: String) -> String? {
        let values = [username, password, captcha]
        guard let data = try? JSONSerialization.data(withJSONObject: values, options: [.fragmentsAllowed]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func submitScript(username: String, password: String, captcha: String) -> String? {
        guard let values = credentialsLiteral(username: username, password: password, captcha: captcha) else {
            return nil
        }
        return #"""
        (() => {
          const values = \#(values);
          const find = window.__hfutCampusAICasFindControls;
          const controls = typeof find === 'function' ? find() : null;
          if (!controls || !controls.username || !controls.password || !controls.code || !controls.submit) return false;
          const setValue = (element, value) => {
            const prototype = Object.getPrototypeOf(element);
            const descriptor = Object.getOwnPropertyDescriptor(prototype, 'value');
            if (descriptor && descriptor.set) descriptor.set.call(element, value);
            else element.value = value;
            element.dispatchEvent(new Event('input', { bubbles: true }));
            element.dispatchEvent(new Event('change', { bubbles: true }));
          };
          setValue(controls.username, values[0]);
          setValue(controls.password, values[1]);
          setValue(controls.code, values[2]);
          controls.submit.click();
          return true;
        })()
        """#
    }

    static func captchaImageData(from dataURL: String?) -> Data? {
        guard let dataURL = dataURL, dataURL.utf8.count <= 700_000,
              let separator = dataURL.range(of: ";base64,"),
              dataURL[..<separator.lowerBound].lowercased() == "data:image/png"
                || dataURL[..<separator.lowerBound].lowercased() == "data:image/jpeg"
                || dataURL[..<separator.lowerBound].lowercased() == "data:image/gif" else { return nil }
        let encoded = String(dataURL[separator.upperBound...])
        guard let data = Data(base64Encoded: encoded), !data.isEmpty, data.count <= 512_000 else { return nil }
        return data
    }

    static let probeScript = #"""
    (() => {
      const visible = element => !!element && element.getClientRects().length > 0
        && getComputedStyle(element).display !== 'none'
        && getComputedStyle(element).visibility !== 'hidden';
      const captchaHint = /captcha|verify|validate|check.?code|random.?code|vercode|验证码|校验码|codeimg/i;
      const codeHint = /captcha|verify|validate|check.?code|random.?code|vercode|验证码|校验码/i;
      const genericCodeHint = /code/i;
      const excludedHint = /sms|mobile|phone|短信|动态码|otp|手机号/i;
      const fieldHint = element => [element.id, element.name, element.placeholder,
        element.getAttribute('aria-label'), ...(element.labels ? Array.from(element.labels).map(label => label.textContent || '') : [])]
        .join(' ');
      const textInputs = form => Array.from(form.querySelectorAll('input')).filter(element => {
        const type = (element.type || 'text').toLowerCase();
        return visible(element) && ['text', 'tel', 'number', ''].includes(type);
      });
      const findControls = () => {
        for (const form of Array.from(document.forms)) {
          const username = Array.from(form.querySelectorAll('#username, #u, input[name="username"], input[name="userName"]'))
            .find(visible);
          const password = Array.from(form.querySelectorAll('#pwd, input.password, input[name="password"], input[type="password"]'))
            .find(visible);
          if (!visible(username) || !visible(password)) continue;

          const candidates = textInputs(form).filter(element => element !== username && !excludedHint.test(fieldHint(element)));
          let code = candidates.find(element => codeHint.test(fieldHint(element)));
          const images = Array.from(form.querySelectorAll('img')).filter(visible);
          const isCaptchaImage = image => {
            let path = '';
            try { path = new URL(image.currentSrc || image.src, location.href).pathname; } catch (_) {}
            const nearbyText = image.parentElement ? (image.parentElement.innerText || '') : '';
            return captchaHint.test([image.id, image.alt, image.className, path, nearbyText].join(' '));
          };
          let image = images.find(isCaptchaImage);

          if (!code && image) {
            let ancestor = image.parentElement;
            for (let depth = 0; ancestor && ancestor !== form && depth < 4 && !code; depth += 1, ancestor = ancestor.parentElement) {
              const local = candidates.filter(element => ancestor.contains(element));
              if (local.length === 1) code = local[0];
            }
          }
          if (!image && code) {
            image = images.find(candidate => {
              let ancestor = candidate.parentElement;
              for (let depth = 0; ancestor && ancestor !== form && depth < 4; depth += 1, ancestor = ancestor.parentElement) {
                if (ancestor.contains(code)) return true;
              }
              return false;
            });
          }
          if (!image && !code) {
            const genericCode = candidates.find(element => genericCodeHint.test(fieldHint(element)));
            if (genericCode) {
              let ancestor = genericCode.parentElement;
              for (let depth = 0; ancestor && ancestor !== form && depth < 4 && !image; depth += 1, ancestor = ancestor.parentElement) {
                const localImages = images.filter(candidate => ancestor.contains(candidate));
                if (localImages.length === 1) {
                  code = genericCode;
                  image = localImages[0];
                }
              }
            }
          }
          if (!code || !image) continue;

          const buttons = Array.from(form.querySelectorAll('button, input[type="submit"], input[type="button"], [role="button"]'))
            .filter(visible)
            .filter(element => !excludedHint.test(fieldHint(element) + ' ' + (element.innerText || element.value || '')));
          const submit = buttons.find(element => element.type === 'submit'
            || element.id === 'sb2' || element.classList.contains('button-submit')
            || /登录|login|submit/i.test(fieldHint(element) + ' ' + (element.innerText || element.value || '')));
          if (!submit) continue;

          const refreshCandidates = Array.from(form.querySelectorAll('button, a, [role="button"], [onclick]'))
            .filter(visible);
          const refresh = refreshCandidates.find(element => /刷新|换一张|更换|refresh|reload/i
            .test(fieldHint(element) + ' ' + (element.innerText || '')))
            || image.closest('a, button, [role="button"]')
            || (typeof image.onclick === 'function' || image.hasAttribute('onclick') ? image : null);
          return { form, username, password, code, image, submit, refresh };
        }
        return null;
      };

      window.__hfutCampusAICasFindControls = findControls;
      const sendEvent = (event, username = '') => {
        try {
          if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.campusAICaptcha) {
            window.webkit.messageHandlers.campusAICaptcha.postMessage({ event, username });
          }
        } catch (_) {}
      };

      if (!window.__hfutCampusAICasObserverInstalled && document.documentElement) {
        window.__hfutCampusAICasObserverInstalled = true;
        let previousSignature = null;
        const watchedImages = new WeakSet();
        const watchedForms = new WeakSet();
        const inspect = () => {
          const controls = findControls();
          const signature = controls ? [controls.username.id, controls.username.name,
            controls.password.id, controls.code.id, controls.code.name,
            controls.image.id, controls.image.getAttribute('src'), visible(controls.username), visible(controls.password)].join('|') : 'none';
          if (signature !== previousSignature) {
            previousSignature = signature;
            sendEvent('formChanged');
          }
          if (controls && !watchedImages.has(controls.image)) {
            watchedImages.add(controls.image);
            controls.image.addEventListener('load', () => sendEvent('captchaChanged'));
          }
          for (const form of Array.from(document.forms)) {
            if (watchedForms.has(form)) continue;
            const username = Array.from(form.querySelectorAll('#username, #u, input[name="username"], input[name="userName"]'))
              .find(visible);
            if (!username) continue;
            watchedForms.add(form);
            const reportLoginSubmission = () => {
              const currentUsername = Array.from(form.querySelectorAll('#username, #u, input[name="username"], input[name="userName"]'))
                .find(visible) || username;
              sendEvent('loginSubmitting', currentUsername.value.trim());
            };
            form.addEventListener('submit', reportLoginSubmission, true);
            const submit = Array.from(form.querySelectorAll('button, input[type="submit"], input[type="button"], [role="button"]'))
              .filter(visible)
              .find(element => element.type === 'submit' || element.id === 'sb2'
                || element.classList.contains('button-submit')
                || /登录|login|submit/i.test([element.id, element.name, element.innerText, element.value].join(' ')));
            if (submit) submit.addEventListener('click', reportLoginSubmission, true);
          }
        };
        new MutationObserver(inspect).observe(document.documentElement, {
          subtree: true, childList: true, attributes: true,
          attributeFilter: ['class', 'style', 'hidden', 'src']
        });
        inspect();
      }

      const controls = findControls();
      if (!controls) return { ready: false };
      let captchaDataURL = null;
      let captureFailed = false;
      const image = controls.image;
      if (image.complete && image.naturalWidth > 0 && image.naturalHeight > 0) {
        try {
          const canvas = document.createElement('canvas');
          canvas.width = image.naturalWidth;
          canvas.height = image.naturalHeight;
          canvas.getContext('2d').drawImage(image, 0, 0);
          captchaDataURL = canvas.toDataURL('image/png');
        } catch (_) { captureFailed = true; }
      }
      return { ready: true, captchaDataURL, captureFailed };
    })()
    """#

    static let refreshCaptchaScript = #"""
    (() => {
      const find = window.__hfutCampusAICasFindControls;
      const controls = typeof find === 'function' ? find() : null;
      if (!controls || !controls.refresh || typeof controls.refresh.click !== 'function') return false;
      controls.refresh.click();
      return true;
    })()
    """#
}
