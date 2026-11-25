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
    /// true = PDF 书。PDF 由网页阅读器用画布渲染，正文 `innerText`
    /// 可能接近空，不能按「白屏」把它退回网页书架。
    let isPDF: Bool

    init(
        url: String,
        title: String,
        bookId: String,
        needsJump: Bool,
        isPDF: Bool = false
    ) {
        self.url = url
        self.title = title
        self.bookId = bookId
        self.needsJump = needsJump
        self.isPDF = isPDF
    }
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
                isPDF: target.isPDF,
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
                        Text(
                            target.isPDF
                                ? "PDF 由微读官方网页阅读器渲染，首次打开会稍慢"
                                : "一直在转圈的话，等下会露出网页书架，点封面也能进"
                        )
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
    let isPDF: Bool
    let reloadToken: Int
    @Binding var isLoading: Bool
    @Binding var inReader: Bool

    /// 让阅读页的文字可以被长按选中。
    ///
    /// 微信读书会给正文容器写 `user-select: none`，CSS 用 `!important` 盖掉即可。
    /// 事件不能拦：它自己的划词菜单（划线 / 写想法）就挂在 `selectstart` 上。
    private static let selectionScript = """
    (function(){
      var styleId = 'flare-select-style';
      // 只放开「正文段落」，不要把 body 整页放开。
      // 以前 body * 全开，长按一下整页就被当成一个可选块，一拖就是全页，
      // 微信读书自己的划词菜单也认不出「你选的是哪一段」。
      var css = 'html, body { -webkit-user-select: none !important; user-select: none !important; }' +
        'p, p *, li, li *, blockquote, blockquote *, td, td *,' +
        '.readerChapterContent p, .readerChapterContent p *,' +
        '#renderTargetContent p, #renderTargetContent p *,' +
        '.app_content p, .app_content p *' +
        ' { -webkit-user-select: text !important; user-select: text !important; -webkit-touch-callout: default !important; }';
      var pending = false;
      // iOS 15 的 WKWebView 里，祖先一旦 user-select:none，子节点常常盖不回来，
      // 表现就是「已划线的字能点，自己拖选新文段不行」。微信读书的正文层级不固定，
      // 所以不靠一张选择器表：手指按下时把命中的元素向上 4 层临时放开选择，
      // 同时不放开 body，避免一拖整页。
      function enableSelectionAt(target) {
        var el = target;
        var depth = 0;
        while (el && el !== document.body && depth < 4) {
          try {
            el.style.setProperty('-webkit-user-select', 'text', 'important');
            el.style.setProperty('user-select', 'text', 'important');
            el.style.setProperty('-webkit-touch-callout', 'default', 'important');
          } catch (e) {}
          el = el.parentElement;
          depth += 1;
        }
      }
      ['touchstart', 'pointerdown', 'mousedown'].forEach(function (name) {
        document.addEventListener(name, function (event) {
          if (event.target) { enableSelectionAt(event.target); }
        }, { passive: true, capture: true });
      });
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
          var inline = document.querySelectorAll('p[style*="user-select"], p [style*="user-select"], .readerChapterContent [style*="user-select"], #renderTargetContent [style*="user-select"]');
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
      // 这里**不要**再拦 selectstart / contextmenu。微信读书的划线、想法菜单
      // 就是监听这两个事件的，捕获阶段一 stopPropagation，它自己的菜单也弹不
      // 出来，用户只剩系统菜单（复制 / 查询），根本写不了想法。
      try {
        var observer = new MutationObserver(schedule);
        observer.observe(document.documentElement, { childList: true, subtree: true });
      } catch (e) {}
    })();
    """

    /// iOS 长按正文只会弹 UIKit 的「拷贝 / 查询 / 翻译 / 学习 / 共享」菜单，
    /// 微信读书官方的「划线 / 写想法」工具条不会出现：官方工具条是网页自己
    /// 在鼠标抬起后调 `showSelectionToolBar` 渲染的，而 iOS 长按不会派发
    /// 那条鼠标流程。这里把 DOM 选区映射回官方渲染对象，再调用官方阅读组件
    /// 自己的 `showSelectionToolBar`，由官方逻辑负责划线、写想法和云端同步。
    /// 工具条确认出现后才清掉网页选区并通知原生收起系统菜单；找不到官方
    /// 组件或映射失败时完全不动选区，系统菜单照旧可用。
    private static let selectionBridgeScript = """
    (function(){
      if (window.__flareSelectionBridge) { return; }
      window.__flareSelectionBridge = true;
      var touchActive = false;
      var pendingTimer = 0;
      var lastKey = '';
      var failures = 0;
      var cooldownUntil = 0;

      function postHideMenu() {
        try {
          if (window.webkit && window.webkit.messageHandlers &&
              window.webkit.messageHandlers.flareSelection) {
            window.webkit.messageHandlers.flareSelection.postMessage('hideMenu');
          }
        } catch (e) {}
      }

      function toolbarShowing() {
        var el = document.querySelector('.reader_toolbar_container[data-wr-role="selectionToolbar"]');
        if (!el) { return false; }
        var r = el.getBoundingClientRect();
        var style = window.getComputedStyle(el);
        return r.width > 8 && r.height > 8 &&
          style.display !== 'none' && style.visibility !== 'hidden' &&
          style.opacity !== '0';
      }

      function inEditable(el) {
        while (el && el !== document.body) {
          var tag = (el.tagName || '').toLowerCase();
          if (tag === 'input' || tag === 'textarea' || el.isContentEditable) { return true; }
          el = el.parentElement;
        }
        return false;
      }

      // 返回 null 一律表示「不要介入」：空选区、非正文、输入框 / 想法编辑器、
      // 或没有可用的行矩形。
      function currentSelection() {
        var sel = window.getSelection();
        if (!sel || sel.rangeCount < 1 || sel.isCollapsed) { return null; }
        var text = (sel.toString() || '').replace(/\\s+/g, ' ').trim();
        if (!text || text.length > 3000) { return null; }
        var range = sel.getRangeAt(0);
        var startNode = range.startContainer;
        var endNode = range.endContainer;
        var startEl = startNode && startNode.nodeType === 3 ? startNode.parentElement : startNode;
        var endEl = endNode && endNode.nodeType === 3 ? endNode.parentElement : endNode;
        if (!startEl || !endEl || !startEl.closest) { return null; }
        var content = startEl.closest('.readerChapterContent, #renderTargetContent, #renderTargetContainer, .app_content');
        if (!content || !content.contains(endEl)) { return null; }
        if (startEl.closest('.reader_toolbar_container, .readerReviewDetailPanel, [contenteditable="true"], input, textarea')) {
          return null;
        }
        if (inEditable(startEl) || inEditable(endEl)) { return null; }
        var raw = range.getClientRects();
        var rects = [];
        for (var i = 0; i < raw.length && i < 80; i++) {
          var r = raw[i];
          if (r.width > 1 && r.height > 1) { rects.push(r); }
        }
        if (!rects.length) { return null; }
        return { text: text, startEl: startEl, rects: rects };
      }

      // 微信读书每个组件根节点都带 Vue 2 的 `__vue__`。从选区起点向上爬，
      // 再顺着 `$parent` 找阅读页组件，不赌单一挂载点。
      function candidates(startEl) {
        var out = [];
        var seen = [];
        function add(vm) {
          if (!vm || seen.indexOf(vm) >= 0) { return; }
          seen.push(vm);
          out.push(vm);
        }
        var el = startEl;
        var hops = 0;
        while (el && el !== document.documentElement && hops < 20) {
          var vm = el.__vue__;
          var depth = 0;
          while (vm && depth < 20) {
            add(vm);
            vm = vm.$parent;
            depth += 1;
          }
          el = el.parentElement;
          hops += 1;
        }
        return out;
      }

      function findReader(info) {
        var list = candidates(info.startEl);
        var best = null;
        for (var i = 0; i < list.length; i++) {
          var vm = list[i];
          if (!vm || typeof vm.showSelectionToolBar !== 'function') { continue; }
          if (typeof vm.clientXY2RenderAreaXY !== 'function') { continue; }
          if (typeof vm.findObjsWithPointsOnPointer !== 'function' &&
              typeof vm.findObjsWithPoints !== 'function') { continue; }
          if (!vm.$refs || !vm.$refs.renderTargetContainer || !vm.$refs.appContent) { continue; }
          if (!best) { best = vm; continue; }
          var el = vm.$el;
          if (el && el.contains && el.contains(info.startEl) &&
              (!best.$el || !best.$el.contains || !best.$el.contains(info.startEl))) {
            best = vm;
          }
        }
        return best;
      }

      function mapObjs(vm, rects) {
        var first = rects[0];
        var last = rects[rects.length - 1];
        var p1 = vm.clientXY2RenderAreaXY({ x: first.left + 1, y: first.top + 1 });
        var p2 = vm.clientXY2RenderAreaXY({ x: last.right - 1, y: last.bottom - 1 });
        if (!p1 || !p2) { return null; }
        var objs = null;
        if (typeof vm.findObjsWithPoints === 'function') {
          objs = vm.findObjsWithPoints(p1, p2);
        } else {
          objs = vm.findObjsWithPointsOnPointer(p1, p2);
        }
        if (!objs || !objs.length) { return null; }
        var contentRects = null;
        if (typeof vm.getRectsByContentObjs === 'function') {
          contentRects = vm.getRectsByContentObjs(objs);
        }
        if (!contentRects || !contentRects.length) {
          contentRects = [];
          for (var i = 0; i < objs.length; i++) {
            if (objs[i] && objs[i].rect) { contentRects.push(objs[i].rect); }
          }
        }
        if (!contentRects.length) { return null; }
        return { objs: objs, rects: contentRects };
      }

      function fail() {
        failures += 1;
        if (failures >= 2) {
          cooldownUntil = Date.now() + 1200;
          failures = 0;
        }
      }

      function trigger() {
        pendingTimer = 0;
        if (touchActive || Date.now() < cooldownUntil) { return; }
        var info = currentSelection();
        if (!info) { lastKey = ''; return; }
        var last = info.rects[info.rects.length - 1];
        var key = info.text.slice(0, 60) + '|' + info.rects.length + '|' +
          Math.round(info.rects[0].left) + ',' + Math.round(info.rects[0].top) + '|' +
          Math.round(last.right) + ',' + Math.round(last.bottom);
        if (key === lastKey) { return; }
        var vm = findReader(info);
        if (!vm) { fail(); return; }
        var mapped = null;
        try { mapped = mapObjs(vm, info.rects); } catch (e) { mapped = null; }
        if (!mapped) { fail(); return; }
        try {
          vm.showSelectionToolBar({ objs: mapped.objs, rects: mapped.rects, existBookmark: null });
        } catch (e) {
          fail();
          return;
        }
        lastKey = key;
        failures = 0;
        var attempts = 0;
        var verify = function() {
          attempts += 1;
          if (toolbarShowing()) {
            try { window.getSelection().removeAllRanges(); } catch (e) {}
            postHideMenu();
            return;
          }
          if (attempts < 6) { setTimeout(verify, 120); }
        };
        setTimeout(verify, 80);
      }

      function schedule(delay) {
        if (pendingTimer) { clearTimeout(pendingTimer); }
        pendingTimer = setTimeout(trigger, delay);
      }

      document.addEventListener('touchstart', function() {
        touchActive = true;
        if (pendingTimer) { clearTimeout(pendingTimer); pendingTimer = 0; }
      }, { capture: true, passive: true });
      document.addEventListener('touchend', function() {
        touchActive = false;
        schedule(320);
      }, { capture: true, passive: true });
      document.addEventListener('touchcancel', function() {
        touchActive = false;
      }, { capture: true, passive: true });
      document.addEventListener('selectionchange', function() {
        if (touchActive) { return; }
        schedule(320);
      });
    })();
    """

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        // 长按选择按「字符」而不是「块」：默认的 dynamic 在微信读书这种
        // 嵌套 div 的正文里会把整段（甚至整页）当成一个可选块，一拖就是全页。
        configuration.selectionGranularity = .character
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
        configuration.userContentController.add(context.coordinator, name: "flareSelection")
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: Self.selectionBridgeScript,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
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

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "flareSelection")
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
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

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == "flareSelection" else { return }
            // 网页已经把官方工具条显示出来并清掉选区；这里再把 iOS 原生的
            // 编辑菜单收起，避免它盖住官方「划线 / 写想法」。
            UIMenuController.shared.hideMenu()
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
            // PDF 阅读页是画布，`innerText` 只有页码之类的 UI 文案，
            // 甚至可能因为「第 3 / 404 页」被误判成 404。PDF 能停在
            // `/web/reader/` 就按成功处理；真被服务端踢回书架时
            // `didFinish` 的地址判断会走点击兜底。
            if parent.isPDF {
                readerVerified = true
                watchdog?.cancel()
                watchdog = nil
                WereadStore.shared.rememberReaderLink(
                    bookId: parent.bookId,
                    title: parent.bookTitle,
                    url: url
                )
                return
            }
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
            // 正文最多校验 7 轮（1.5s × 7 ≈ 10.5s），看门狗要比它晚一点，
            // 免得正文刚画出来就被判成白屏。
            DispatchQueue.main.asyncAfter(deadline: .now() + 16, execute: item)
        }

        /// 正文是 JS 画出来的，`didFinish` 时往往还是白屏。
        /// 只看明确的「这本书不在这里」；白屏就再等一轮，最多三轮，
        /// 免得把「还在加载」误判成「打不开」把人踢回网页书架。
        private func checkReaderBody(in webView: WKWebView, url: String) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self, weak webView] in
                guard let self = self, let webView = webView else { return }
                // 不要再挡 `fallbackUsed`：白屏退回书架、自动重新点开之后，
                // 这一轮仍然要校验正文并缓存真地址。
                guard self.parent.inReader else { return }
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
                    // 白屏有两种：地址真的不能用，和「JS 还在画」。
                    // 以前 4.5 秒没字就弹回网页书架，书架又要重新加载一遍，
                    // 用户看到的就是「白屏 → 转圈 → 白屏」，比单纯等还慢。
                    if text.count < 10, self.verifyAttempts < 6 {
                        self.verifyAttempts += 1
                        self.checkReaderBody(in: webView, url: url)
                        return
                    }
                    if text.count < 10 {
                        // 已经弹过一次书架了：再弹只会更慢，把页面留给用户，
                        // 顶部的刷新按钮还能自己重试。
                        if self.fallbackUsed {
                            self.parent.isLoading = false
                            return
                        }
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
            // 第一次白屏：退回书架后**再自动点一次**（这一轮书架 DOM 已经渲染过，
            // 能拿到这本书真正的阅读器地址，比让用户自己再点一遍快得多）。
            // 第二次还白屏：就停在书架上让用户自己点，别再来回弹。
            let secondTime = fallbackUsed
            fallbackUsed = true
            jumpMode = true
            checkedReader = false
            didAttemptJump = secondTime
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
            guard jumpAttempts < 24 else {
                // 实在找不到就把遮罩撤掉，让用户自己在网页书架上点。
                parent.isLoading = false
                return
            }
            // 书架是 JS 渲染的，第一次多等一点让它铺开，之后 0.35 秒试一次。
            let delay = jumpAttempts == 0 ? 0.45 : 0.35
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
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self, weak webView] in
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
