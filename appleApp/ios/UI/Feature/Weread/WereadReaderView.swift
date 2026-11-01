import SwiftUI
import WebKit
import UIKit

/// 要打开的一本书。
struct WereadReaderTarget: Identifiable {
    let id = UUID()
    /// 网页阅读器地址（`/web/reader/<hash>`）。没拿到时是网页书架地址。
    let url: String
    let title: String
    /// 数字 bookId。网页书架的卡片上有 data-book-id，按它点最准。
    let bookId: String
    /// true = 没有阅读器地址，先落到网页书架再自动点开那本书。
    let needsJump: Bool
}

/// 微信读书阅读器（网页版，全屏）。
///
/// 只做一件事：把网页阅读器**原样全屏**铺开。
/// 网页阅读器本来就支持长按选文、划线、写想法、翻页、进度同步，
/// 这些自己用原生重写一遍既做不到那么好，也没必要。
///
/// 关键是地址：网页阅读器要的是 `/web/reader/<hash>` 里那个 hash，
/// 用 `shelf/sync` 的数字 bookId 自己拼一定 404 —— 上一版「点进去白屏」
/// 就是这个原因。hash 由 `WereadStore` 从网页书架的链接里抄下来缓存。
struct WereadReaderView: View {
    let target: WereadReaderTarget

    @Environment(\.dismiss) private var dismiss
    @State private var isLoading = true
    @State private var reloadToken = 0
    @State private var inReader = false
    /// 「正在打开」那层遮罩。最多盖 6 秒就撤，绝不把用户永远挡在外面。
    @State private var showSplash = true

    var body: some View {
        ZStack(alignment: .topTrailing) {
            WereadReaderWebView(
                url: target.url,
                cookie: WereadStore.shared.cookie,
                bookTitle: target.title,
                bookId: target.bookId,
                needsJump: target.needsJump,
                reloadToken: reloadToken,
                isLoading: $isLoading,
                inReader: $inReader
            )
            .ignoresSafeArea()

            if showSplash, !inReader {
                // 只盖一小会儿：6 秒后不管有没有打开都把遮罩撤掉，
                // 让用户看见真实页面，别一直对着「正在打开」发呆。
                ZStack {
                    Color(.systemBackground)
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("正在打开《\(target.title)》…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text("一直在转圈的话，等下会露出网页书架，点封面也能进")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    }
                }
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeOut(duration: 0.2)) { showSplash = false }
                }
            }

            VStack(spacing: 10) {
                floatingButton("xmark", label: "关闭") { dismiss() }
                floatingButton("arrow.clockwise", label: "刷新") { reloadToken += 1 }
            }
            .padding(.trailing, 10)
            .padding(.top, 6)
        }
        .background(Color(.systemBackground))
        .statusBar(hidden: true)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                withAnimation(.easeOut(duration: 0.2)) { showSplash = false }
            }
        }
        .onChange(of: inReader) { value in
            if value {
                withAnimation(.easeOut(duration: 0.2)) { showSplash = false }
            }
        }
    }

    private func floatingButton(
        _ symbol: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Color.black.opacity(0.32))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

private struct WereadReaderWebView: UIViewRepresentable {
    let url: String
    let cookie: String
    let bookTitle: String
    let bookId: String
    let needsJump: Bool
    let reloadToken: Int
    @Binding var isLoading: Bool
    @Binding var inReader: Bool

