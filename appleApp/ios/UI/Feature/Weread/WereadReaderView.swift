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

/// 只给微信读书网页阅读器用的 WKWebView。
///
/// 正文长按选中后，iOS 会把「拷贝 / 查询 / 翻译 / 学习 / 共享」这套系统
/// 编辑菜单压在选区上方，正好盖住网页自己的划线工具条。JS 先用合成鼠标
/// 事件把官方 `.reader_toolbar_container`（划线 / 想法）唤出来，确认它
/// 真的显示在当前选区旁边之后，才通知这里临时收起系统菜单。
/// 任何一步失败都保持/恢复系统菜单：宁可回到系统菜单，也不能让用户
/// 两个菜单都点不到。
///
/// - iOS 15（6S 真机）：正文选区菜单还是 `UIMenuController`，收到展示通知
///   后立刻收起；`canPerformAction` 再兜一层。
/// - iOS 16+：`buildMenu(with:)` 移除标准编辑 / 查询 / 学习 / 共享菜单。
/// - 输入框（登录、写想法）需要系统拷贝粘贴：JS 把焦点状态发过来放行。
private final class WereadSelectionWebView: WKWebView {
    /// 默认放行。只有 JS 明确报告「正文有选区且官方工具条已出现」时才关。
    var allowsSystemEditMenu = true {
        didSet {
            if allowsSystemEditMenu {
                failOpenWorkItem?.cancel()
                failOpenWorkItem = nil
                return
            }
            UIMenuController.shared.setMenuVisible(false, animated: false)
            // 兜底：只在当前这次长按后短暂收起系统菜单。即使 JS 后续没能
            // 再上报（输入框自动聚焦、跨 frame、合成事件失败等），也一定
            // 会恢复，绝不让用户连拷贝/粘贴都没有。
            failOpenWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                self?.allowsSystemEditMenu = true
            }
            failOpenWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: item)
        }
    }

    private var failOpenWorkItem: DispatchWorkItem?

    /// 系统菜单项的 action 名（含私有 selector）大致都落在这些词里。
    private static let menuSelectorKeywords = [
        "copy", "cut", "paste", "select", "lookup", "share", "learn",
        "translate", "define", "dictionary", "speech", "replace", "find", "delete"
    ]

    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(hideSystemMenuBeforeShow),
            name: UIMenuController.willShowMenuNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(hideSystemMenuAfterShow),
            name: UIMenuController.didShowMenuNotification,
            object: nil
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        failOpenWorkItem?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func hideSystemMenuBeforeShow() {
        guard !allowsSystemEditMenu else { return }
        // 同步收一次，再在下一轮主线程补一次：系统发完通知后还会再摆一次
        // 菜单，只同步收起会闪一下。
        UIMenuController.shared.setMenuVisible(false, animated: false)
        DispatchQueue.main.async {
            UIMenuController.shared.setMenuVisible(false, animated: false)
        }
    }

    @objc private func hideSystemMenuAfterShow() {
        guard !allowsSystemEditMenu else { return }
        // 展示后再同步收起有时会被系统下一帧覆盖，补一次异步。
        DispatchQueue.main.async {
            UIMenuController.shared.setMenuVisible(false, animated: false)
        }
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if !allowsSystemEditMenu {
            let name = NSStringFromSelector(action).lowercased()
            if Self.menuSelectorKeywords.contains(where: { name.contains($0) }) {
                return false
            }
        }
        return super.canPerformAction(action, withSender: sender)
    }

    // UIResponder.buildMenu(with:) 自 iOS 13 起可用；重写方法的可用性不能低于
    // 它重写的声明，否则 iOS 15 部署目标下编译报
    // "overriding 'buildMenu' must be as available as declaration it overrides"。
    // 实际移除菜单的逻辑仍只在 iOS 16+ 执行（iOS 15 走上面的 UIMenuController 路径）。
    @available(iOS 13.0, *)
    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard !allowsSystemEditMenu else { return }
        if #available(iOS 16.0, *) {
            let identifiers: [UIMenu.Identifier] = [.standardEdit, .lookup, .learn, .share]
            for identifier in identifiers where builder.menu(for: identifier) != nil {
                builder.remove(menu: identifier)
            }
        }
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
    /// 事件不能拦：它自己的划词菜单（划线 / 写想法）也要靠选区事件触发。
    /// 但光有选区不够：官方工具条是桌面交互，等 `mouseup`；iOS 长按只产生
    /// touch 和系统 UIMenu。所以这里补发 mouse 事件；官方工具条确认出现后，
    /// 才让 Swift 临时收起系统菜单，失败则继续保留系统菜单。
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
        ' { -webkit-user-select: text !important; user-select: text !important; -webkit-touch-callout: default !important; }' +
        '.reader_toolbar_container { z-index: 2147483000 !important; pointer-events: auto !important; }';
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
      // 桌面版阅读页的划词工具条（`.reader_toolbar_container`，里面是
      // `.toolbarItem.underlineStraight` 直线划线 / `.toolbarItem.review` 想法）
      // 只在「正文 mousedown → mousemove(which===1) → mouseup」之后弹出：
      // 官方 onContentMouseMove 要求左键拖动并据此算出选中的 objs，
      // onContentMouseUp 只有拿到非空 rects 才调用 showSelectionToolBar。
      // iOS 长按走 WKWebView 原生选区，网页只收到 touch，三个 handler 一个
      // 都不跑，所以只剩系统 UIMenu（拷贝 / 查询 / 翻译），还正好盖住选区。
      // 这里按原生选区的首尾坐标补一轮合成的鼠标拖动，让官方工具条按它
      // 自己的逻辑算选区、定位并弹出；只有确认工具条真的出来了，才让 Swift
      // 收起系统菜单（见 resume / verify 部分），失败则继续放行系统菜单。
      var savedRange = null;
      var lastSelectionKey = '';
      var revealTimer = null;
      var revealBusy = false;
      var revealAttempt = 0;
      var revealFailures = 0;
      // 合成鼠标事件在真机上不可用时，绝不能继续关系统菜单；连续失败两次
      // 就冷却一段时间，期间只走系统菜单，过后再试（避免首次选区早于正文
      // 渲染完成就把功能永久判死）。
      var revealRetryAfter = 0;
      // 官方工具条已为哪个选区成功显示，以及当时的选区矩形。用捕获的
      // 矩形做验证，合成拖动即使清掉原生选区也不会误判失败。
      var verifiedKey = '';
      var verifiedRects = [];

      // 官方 disableDefaultEvent 对 textarea / input / #richTextEditor 放行。
      // 这里覆盖得更宽：登录、写想法、长评、想法详情，以及各种自定义
      // contenteditable / ProseMirror 编辑器，都不能被误关系统拷贝粘贴。
      var editableTags = ['input', 'textarea', 'select'];
      var editableClasses = [
        'readerWriteReviewPanel',
        'writeReviewPanel',
        'write-review-panel',
        'reviewEditorPage_section_container',
        'readerReviewDetailPanel',
        'reader-float-review-create-panel',
        'ProseMirror',
        'ql-editor'
      ];
      var editorPanelSelectors = [
        '.readerWriteReviewPanel',
        'reader-float-review-create-panel',
        '.reader-float-review-create-panel',
        'write-review-panel',
        '.write-review-panel',
        '.reviewEditorPage_section_container',
        '[id="readerReviewDetailPanel"]',
        '.readerReviewDetailPanel'
      ];

      function classListContains(el, name) {
        try {
          return !!(el.classList && el.classList.contains(name));
        } catch (e) { return false; }
      }

      function isEditableNode(el) {
        if (!el || !el.tagName) return false;
        var tag = el.tagName.toLowerCase();
        for (var i = 0; i < editableTags.length; i++) {
          if (tag === editableTags[i]) return true;
        }
        if (el.isContentEditable) return true;
        for (var j = 0; j < editableClasses.length; j++) {
          if (classListContains(el, editableClasses[j])) return true;
        }
        if (el.getAttribute) {
          var role = (el.getAttribute('role') || '').toLowerCase();
          if (role === 'textbox' || role === 'searchbox' || role === 'combobox') {
            return true;
          }
          var editable = el.getAttribute('contenteditable');
          if (editable !== null && editable !== 'false') return true;
          if ((el.getAttribute('aria-multiline') || '') === 'true') return true;
        }
        return false;
      }

      function visibleNode(node) {
        if (!node || !node.getBoundingClientRect) return false;
        var rect = node.getBoundingClientRect();
        if (rect.width <= 4 || rect.height <= 4) return false;
        if (rect.bottom <= 0 || rect.right <= 0) return false;
        var vw = window.innerWidth || 0;
        var vh = window.innerHeight || 0;
        if (vw > 0 && rect.left >= vw) return false;
        if (vh > 0 && rect.top >= vh) return false;
        try {
          var style = window.getComputedStyle(node);
          if (!style || style.display === 'none' || style.visibility === 'hidden') {
            return false;
          }
          if (parseFloat(style.opacity || '1') < 0.05) return false;
        } catch (e) {}
        return true;
      }

      function visibleBySelector(selectors) {
        for (var i = 0; i < selectors.length; i++) {
          var list;
          try { list = document.querySelectorAll(selectors[i]); } catch (e) { list = []; }
          for (var j = 0; j < list.length; j++) {
            if (visibleNode(list[j])) return true;
          }
        }
        return false;
      }

      // shadow DOM 里 activeElement 会停在 shadow host 上，要逐层钻进去。
      function activeElementDeep() {
        var el = document.activeElement;
        var depth = 0;
        while (el && el.shadowRoot && el.shadowRoot.activeElement && depth < 8) {
          el = el.shadowRoot.activeElement;
          depth += 1;
        }
        return el;
      }

      function selectionTouchesEditable() {
        try {
          var sel = window.getSelection();
          if (!sel || sel.rangeCount === 0) return false;
          var nodes = [sel.anchorNode, sel.focusNode];
          for (var i = 0; i < nodes.length; i++) {
            var el = nodes[i];
            if (el && el.nodeType !== 1) el = el.parentElement;
            var depth = 0;
            while (el && depth < 12) {
              if (isEditableNode(el)) return true;
              el = el.parentElement;
              depth += 1;
            }
          }
        } catch (e) {}
        return false;
      }

      function isEditableActive() {
        try {
          // 长评编辑器走路由，不是标准 input；官方也按这个 hash 放行。
          if ((location.hash || '').indexOf('#richTextEditor') === 0) return true;
          var el = activeElementDeep();
          var depth = 0;
          while (el && el !== document.body && depth < 12) {
            if (isEditableNode(el)) return true;
            el = el.parentElement;
            depth += 1;
          }
          // 选区落在编辑器里（contenteditable / ProseMirror）时也算编辑态。
          if (selectionTouchesEditable()) return true;
          // 编辑器可能把焦点留在容器上，或自动聚焦早于脚本注入；
          // 只要可见的写想法 / 长评 / 想法详情面板在，就按编辑态处理。
          return visibleBySelector(editorPanelSelectors);
        } catch (e) {
          // 判断不出来就放行系统菜单，不能把输入框的拷贝粘贴关死。
          return true;
        }
      }

      function selectionRects() {
        try {
          var sel = window.getSelection();
          if (!sel || sel.rangeCount === 0 || sel.isCollapsed) return [];
          if (!String(sel.toString() || '').trim()) return [];
          var range = sel.getRangeAt(0);
          var list = range.getClientRects();
          var rects = [];
          for (var i = 0; i < list.length; i++) {
            var rect = list[i];
            if (rect && rect.width > 0 && rect.height > 0) { rects.push(rect); }
          }
          if (rects.length === 0) {
            var fallback = range.getBoundingClientRect();
            if (fallback && fallback.width > 0 && fallback.height > 0) {
              rects.push(fallback);
            }
          }
          return rects;
        } catch (e) { return []; }
      }

      function toolbarNode() {
        return document.querySelector('.reader_toolbar_container');
      }

      function toolbarVisible() {
        var bar = toolbarNode();
        if (!bar) return false;
        try {
          var style = window.getComputedStyle(bar);
          if (!style || style.display === 'none' || style.visibility === 'hidden') return false;
          if (parseFloat(style.opacity || '1') < 0.05) return false;
          var rect = bar.getBoundingClientRect();
          if (rect.width < 10 || rect.height < 10) return false;
          return rect.bottom > 0 && rect.top < (window.innerHeight || 0);
        } catch (e) { return false; }
      }

      // 工具条必须贴着当前选区，才能排除「上一次选区的旧工具条还挂着」。
      // 官方把工具条摆在上方或下方，横向中心落在选区范围内。
      function toolbarNearRects(rects) {
        var bar = toolbarNode();
        if (!bar) return false;
        var br = bar.getBoundingClientRect();
        if (!rects || !rects.length) return false;
        var minX = Infinity, maxX = -Infinity, minY = Infinity, maxY = -Infinity;
        for (var i = 0; i < rects.length; i++) {
          var rect = rects[i];
          if (rect.left < minX) minX = rect.left;
          if (rect.right > maxX) maxX = rect.right;
          if (rect.top < minY) minY = rect.top;
          if (rect.bottom > maxY) maxY = rect.bottom;
        }
        var centerX = (br.left + br.right) / 2;
        if (centerX < minX - 80 || centerX > maxX + 80) return false;
        var verticalGap = 0;
        if (br.top > maxY) verticalGap = br.top - maxY;
        else if (minY > br.bottom) verticalGap = minY - br.bottom;
        return verticalGap <= 160;
      }

      function selectionKey() {
        try {
          var sel = window.getSelection();
          if (!sel || sel.rangeCount === 0 || sel.isCollapsed) return '';
          var text = String(sel.toString() || '').trim();
          if (!text) return '';
          var rects = selectionRects();
          if (rects.length === 0) return '';
          var first = rects[0];
          var last = rects[rects.length - 1];
          return text.slice(0, 80) + '|' + Math.round(first.left) + ',' +
            Math.round(first.top) + ',' + Math.round(last.right) + ',' +
            Math.round(last.top);
        } catch (e) { return ''; }
      }

      // 只上报两种状态：焦点在编辑器，或「正文选区 + 官方工具条已确认」。
      // Swift 侧据此决定是否临时收起系统菜单；其余情况一律放行。
      // 不做同值去重：Swift 的 8 秒兜底会重新放行系统菜单，之后必须能
      // 靠后续 selectionchange / focus 再关回去。
      function postState(reason) {
        var editable = isEditableActive();
        var selecting = !editable && verifiedKey !== '' &&
          toolbarVisible() && toolbarNearRects(verifiedRects);
        try {
          window.webkit.messageHandlers.flareSelection.postMessage({
            editable: editable,
            selecting: selecting,
            reason: reason || ''
          });
        } catch (e) {}
      }

      function contentElementAt(x, y) {
        var el = document.elementFromPoint(x, y);
        var content = document.querySelector('.readerChapterContent') ||
          document.querySelector('#renderTargetContent') ||
          document.querySelector('.app_content');
        if (el && (!content || content.contains(el))) return el;
        // 覆盖层（例如旧工具条）挡住时，按坐标找底下的文字节点。
        try {
          var range = document.caretRangeFromPoint ? document.caretRangeFromPoint(x, y) : null;
          if (range) {
            var node = range.startContainer;
            var candidate = node ? (node.nodeType === 1 ? node : node.parentElement) : null;
            if (candidate && (!content || content.contains(candidate))) return candidate;
          }
        } catch (e) {}
        return el;
      }

      function isLikelyContentTarget(el) {
        if (!el) return false;
        if (el === document.documentElement) return true;
        var content = document.querySelector('.readerChapterContent') ||
          document.querySelector('#renderTargetContent') ||
          document.querySelector('.app_content');
        // 找不到正文容器时不阻断，仍交给官方 onContentMouseDown 判断。
        if (!content) return true;
        return content === el || content.contains(el);
      }

      // 旧工具条如果还显示且 pointer-events:auto，合成 mousedown 会打在它身上，
      // 官方正文 handler 收不到。拖动期间临时让工具条不参与命中。
      function suspendToolbarHitTesting() {
        var bars = document.querySelectorAll('.reader_toolbar_container');
        for (var i = 0; i < bars.length; i++) {
          var bar = bars[i];
          if (!bar.hasAttribute('data-flare-toolbar-pe')) {
            bar.setAttribute(
              'data-flare-toolbar-pe',
              bar.style.getPropertyValue('pointer-events') || ''
            );
          }
          bar.style.setProperty('pointer-events', 'none', 'important');
        }
      }

      function resumeToolbarHitTesting() {
        var bars = document.querySelectorAll('.reader_toolbar_container');
        for (var i = 0; i < bars.length; i++) {
          var bar = bars[i];
          if (!bar.hasAttribute('data-flare-toolbar-pe')) continue;
          var old = bar.getAttribute('data-flare-toolbar-pe');
          if (old) {
            bar.style.setProperty('pointer-events', old, 'important');
          } else {
            bar.style.removeProperty('pointer-events');
          }
          bar.removeAttribute('data-flare-toolbar-pe');
        }
      }

      function clampX(x) {
        return Math.min(Math.max(x, 1), Math.max(window.innerWidth - 1, 1));
      }

      function clampY(y) {
        return Math.min(Math.max(y, 1), Math.max(window.innerHeight - 1, 1));
      }

      function emitMouse(name, x, y, target) {
        try {
          var el = target || document.elementFromPoint(x, y) || document.body;
          if (!el) return;
          var event = new MouseEvent(name, {
            bubbles: true,
            cancelable: true,
            view: window,
            clientX: x,
            clientY: y,
            screenX: x,
            screenY: y,
            button: 0,
            buttons: name === 'mouseup' ? 0 : 1
          });
          // 官方 onContentMouseMove 用 `event.which === 1` 判断左键拖动；
          // MouseEvent 构造参数里没有 which，这里补一个同名属性。
          try {
            Object.defineProperty(event, 'which', { value: 1 });
          } catch (e) {
            try { event.which = 1; } catch (e2) {}
          }
          el.dispatchEvent(event);
        } catch (e) {}
      }

      // 从选区首行左端拖到末行右端。官方 mousedown 会清空上一次的 objs，
      // 只补 mouseup 不会产生 rects；必须走完整的按下 / 移动 / 抬起。
      function replaySelectionDrag(rects) {
        if (!rects || rects.length === 0) return false;
        var first = rects[0];
        var last = rects[rects.length - 1];
        var startX = clampX(first.left + Math.min(2, first.width / 2));
        var startY = clampY(first.top + Math.min(first.height, 20) / 2);
        var endX = clampX(last.right - Math.min(2, last.width / 2));
        var endY = clampY(last.top + Math.min(last.height, 20) / 2);
        var startEl = contentElementAt(startX, startY);
        var endEl = contentElementAt(endX, endY);
        if (!startEl || !endEl) return false;
        if (!isLikelyContentTarget(startEl)) return false;
        // 中间点必须与起点不同：官方 mousemove 一旦拿到退化区间，会把
        // 拖动状态清掉，后面的 mouseup 就不再有 objs/rects。
        var midX = clampX((startX + endX) / 2);
        var midY = clampY((startY + endY) / 2);
        if (Math.abs(midX - startX) < 1 && Math.abs(midY - startY) < 1) {
          midX = clampX(startX + 1);
        }
        var midEl = contentElementAt(midX, midY) || startEl;
        emitMouse('mousedown', startX, startY, startEl);
        emitMouse('mousemove', midX, midY, midEl);
        emitMouse('mousemove', endX, endY, endEl);
        emitMouse('mouseup', endX, endY, endEl);
        return true;
      }

      function restoreSelection() {
        if (!savedRange) return;
        var sel = window.getSelection();
        if (sel && sel.rangeCount > 0 && !sel.isCollapsed) return;
        try {
          if (!sel) { sel = window.getSelection(); }
          if (!sel) return;
          sel.removeAllRanges();
          sel.addRange(savedRange);
        } catch (e) {}
      }

      function revealSelectionToolbar() {
        if (revealBusy || Date.now() < revealRetryAfter) return;
        var key = selectionKey();
        var rects = selectionRects();
        if (!key || rects.length === 0) return;
        revealBusy = true;
        var attempt = ++revealAttempt;
        bindToolbar();
        suspendToolbarHitTesting();
        var replayed = false;
        try {
          replayed = replaySelectionDrag(rects);
        } finally {
          // 拖动事件已经同步派发完，工具条必须立刻恢复可点；不能把它
          // 留给带 attempt 守卫的延时任务，否则新选区一来就永久丢点击。
          resumeToolbarHitTesting();
        }
        // 合成拖动可能让页面清掉原生选区，清掉就还原，用户仍能看到
        // 自己选的文字和手柄；工具条按钮本身用的是页面捕获的 objs。
        setTimeout(function () {
          restoreSelection();
          resumeToolbarHitTesting();
          bindToolbar();
          if (attempt === revealAttempt) {
            revealBusy = false;
            var afterKey = selectionKey();
            if (afterKey) { lastSelectionKey = afterKey; }
          }
        }, 300);
        // 先不关系统菜单：等官方工具条真的在当前选区旁出现，再让 Swift
        // 收起系统菜单。合成事件无效时用户仍保留系统菜单，不会两个都没有。
        setTimeout(function () {
          if (attempt !== revealAttempt) return;
          var ok = replayed && toolbarVisible() && toolbarNearRects(rects);
          if (ok) {
            revealFailures = 0;
            verifiedKey = key;
            verifiedRects = rects;
            lastSelectionKey = key;
            postState('toolbar-visible');
          } else {
            revealFailures += 1;
            verifiedKey = '';
            verifiedRects = [];
            if (revealFailures >= 2) {
              revealFailures = 0;
              revealRetryAfter = Date.now() + 8000;
            }
            // 失败必须强制上报：此时状态通常和上一次「无选区」相同，
            // 若被去重吞掉，Swift 可能还停留在「已关系统菜单」。
            postState('toolbar-failed');
          }
        }, 550);
      }

      function scheduleReveal() {
        if (revealTimer) { clearTimeout(revealTimer); }
        revealTimer = setTimeout(function () {
          revealTimer = null;
          if (revealBusy || Date.now() < revealRetryAfter || isEditableActive()) return;
          revealSelectionToolbar();
        }, 320);
      }

      document.addEventListener('selectionchange', function () {
        // 合成事件本身会改选区；这里在 busy 期间不响应，避免自己触发自己。
        if (revealBusy) return;
        var editable = isEditableActive();
        var key = selectionKey();
        if (editable || key === '') {
          savedRange = null;
          lastSelectionKey = '';
          verifiedKey = '';
          verifiedRects = [];
          postState(editable ? 'editable' : 'empty');
          return;
        }
        var sel = window.getSelection();
        try {
          savedRange = sel.getRangeAt(0).cloneRange();
        } catch (e) {
          savedRange = null;
          verifiedKey = '';
          postState('empty');
          return;
        }
        // 新选区/选区变了先放行系统菜单；等合成拖动确认官方工具条出来，
        // 下面的 toolbar-visible 才会重新关掉系统菜单。
        if (verifiedKey && verifiedKey !== key) { verifiedKey = ''; }
        postState('selection');
        if (key !== lastSelectionKey) {
          lastSelectionKey = key;
          scheduleReveal();
        }
      }, true);

      // 工具条上的按钮要按得住：iOS 点它时页面可能在 touchstart 里收起选区
      // 或做别的处理。只 stopPropagation、不 preventDefault，保证 click 仍能
      // 合成。工具条换章后可能重建，节点换了就重新绑。
      var boundToolbar = null;
      function bindToolbar() {
        var bar = toolbarNode();
        if (!bar || bar === boundToolbar) return;
        boundToolbar = bar;
        ['touchstart', 'mousedown'].forEach(function (name) {
          bar.addEventListener(name, function (event) {
            event.stopPropagation();
          }, { passive: true });
        });
      }

      // 网页里的输入框（登录、写想法、长评编辑器）仍需要系统拷贝粘贴。
      // 每次焦点变化都立即上报，自动聚焦/脚本注入前已聚焦也能覆盖。
      document.addEventListener('focusin', function () {
        postState('focusin');
      }, true);
      document.addEventListener('focusout', function () {
        setTimeout(function () { postState('focusout'); }, 0);
      }, true);
      postState('init');

      // 这里**不要**再拦 mousedown / mouseup / selectstart / contextmenu。
      // 官方划线工具条靠正文上的 mouseup 触发；这些事件被捕获阶段
      // stopPropagation 掉，工具条就弹不出来，用户只剩系统菜单。
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
        // JS 上报「焦点是否在编辑器」以及「官方划线工具条是否已为当前
        // 正文选区出现」；只有后者为真时才临时收起系统菜单。
        configuration.userContentController.add(context.coordinator, name: "flareSelection")
        let webView = WereadSelectionWebView(frame: .zero, configuration: configuration)
        // 桌面 UA：手机 UA 下微信读书会把网页换成「打开 App」引导页。
        webView.customUserAgent = WebPlatformUserAgent.desktop
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        context.coordinator.webView = webView
        context.coordinator.selectionWebView = webView
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

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "flareSelection")
        webView.stopLoading()
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        var parent: WereadReaderWebView
        weak var webView: WKWebView?
        weak var selectionWebView: WereadSelectionWebView?
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
            // 新页面 JS 还没上报前一律放行：加载失败也不能把系统菜单关死。
            selectionWebView?.allowsSystemEditMenu = true
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
            selectionWebView?.allowsSystemEditMenu = true
            parent.isLoading = true
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == "flareSelection" else { return }
            guard let body = message.body as? [String: Any] else { return }
            // 缺字段时按「编辑器 / 放行」处理，JS 漏报也不会关掉系统菜单。
            let editable = (body["editable"] as? Bool) ?? true
            let selecting = (body["selecting"] as? Bool) ?? false
            // 只有「焦点不在编辑器，且官方工具条已确认在当前选区旁出现」
            // 才收起系统菜单；其余情况一律放行。
            selectionWebView?.allowsSystemEditMenu = editable || !selecting
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