    /// 让阅读页的文字可以被长按选中。
    ///
    /// 微信读书自己接管了 `touchstart` / `selectstart`，还会给正文容器写
    /// `user-select: none`。CSS 用 `!important` 盖掉，事件在捕获阶段掐断，
    /// 这样系统原生的选择手柄、复制/查询/翻译菜单就能正常出来。
    private static let selectionScript = """
    (function(){
      var styleId = 'flare-select-style';
      var css = 'body, body * { -webkit-user-select: text !important; user-select: text !important; -webkit-touch-callout: default !important; }';
      var pending = false;
      function apply(){
        pending = false;
        try {
          var head = document.head || document.documentElement;
          if (!head) { return; }
          var style = document.getElementById(styleId);
          if (!style) {
            style = document.createElement('style');
            style.id = styleId;
            head.appendChild(style);
          }
          // 只有内容真的变了才写。以前每次都写 textContent，等于每次
          // MutationObserver 回调都再产生一条 mutation，自己触发自己，
          // 主线程被微任务塞满 —— 阅读页就永远画不出来（白屏）。
          if (style.textContent !== css) { style.textContent = css; }
          var inline = document.querySelectorAll('[style*="user-select"]');
          for (var i = 0; i < inline.length && i < 200; i++) {
            var el = inline[i];
            if (el.style.getPropertyValue('-webkit-user-select') !== 'text') {
              el.style.setProperty('-webkit-user-select', 'text', 'important');
              el.style.setProperty('user-select', 'text', 'important');
            }
          }
        } catch (e) {}
      }
      // 节流：阅读页 DOM 变得很勤，每次变更都全量扫一遍会卡。
      function schedule(){
        if (pending) { return; }
        pending = true;
        setTimeout(apply, 500);
      }
      apply();
      document.addEventListener('DOMContentLoaded', schedule, true);
      window.addEventListener('load', schedule, true);
      ['selectstart', 'contextmenu'].forEach(function(name){
        document.addEventListener(name, function(e){ e.stopPropagation(); }, true);
      });
      try {
        var observer = new MutationObserver(schedule);
        observer.observe(document.documentElement, { childList: true, subtree: true });
      } catch (e) {}
    })();
    """

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        // 微信读书的阅读页默认把文字设成不可选（它想自己做划线交互），
        // 结果 WKWebView 里长按既不出选择手柄，也没法写想法。这里强行放开。
        configuration.preferences.isTextInteractionEnabled = true
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: Self.selectionScript,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: false
            )
        )
        let webView = WKWebView(frame: .zero, configuration: configuration)
        // 桌面 UA：手机 UA 下微信读书会把网页换成「打开 App」引导页。
        webView.customUserAgent = WebPlatformUserAgent.desktop
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        context.coordinator.webView = webView
        context.coordinator.load()
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.loadedToken != reloadToken {
            context.coordinator.loadedToken = reloadToken
            context.coordinator.load()
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: WereadReaderWebView
        weak var webView: WKWebView?
        var loadedToken = 0

        private var didAttemptJump = false
        private var jumpAttempts = 0
        /// true = 当前在「网页书架 → 自动点开那本书」的兜底流程里。
        private var jumpMode = false
        /// 阅读器页只校验一次，避免每次翻页都跑一遍。
        private var checkedReader = false
        /// 正文还没画出来时多等几轮，别把「还在加载」当成「打不开」。
        private var verifyAttempts = 0
        /// 正文确认画出来了才写缓存，白屏地址绝不能存。
        private var readerVerified = false
        /// 已经退回过一次网页书架，避免白屏 → 书架 → 白屏 无限循环。
        private var fallbackUsed = false
        /// 阅读器迟迟没有正文时的看门狗。
        private var watchdog: DispatchWorkItem?

        init(parent: WereadReaderWebView) {
            self.parent = parent
        }

        func load() {
            guard let webView = webView else { return }
            guard let target = URL(string: parent.url) else { return }
            didAttemptJump = false
            jumpAttempts = 0
            jumpMode = parent.needsJump
            checkedReader = false
            verifyAttempts = 0
            readerVerified = false
            fallbackUsed = false
            watchdog?.cancel()
            watchdog = nil
            // 页面里已经登录过就别再灌旧 cookie —— 那会把用户刚登好的会话顶掉。
            let request = URLRequest(url: target)
            if parent.cookie.isEmpty {
                webView.load(request)
            } else {
                CookieJar.writeIfAbsent(
                    parent.cookie,
                    domainSuffix: "weread.qq.com"
                ) {
                    webView.load(request)
                }
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.isLoading = true
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.isLoading = false
            let current = webView.url?.absoluteString ?? ""
            // 真的跳进阅读器了就把地址记下来，下次点这本书直接秒开。
            if current.contains("/web/reader/") {
                parent.inReader = true
                // 不再「地址进了 /web/reader/ 就当成功」：hash 过期、正文没画出来
                // 的时候页面是白的，之前把这种地址也写进缓存，于是每次点都白屏。
                verifyReader(in: webView, url: current)
                return
            }
            // 落到书架上：先把这一屏所有书的阅读器地址抄下来，
            // 下次点别的书就不用再走一遍兜底。
            if current.contains("/web/shelf") {
                captureLinks(in: webView)
                if jumpMode || parent.needsJump {
                    jumpMode = true
                    guard !didAttemptJump else { return }
                    didAttemptJump = true
                    // 书架是 JS 渲染的，`didFinish` 时列表往往还没出来，多试几次。
                    scheduleJump(in: webView)
                    return
                }
            }
            // 直接拼出来的地址被服务端踢回书架 = 这本书的 hash 拼错了
            // （下架、合集、老书）。别让用户对着书架发愣，走点击兜底。
            if parent.url.contains("/web/reader/"), !jumpMode {
                enterJumpMode(in: webView)
                return
            }
            guard jumpMode || parent.needsJump else { return }
            jumpMode = true
            guard !didAttemptJump else { return }
            didAttemptJump = true
            scheduleJump(in: webView)
        }

        /// 阅读器页可能只是「书不存在」的空壳（HTTP 200），看正文判断一下。
        private func verifyReader(in webView: WKWebView, url: String) {
            checkedReader = true
            verifyAttempts = 0
            readerVerified = false
            startWatchdog(in: webView)
            checkReaderBody(in: webView, url: url)
        }

        /// 阅读器页面是纯 JS 画的，卡住时连脚本都不返回；所以看门狗走 Swift 计时，
        /// 到点还没确认正文就退回网页书架，别让用户对着白板。
        private func startWatchdog(in webView: WKWebView) {
            watchdog?.cancel()
            let item = DispatchWorkItem { [weak self, weak webView] in
                guard let self = self, let webView = webView else { return }
                guard !self.readerVerified, self.parent.inReader else { return }
                self.fallbackToShelf(in: webView)
            }
            watchdog = item
            // 正文最多校验 4 轮（2.5s × 4），看门狗要比它晚一点，
            // 免得正文刚画出来就被判成白屏。
            DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: item)
        }

        /// 正文是 JS 画出来的，`didFinish` 时往往还是白屏。
        /// 只看明确的「这本书不在这里」；白屏就再等一轮，最多三轮，
        /// 免得把「还在加载」误判成「打不开」把人踢回网页书架。
        private func checkReaderBody(in webView: WKWebView, url: String) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self, weak webView] in
                guard let self = self, let webView = webView else { return }
                guard self.parent.inReader, !self.fallbackUsed else { return }
                let script = "(document.body ? (document.body.innerText || '') : '').slice(0, 1500)"
                webView.evaluateJavaScript(script) { value, _ in
                    let text = ((value as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let missing =
                        text.contains("404")
                        || text.contains("不存在")
                        || text.contains("已下架")
                    if missing {
                        self.fallbackToShelf(in: webView)
                        return
                    }
                    if text.count < 10, self.verifyAttempts < 3 {
                        self.verifyAttempts += 1
                        self.checkReaderBody(in: webView, url: url)
                        return
                    }
                    if text.count < 10 {
                        // 白屏：这个地址不能用，别写缓存，退回网页书架让用户自己点。
                        self.fallbackToShelf(in: webView)
                        return
                    }
                    self.readerVerified = true
                    self.watchdog?.cancel()
                    self.watchdog = nil
                    WereadStore.shared.rememberReaderLink(
                        bookId: self.parent.bookId,
                        title: self.parent.bookTitle,
                        url: url
                    )
                }
            }
        }

        /// 阅读器打不开（白屏 / 404 / 卡住）时退回网页书架。
        private func fallbackToShelf(in webView: WKWebView) {
            watchdog?.cancel()
            watchdog = nil
            guard !fallbackUsed else {
                parent.isLoading = false
                return
            }
            fallbackUsed = true
            jumpMode = true
            checkedReader = false
            // 保持「已经自动跳过」的状态：退回书架后别再自动点开同一本书，
            // 否则又进白屏，而 fallbackUsed 已经用完，用户就卡死在白板上了。
            didAttemptJump = true
            jumpAttempts = 0
            parent.inReader = false
            parent.isLoading = true
            guard let shelf = URL(string: "https://weread.qq.com/web/shelf") else { return }
            webView.load(URLRequest(url: shelf))
        }

        private func enterJumpMode(in webView: WKWebView) {
            guard !jumpMode else { return }
            watchdog?.cancel()
            watchdog = nil
            jumpMode = true
            checkedReader = true
            didAttemptJump = false
            jumpAttempts = 0
            parent.inReader = false
            parent.isLoading = true
            guard let shelf = URL(string: "https://weread.qq.com/web/shelf") else { return }
            webView.load(URLRequest(url: shelf))
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            parent.isLoading = false
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            parent.isLoading = false
        }

        /// 卡片经常用新窗口打开；没有这个回调点了会没反应。
        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
                webView.load(URLRequest(url: url))
            }
            return nil
        }

        private func scheduleJump(in webView: WKWebView) {
            // 已经进阅读器了就别再折腾书架，否则会把正文页滚走。
            if parent.inReader { return }
            guard jumpAttempts < 14 else {
                // 实在找不到就把遮罩撤掉，让用户自己在网页书架上点。
                parent.isLoading = false
                return
            }
            // 第一次稍微等一下让书架铺开，之后半秒一次，快速试。
            let delay = jumpAttempts == 0 ? 0.8 : 0.6
            jumpAttempts += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak webView] in
                guard let self = self, let webView = webView else { return }
                self.captureLinks(in: webView)
                Self.openBook(
                    in: webView,
                    title: self.parent.bookTitle,
                    bookId: self.parent.bookId
                ) { found in
                    if found {
                        // 有些卡片走的是 SPA 路由，点完不会立刻换地址。
                        // 隔几秒还没进阅读器就再试一轮，免得停在书架上一动不动。
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self, weak webView] in
                            guard let self = self, let webView = webView else { return }
                            if self.parent.inReader { return }
                            let current = webView.url?.absoluteString ?? ""
                            if current.contains("/web/reader/") { return }
                            self.scheduleJump(in: webView)
                        }
                        return
                    }
                    // 书架是虚拟列表，目标书往往还在下面没渲染出来。
                    // 每次找不到就往下滚一屏；到底了就回到顶部再来一轮。
                    let scroll = "(function(){var h=document.documentElement;var bottom=(window.innerHeight+window.scrollY)>=((document.body?document.body.scrollHeight:0)-60);if(bottom){window.scrollTo(0,0);return 'top';}window.scrollBy(0,Math.round(window.innerHeight*0.9));return 'down';})()"
                    webView.evaluateJavaScript(scroll) { _, _ in
                        self.scheduleJump(in: webView)
                    }
                }
            }
        }

        /// 把网页书架上这一屏所有书的 `bookId/书名 → 阅读器地址` 抄进缓存。
        private func captureLinks(in webView: WKWebView) {
            let script = """
            (function(){
              var out = [];
              var anchors = document.querySelectorAll('a[href*="/web/reader/"]');
              for (var i = 0; i < anchors.length; i++) {
                var a = anchors[i];
                var text = (a.innerText || a.textContent || a.getAttribute('title') || '').replace(/\\s+/g,' ').trim();
                if (!text || text.length > 60) {
                  var img = a.querySelector('img');
                  if (img) { text = (img.getAttribute('alt') || '').trim(); }
                }
                if (!text || text.length > 60) { continue; }
                var id = '';
                var node = a;
                for (var k = 0; k < 6 && node; k++) {
                  if (node.getAttribute) {
                    id = node.getAttribute('data-book-id') || '';
                    if (id) { break; }
                  }
                  node = node.parentElement;
                }
                out.push({title: text, href: a.href, bookId: id});
              }
              return JSON.stringify(out);
            })()
            """
            webView.evaluateJavaScript(script) { value, _ in
                guard
                    let text = value as? String,
                    let data = text.data(using: .utf8),
                    let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
                else {
                    return
                }
                for item in list {
                    guard
                        let title = item["title"] as? String,
                        let href = item["href"] as? String,
                        !title.isEmpty,
                        !href.isEmpty
                    else {
                        continue
                    }
                    let bookId = (item["bookId"] as? String) ?? ""
                    WereadStore.shared.rememberReaderLink(bookId: bookId, title: title, url: href)
                }
            }
        }

        /// 在网页书架里找到目标书并点开。
        /// 优先用 `data-book-id`（和 shelf/sync 的数字 bookId 一致），
        /// 精确命中就不用赌书名是否被改过、是否带副标题。
        private static func openBook(
            in webView: WKWebView,
            title: String,
            bookId: String,
            completion: @escaping (Bool) -> Void
        ) {
            guard !title.isEmpty || !bookId.isEmpty else {
                completion(true)
                return
            }
            let script = """
            (function(){
              var title = \(jsString(title));
              var bookId = \(jsString(bookId));
              function norm(s){ return String(s||"").replace(/\\s+/g,"").toLowerCase(); }
              var target = norm(title);
              // 1) data-book-id 精确命中：卡片上的 id 就是书架接口给的 bookId。
              if (bookId) {
                var byId = null;
                try { byId = document.querySelector('[data-book-id="' + bookId + '"]'); } catch (e) { byId = null; }
                if (byId) {
                  var inner = byId.querySelector ? byId.querySelector('a[href*="/web/reader/"]') : null;
                  var self = (byId.getAttribute && byId.getAttribute('href') && byId.getAttribute('href').indexOf('/web/reader/') >= 0) ? byId : null;
                  var anchor = inner || self;
                  if (anchor && anchor.href) { location.href = anchor.href; return "nav"; }
                  if (byId.click) { byId.click(); return "click"; }
                }
              }
              if (!target) return "";
              // 2) 书名精确匹配 <a href="/web/reader/...">：直接改 location 最稳。
              var anchors = document.querySelectorAll('a[href*="/web/reader/"]');
              var fallback = "";
              for (var i = 0; i < anchors.length; i++) {
                var a = anchors[i];
                var text = norm(a.innerText || a.textContent || a.getAttribute('title') || a.getAttribute('aria-label') || "");
                if (!text) {
                  var img = a.querySelector('img');
                  if (img) { text = norm(img.getAttribute('alt') || ""); }
                }
                if (!text) { continue; }
                if (text === target) { location.href = a.href; return "nav"; }
                if (!fallback && (text.indexOf(target) >= 0 || target.indexOf(text) >= 0)) {
                  fallback = a.href;
                }
              }
              if (fallback) { location.href = fallback; return "nav"; }
              // 3) 有些卡片不是 <a>，只挂了 data-book-id 或者整块可点。
              var cards = document.querySelectorAll('[data-book-id], [class*="shelfBook"], [class*="bookItem"], [class*="book-item"]');
              for (var j = 0; j < cards.length; j++) {
                var c = cards[j];
                var ct = norm(c.innerText || c.textContent || "");
                if (!ct) { continue; }
                if (ct === target || ct.indexOf(target) >= 0) {
                  c.click();
                  return "click";
                }
              }
              return "";
            })()
            """
            webView.evaluateJavaScript(script) { value, _ in
                let result = value as? String ?? ""
                completion(!result.isEmpty)
            }
        }

        private static func jsString(_ value: String) -> String {
            let escaped =
                value
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                    .replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "\r", with: " ")
            return "\"\(escaped)\""
        }
    }
}
