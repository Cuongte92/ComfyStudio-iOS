import SwiftUI
import WebKit
import PhotosUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var isLightMode = false

    var body: some View {
        LiquidGlassWebView(htmlContent: embeddedHTML, isLightMode: $isLightMode)
            .ignoresSafeArea(.container, edges: .bottom)
            .background(isLightMode
                ? Color(red: 243/255, green: 244/255, blue: 248/255)
                : Color(red: 7/255, green: 8/255, blue: 14/255))
            .preferredColorScheme(isLightMode ? .light : .dark)
    }
}

struct LiquidGlassWebView: UIViewRepresentable {
    let htmlContent: String
    @Binding var isLightMode: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(isLightMode: $isLightMode)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")

        config.userContentController.add(context.coordinator, name: "exportHtmlHandler")
        config.userContentController.add(context.coordinator, name: "themeChangeHandler")
        config.userContentController.add(context.coordinator, name: "nativeAttachHandler")

        let webView = WKWebView(frame: .zero, configuration: config)
        context.coordinator.webView = webView
        webView.isOpaque = false
        webView.backgroundColor = UIColor(red: 7/255, green: 8/255, blue: 14/255, alpha: 1.0)
        webView.scrollView.backgroundColor = UIColor(red: 7/255, green: 8/255, blue: 14/255, alpha: 1.0)
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.uiDelegate = context.coordinator

        let bridgeScript = """
        window.exportSingleHtmlFile = function() {
            const clone = document.documentElement.cloneNode(true);
            const apiInput = clone.querySelector("#apiKeyInput");
            if (apiInput) apiInput.value = "";
            const customKey = clone.querySelector("#customApiKeyInput");
            if (customKey) customKey.value = "";
            const fullHtml = "<!DOCTYPE html>\\n" + clone.outerHTML;
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.exportHtmlHandler) {
                window.webkit.messageHandlers.exportHtmlHandler.postMessage(fullHtml);
            }
        };

        document.addEventListener("DOMContentLoaded", function() {
            const attachBtn = document.getElementById("attachFileBtn");
            if (attachBtn) {
                attachBtn.onclick = function(e) {
                    e.preventDefault();
                    e.stopPropagation();
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.nativeAttachHandler) {
                        window.webkit.messageHandlers.nativeAttachHandler.postMessage("openPicker");
                    }
                };
            }
        });

        window.receiveNativeFile = function(fileObj) {
            if (typeof STATE !== "undefined" && typeof renderFilePreviews === "function") {
                STATE.currentFiles.push(fileObj);
                renderFilePreviews();
            }
        };
        """
        let userScript = WKUserScript(source: bridgeScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        config.userContentController.addUserScript(userScript)

        webView.loadHTMLString(htmlContent, baseURL: URL(string: "https://localhost"))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        let bgColor = isLightMode
            ? UIColor(red: 243/255, green: 244/255, blue: 248/255, alpha: 1.0)
            : UIColor(red: 7/255, green: 8/255, blue: 14/255, alpha: 1.0)
        uiView.backgroundColor = bgColor
        uiView.scrollView.backgroundColor = bgColor
    }

    class Coordinator: NSObject, WKScriptMessageHandler, WKUIDelegate, PHPickerViewControllerDelegate, UIDocumentPickerDelegate {
        @Binding var isLightMode: Bool
        weak var webView: WKWebView?

        init(isLightMode: Binding<Bool>) {
            _isLightMode = isLightMode
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "themeChangeHandler", let theme = message.body as? String {
                DispatchQueue.main.async {
                    self.isLightMode = (theme == "light")
                }
                return
            }

            if message.name == "nativeAttachHandler" {
                DispatchQueue.main.async {
                    self.showTwoOptionAttachSheet()
                }
                return
            }

            if message.name == "exportHtmlHandler", let htmlString = message.body as? String {
                let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("multimodal-ai-chat-liquid-glass.html")
                do {
                    try htmlString.write(to: tempURL, atomically: true, encoding: .utf8)
                    DispatchQueue.main.async {
                        let activityVC = UIActivityViewController(activityItems: [tempURL], applicationActivities: nil)
                        self.presentViewController(activityVC)
                    }
                } catch {
                    print("Lỗi xuất file HTML: \(error)")
                }
            }
        }

        private func showTwoOptionAttachSheet() {
            let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)

            sheet.addAction(UIAlertAction(title: "Thư viện ảnh (Photo Library)", style: .default) { _ in
                var config = PHPickerConfiguration()
                config.selectionLimit = 5
                config.filter = .images
                let picker = PHPickerViewController(configuration: config)
                picker.delegate = self
                self.presentViewController(picker)
            })

            sheet.addAction(UIAlertAction(title: "Chọn tệp (Choose Files)", style: .default) { _ in
                let docPicker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
                docPicker.allowsMultipleSelection = true
                docPicker.delegate = self
                self.presentViewController(docPicker)
            })

            sheet.addAction(UIAlertAction(title: "Hủy", style: .cancel))
            presentViewController(sheet)
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            for result in results {
                let provider = result.itemProvider
                if provider.canLoadObject(ofClass: UIImage.self) {
                    provider.loadObject(ofClass: UIImage.self) { object, _ in
                        if let image = object as? UIImage, let jpegData = image.jpegData(compressionQuality: 0.85) {
                            let base64 = jpegData.base64EncodedString()
                            let fileName = "photo_\(Int(Date().timeIntervalSince1970)).jpg"
                            self.sendFileToWeb(
                                name: fileName,
                                size: jpegData.count,
                                mimeType: "image/jpeg",
                                base64: base64,
                                category: "image",
                                textContent: nil
                            )
                        }
                    }
                }
            }
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            let textExts = ["txt", "csv", "json", "md", "js", "py", "html", "ts", "jsx", "tsx", "css", "sql", "sh"]
            for url in urls {
                guard let data = try? Data(contentsOf: url) else { continue }
                let name = url.lastPathComponent
                let ext = url.pathExtension.lowercased()

                if textExts.contains(ext), let textStr = String(data: data, encoding: .utf8) {
                    sendFileToWeb(name: name, size: data.count, mimeType: "text/plain", base64: nil, category: "text", textContent: textStr)
                } else {
                    let mime: String
                    let cat: String
                    if ["jpg", "jpeg"].contains(ext) { mime = "image/jpeg"; cat = "image" }
                    else if ext == "png" { mime = "image/png"; cat = "image" }
                    else if ext == "webp" { mime = "image/webp"; cat = "image" }
                    else if ext == "pdf" { mime = "application/pdf"; cat = "document" }
                    else { mime = "application/octet-stream"; cat = "document" }

                    sendFileToWeb(name: name, size: data.count, mimeType: mime, base64: data.base64EncodedString(), category: cat, textContent: nil)
                }
            }
        }

        private func sendFileToWeb(name: String, size: Int, mimeType: String, base64: String?, category: String, textContent: String?) {
            var dict: [String: Any] = [
                "name": name,
                "size": size,
                "mimeType": mimeType,
                "category": category
            ]
            if let b64 = base64 {
                dict["dataBase64"] = b64
                dict["previewUrl"] = "data:\(mimeType);base64,\(b64)"
            }
            if let txt = textContent {
                dict["textContent"] = txt
            }

            if let jsonData = try? JSONSerialization.data(withJSONObject: dict),
               let jsonStr = String(data: jsonData, encoding: .utf8) {
                DispatchQueue.main.async {
                    self.webView?.evaluateJavaScript("window.receiveNativeFile(\(jsonStr));", completionHandler: nil)
                }
            }
        }

        private func presentViewController(_ vc: UIViewController) {
            DispatchQueue.main.async {
                if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                   let rootVC = windowScene.windows.first?.rootViewController {
                    if let popover = vc.popoverPresentationController {
                        popover.sourceView = rootVC.view
                        popover.sourceRect = CGRect(x: rootVC.view.bounds.midX, y: rootVC.view.bounds.midY, width: 0, height: 0)
                        popover.permittedArrowDirections = []
                    }
                    rootVC.present(vc, animated: true)
                }
            }
        }

        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
            presentViewController(alert)
        }

        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Hủy", style: .cancel) { _ in completionHandler(false) })
            alert.addAction(UIAlertAction(title: "Xác nhận", style: .destructive) { _ in completionHandler(true) })
            presentViewController(alert)
        }

        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
            let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
            alert.addTextField { textField in textField.text = defaultText }
            alert.addAction(UIAlertAction(title: "Hủy", style: .cancel) { _ in completionHandler(nil) })
            alert.addAction(UIAlertAction(title: "Lưu", style: .default) { _ in
                completionHandler(alert.textFields?.first?.text)
            })
            presentViewController(alert)
        }
    }
}

let embeddedHTML = #"""
<!DOCTYPE html>
<html lang="vi" class="dark">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no, viewport-fit=cover" />
  <title>Multimodal AI Chat • Liquid Glass Edition</title>
  <meta name="description" content="Multimodal AI Chat with Liquid Glass UI, high-performance SSE stream processing, and multi-endpoint support." />

  <!-- Tailwind CSS CDN -->
  <script src="https://cdn.tailwindcss.com"></script>
  <script>
    tailwind.config = {
      darkMode: "class",
      theme: {
        extend: {
          fontFamily: {
            sans: ['-apple-system', 'BlinkMacSystemFont', '"SF Pro Text"', '"SF Pro Display"', '"Plus Jakarta Sans"', 'Inter', 'system-ui', 'sans-serif'],
            mono: ['"SF Mono"', '"JetBrains Mono"', 'Menlo', 'Monaco', 'Consolas', 'monospace']
          },
          colors: {
            liquid: {
              void: '#07080e',
              deep: '#0d0f18',
              card: 'rgba(18, 20, 32, 0.65)',
              border: 'rgba(255, 255, 255, 0.12)',
              glow: 'rgba(139, 92, 246, 0.25)'
            }
          }
        }
      }
    }
  </script>

  <!-- Marked.js & Highlight.js -->
  <script src="https://cdn.jsdelivr.net/npm/marked/marked.min.js"></script>
  <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/styles/atom-one-dark.min.css" />
  <script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/highlight.min.js"></script>

  <style>
    :root {
      --accent-primary: #8b5cf6;
      --accent-secondary: #6366f1;
      --accent-light: #c4b5fd;
      --accent-glow: rgba(124, 58, 237, 0.35);
      --accent-soft: rgba(139, 92, 246, 0.22);
      --accent-border: rgba(167, 139, 250, 0.4);
      --orb-1: radial-gradient(circle, rgba(124, 58, 237, 0.28), rgba(79, 70, 229, 0.12));
      --orb-2: radial-gradient(circle, rgba(6, 182, 212, 0.2), rgba(59, 130, 246, 0.1));
      --orb-3: radial-gradient(circle, rgba(236, 72, 153, 0.14), rgba(139, 92, 246, 0.08));
    }

    html, body {
      height: 100%; width: 100%; margin: 0; padding: 0;
      overflow: hidden; position: fixed; inset: 0;
      touch-action: none;
      overscroll-behavior: none; -webkit-overflow-scrolling: touch;
      background-color: #07080e;
      -webkit-text-size-adjust: 100%;
    }
    html:not(.dark), html:not(.dark) body { background-color: #f3f4f8; color: #18181b; }

    /* === DYNAMIC ACCENT CLASSES === */
    .accent-gradient-bg {
      background: linear-gradient(135deg, var(--accent-primary), var(--accent-secondary)) !important;
      box-shadow: 0 4px 18px var(--accent-glow) !important;
    }
    .accent-badge {
      background: var(--accent-soft) !important;
      border-color: var(--accent-border) !important;
      color: var(--accent-light) !important;
    }
    html:not(.dark) .accent-badge {
      color: var(--accent-primary) !important;
    }
    .accent-focus:focus-within {
      border-color: var(--accent-primary) !important;
      box-shadow: 0 12px 40px var(--accent-glow) !important;
    }

    /* === HIỆU ỨNG ÁNH SÁNG MÔI TRƯỜNG LIQUID (AMBIENT LIGHTS) === */
    .ambient-mesh {
      position: fixed;
      inset: 0;
      pointer-events: none;
      z-index: 0;
      overflow: hidden;
    }
    .ambient-orb {
      position: absolute;
      border-radius: 9999px;
      filter: blur(85px);
      transform: translateZ(0);
      will-change: transform, opacity;
      animation: floatOrb 18s ease-in-out infinite alternate;
      transition: background 0.5s ease;
    }
    .orb-1 {
      width: 420px; height: 420px; top: -100px; left: -80px;
      background: var(--orb-1);
    }
    .orb-2 {
      width: 480px; height: 480px; bottom: 5%; right: -120px;
      background: var(--orb-2);
      animation-duration: 24s;
    }
    .orb-3 {
      width: 320px; height: 320px; top: 35%; left: 30%;
      background: var(--orb-3);
      animation-duration: 20s;
    }

    @keyframes floatOrb {
      0% { transform: translate(0, 0) scale(1); }
      50% { transform: translate(30px, 40px) scale(1.08); }
      100% { transform: translate(-20px, 20px) scale(0.95); }
    }

    /* === LIQUID GLASS SURFACES === */
    .glass-surface {
      background: rgba(13, 15, 24, 0.65);
      backdrop-filter: blur(24px) saturate(190%);
      -webkit-backdrop-filter: blur(24px) saturate(190%);
      border: 1px solid rgba(255, 255, 255, 0.1);
      box-shadow: inset 0 1px 1px 0 rgba(255, 255, 255, 0.12), 0 12px 36px 0 rgba(0, 0, 0, 0.35);
    }
    html:not(.dark) .glass-surface {
      background: rgba(255, 255, 255, 0.78);
      border: 1px solid rgba(0, 0, 0, 0.08);
      box-shadow: inset 0 1px 1px 0 rgba(255, 255, 255, 0.9), 0 10px 30px 0 rgba(0, 0, 0, 0.06);
      color: #18181b;
    }

    .glass-card-user {
      background: linear-gradient(135deg, var(--accent-soft), rgba(99, 102, 241, 0.12));
      backdrop-filter: blur(20px) saturate(180%);
      -webkit-backdrop-filter: blur(20px) saturate(180%);
      border: 1px solid var(--accent-border);
      box-shadow: inset 0 1px 1px 0 rgba(255, 255, 255, 0.2), 0 6px 20px 0 var(--accent-glow);
    }
    html:not(.dark) .glass-card-user {
      color: #18181b;
    }

    .glass-btn {
      background: rgba(255, 255, 255, 0.06);
      backdrop-filter: blur(14px);
      -webkit-backdrop-filter: blur(14px);
      border: 1px solid rgba(255, 255, 255, 0.1);
      box-shadow: inset 0 1px 0.5px rgba(255, 255, 255, 0.15);
      transition: all 0.2s cubic-bezier(0.16, 1, 0.3, 1);
    }
    .glass-btn:hover {
      background: rgba(255, 255, 255, 0.12);
      border-color: rgba(255, 255, 255, 0.22);
      transform: translateY(-0.5px);
    }
    .glass-btn:active {
      transform: scale(0.96);
    }
    html:not(.dark) .glass-btn {
      background: rgba(0, 0, 0, 0.05);
      border: 1px solid rgba(0, 0, 0, 0.09);
      box-shadow: inset 0 1px 0.5px rgba(255, 255, 255, 0.7);
      color: #27272a;
    }
    html:not(.dark) .glass-btn:hover {
      background: rgba(0, 0, 0, 0.09);
    }

    /* Light Mode Text Overrides */
    html:not(.dark) header { background: rgba(255, 255, 255, 0.8) !important; border-color: rgba(0, 0, 0, 0.08) !important; }
    html:not(.dark) header h1, html:not(.dark) #emptyStateTitle { color: #09090b !important; }
    html:not(.dark) #messageInput { color: #09090b !important; }
    html:not(.dark) #chatSidebar { background: rgba(250, 250, 252, 0.92) !important; border-color: rgba(0, 0, 0, 0.1) !important; }
    html:not(.dark) #sidebarTitle { color: #09090b !important; }
    html:not(.dark) .text-zinc-200 { color: #27272a !important; }
    html:not(.dark) .text-zinc-300 { color: #3f3f46 !important; }
    html:not(.dark) .text-zinc-400 { color: #52525b !important; }

    /* Scrollbars */
    ::-webkit-scrollbar { width: 5px; height: 5px; }
    ::-webkit-scrollbar-track { background: transparent; }
    ::-webkit-scrollbar-thumb { background: rgba(255, 255, 255, 0.15); border-radius: 9999px; }
    ::-webkit-scrollbar-thumb:hover { background: rgba(255, 255, 255, 0.25); }

    /* Typography & Prose */
    body, .prose-content {
      -webkit-font-smoothing: antialiased;
      -moz-osx-font-smoothing: grayscale;
      text-rendering: optimizeLegibility;
      font-kerning: normal;
    }
    .prose-content {
      font-size: 0.94rem;
      line-height: 1.68;
      color: #e2e4ed;
      overflow-wrap: break-word;
      word-wrap: break-word;
      min-height: 1em;
    }
    html:not(.dark) .prose-content { color: #1e2029; }
    .prose-content p { margin-bottom: 0.85rem; }
    .prose-content p:last-child { margin-bottom: 0; }
    .prose-content h1, .prose-content h2, .prose-content h3 {
      font-weight: 700; margin: 1.1rem 0 0.55rem; color: #ffffff; letter-spacing: -0.015em;
    }
    html:not(.dark) .prose-content h1, html:not(.dark) .prose-content h2, html:not(.dark) .prose-content h3 { color: #07080e; }
    .prose-content ul, .prose-content ol { margin: 0.5rem 0 0.85rem 1.25rem; }
    .prose-content ul { list-style-type: disc; }
    .prose-content ol { list-style-type: decimal; }
    .prose-content li { margin-bottom: 0.3rem; }
    .prose-content blockquote {
      border-left: 3px solid var(--accent-primary); padding-left: 0.85rem; font-style: italic; color: #9499ad; margin: 0.85rem 0;
      background: var(--accent-soft); border-radius: 0 0.5rem 0.5rem 0; padding-top: 0.25rem; padding-bottom: 0.25rem;
    }
    .prose-content table { width: 100%; border-collapse: collapse; margin: 0.85rem 0; font-size: 0.875rem; }
    .prose-content th, .prose-content td { border: 1px solid rgba(255, 255, 255, 0.1); padding: 0.55rem 0.8rem; text-align: left; }
    html:not(.dark) .prose-content th, html:not(.dark) .prose-content td { border-color: rgba(0, 0, 0, 0.1); }
    .prose-content th { background: rgba(255, 255, 255, 0.07); color: #fff; font-weight: 600; }
    html:not(.dark) .prose-content th { background: rgba(0, 0, 0, 0.05); color: #000; }

    .prose-content :not(pre) > code {
      background: var(--accent-soft); border: 1px solid var(--accent-border); color: var(--accent-light);
      padding: 0.15rem 0.4rem; border-radius: 0.375rem; font-size: 0.86em;
      font-family: inherit;
    }
    html:not(.dark) .prose-content :not(pre) > code {
      color: var(--accent-primary);
    }

    .code-block-wrapper {
      position: relative; margin: 0.9rem 0; border-radius: 0.85rem;
      overflow: hidden; border: 1px solid rgba(255, 255, 255, 0.12);
      background: rgba(9, 10, 16, 0.88);
      box-shadow: inset 0 1px 1px rgba(255, 255, 255, 0.06), 0 8px 24px rgba(0, 0, 0, 0.4);
    }
    .code-block-header {
      display: flex; align-items: center; justify-content: space-between;
      padding: 0.45rem 0.85rem; background: rgba(255, 255, 255, 0.04);
      border-bottom: 1px solid rgba(255, 255, 255, 0.08);
      font-size: 0.75rem; user-select: none;
    }
    .code-block-wrapper pre { margin: 0; padding: 0.85rem 1rem; overflow-x: auto; background: transparent !important; }
    .code-block-wrapper pre code { font-size: 0.85rem; line-height: 1.55; }

    .citation-link {
      color: var(--accent-light); text-decoration: underline; text-underline-offset: 2px;
      text-decoration-color: var(--accent-border); font-weight: 500;
    }
    .citation-link:hover { opacity: 0.85; }

    #streamingBubble { contain: layout style; }
    #messageInput, .ios-fix-input, select, textarea { font-size: 16px !important; }

    @keyframes pulseGlow { 0%, 100% { opacity: 0.35; transform: scale(0.85); } 50% { opacity: 1; transform: scale(1.15); } }
    .typing-dot { animation: pulseGlow 1.3s infinite ease-in-out; }
    .typing-dot:nth-child(2) { animation-delay: 0.22s; }
    .typing-dot:nth-child(3) { animation-delay: 0.44s; }
  </style>
</head>
<body class="bg-[#07080e] text-zinc-100 flex flex-col font-sans antialiased select-auto transition-colors duration-200">

  <!-- Hiệu ứng khúc xạ ánh sáng Liquid Glass ngầm -->
  <div class="ambient-mesh">
    <div class="ambient-orb orb-1"></div>
    <div class="ambient-orb orb-2"></div>
    <div class="ambient-orb orb-3"></div>
  </div>

  <!-- Backdrop cho Sidebar -->
  <div id="sidebarBackdrop" class="hidden fixed inset-0 z-40 bg-black/60 backdrop-blur-md transition-opacity duration-300"></div>

  <!-- SIDEBAR (Kính lỏng Liquid Glass) -->
  <aside id="chatSidebar" class="fixed top-0 left-0 bottom-0 z-50 w-72 sm:w-80 bg-[#0a0c16]/85 backdrop-blur-3xl border-r border-white/10 flex flex-col transition-transform duration-300 -translate-x-full shadow-2xl">
    <div class="p-3.5 border-b border-white/10 flex items-center justify-between">
      <div class="flex items-center gap-2.5">
        <div class="w-8 h-8 rounded-xl accent-badge border flex items-center justify-center font-bold text-sm shadow-inner">✦</div>
        <div>
          <h2 id="sidebarTitle" class="font-semibold text-xs sm:text-sm text-zinc-100">Lịch sử trò chuyện</h2>
          <p id="sidebarSubtitle" class="text-[10px] text-zinc-400 font-light">Quản lý cuộc trò chuyện</p>
        </div>
      </div>
      <button id="closeSidebarBtn" class="p-1.5 rounded-xl hover:bg-white/10 text-zinc-400 hover:text-white transition text-sm">✕</button>
    </div>

    <div class="p-3 border-b border-white/10 flex flex-col gap-2">
      <button id="newSessionBtn" class="w-full py-2.5 px-3.5 rounded-xl accent-gradient-bg text-white font-semibold text-xs flex items-center justify-center gap-2 transition active:scale-95">
        <span>➕</span><span id="newSessionLabel">Cuộc trò chuyện mới</span>
      </button>
    </div>

    <div id="sessionsList" class="flex-1 overflow-y-auto p-2 space-y-1.5"></div>

    <div class="p-3 border-t border-white/10 text-[11px] text-zinc-400 flex items-center justify-between">
      <span class="flex items-center gap-1 text-[10px]"><span>📱</span><span id="swipeHintLabel">Vuốt mép để mở</span></span>
      <button id="clearAllSessionsBtn" class="text-rose-400 hover:text-rose-300 hover:underline text-[10px] transition">Xóa tất cả</button>
    </div>
  </aside>

  <!-- APP ROOT -->
  <div id="appRoot" class="fixed inset-0 w-full h-full flex flex-col overflow-hidden box-border z-10">

    <!-- HEADER / NAVBAR -->
    <header class="flex-shrink-0 border-b border-white/10 bg-[#090b14]/75 backdrop-blur-2xl px-3 sm:px-4 py-2.5 sm:py-3 z-30 flex items-center justify-between shadow-[0_4px_24px_rgba(0,0,0,0.25)]">
      <div class="flex items-center gap-2 sm:gap-3">
        <button id="sidebarToggleBtn" class="h-9 w-9 flex items-center justify-center rounded-xl glass-btn text-zinc-200 hover:text-white transition">☰</button>
        <div class="w-8 h-8 rounded-xl accent-badge border flex items-center justify-center font-bold text-sm shadow-inner">✦</div>
        <div>
          <div class="flex items-center gap-2">
            <h1 class="font-semibold text-xs sm:text-sm tracking-tight text-white drop-shadow-sm">Multimodal AI Chat</h1>
            <span id="currentModelBadge" class="hidden xs:flex items-center gap-1.5 text-[10px] font-mono px-2 py-0.5 rounded-full bg-white/5 border border-white/10 text-zinc-300 backdrop-blur-md"></span>
          </div>
        </div>
      </div>

      <div class="flex items-center gap-1.5 sm:gap-2">
        <button id="headerSearchToggleBtn" class="hidden sm:inline-flex items-center gap-1.5 px-2.5 py-1 rounded-xl text-[11px] font-medium border transition cursor-pointer glass-btn">
          <span class="text-xs">🌐</span>
          <span id="headerSearchStatusText">Search: BẬT</span>
        </button>

        <span id="thinkingHeaderBadge" class="hidden md:inline-flex items-center gap-1 px-2.5 py-1 rounded-xl text-[10px] font-mono bg-amber-400/15 text-amber-300 border border-amber-400/30 backdrop-blur-md">
          <span>🧠</span><span id="thinkingHeaderLabel">THẤP</span>
        </span>

        <button id="langToggleBtn" class="flex items-center gap-1 px-2.5 py-1.5 rounded-xl glass-btn text-zinc-200 hover:text-white text-xs font-semibold">
          <span>🌐</span><span id="langToggleLabel">EN</span>
        </button>

        <button id="exportHtmlBtn" class="flex items-center gap-1.5 px-2.5 py-1.5 rounded-xl glass-btn accent-badge text-xs">
          <span>💾</span><span id="exportHtmlBtnLabel" class="hidden sm:inline">Xuất HTML</span>
        </button>

        <button id="themeToggleBtn" class="p-2 rounded-xl glass-btn text-zinc-300 hover:text-white text-xs">🌙</button>

        <button id="openSettingsBtn" class="flex items-center gap-1.5 px-3 py-1.5 rounded-xl bg-white/90 hover:bg-white text-zinc-950 font-semibold text-xs active:scale-95 transition shadow-[0_2px_12px_rgba(255,255,255,0.2)]">
          <span>⚙️</span><span id="openSettingsLabel" class="hidden xs:inline">Cài đặt</span>
        </button>
      </div>
    </header>

    <!-- KHUNG CHAT CHÍNH -->
    <main id="chatMain" class="flex-1 min-h-0 overflow-y-auto px-3 sm:px-4 py-4 space-y-4 scroll-smooth relative">
      <div id="emptyState" class="flex flex-col items-center justify-center py-12 sm:py-16 px-4 text-center">
        <div class="w-16 h-16 rounded-2xl glass-surface flex items-center justify-center text-3xl mb-4 accent-badge border">✦</div>
        <h2 id="emptyStateTitle" class="text-lg font-bold text-white mb-2">Sẵn sàng phản hồi</h2>
        <p id="emptyStateSub" class="text-xs text-zinc-400 max-w-md mb-5 font-light leading-relaxed">
          Hỗ trợ kết nối Google Gemini API trực tiếp hoặc máy chủ tùy chỉnh (OpenAI-compatible / Ollama / OneAPI / Groq).
        </p>
        <div class="flex flex-wrap gap-2 justify-center max-w-lg">
          <button id="quickPrompt1" onclick="quickPrompt(this.innerText)" class="text-[11px] px-3.5 py-2 rounded-xl glass-btn text-zinc-300">
            🌐 Tin tức công nghệ mới & nguồn
          </button>
          <button id="quickPrompt2" onclick="quickPrompt(this.innerText)" class="text-[11px] px-3.5 py-2 rounded-xl glass-btn text-zinc-300">
            🐍 Python parse JSON chuẩn
          </button>
          <button id="quickPrompt3" onclick="quickPrompt('/image ')" class="text-[11px] px-3.5 py-2 rounded-xl glass-btn accent-badge font-semibold">
            🎨 Tạo ảnh bằng AI
          </button>
        </div>
      </div>

      <div id="messagesContainer" class="max-w-4xl mx-auto space-y-4 pb-4"></div>

      <button id="scrollToBottomBtn" class="hidden fixed bottom-28 right-6 z-20 px-3.5 py-2 rounded-full glass-surface text-zinc-200 border border-white/20 shadow-2xl text-xs flex items-center gap-1.5 hover:text-white transition active:scale-95">
        <span id="scrollToBottomLabel">↓ Cuộn xuống cuối</span>
      </button>
    </main>

    <!-- ERROR BANNER -->
    <div id="errorBanner" class="hidden max-w-4xl mx-auto w-full px-3 mb-2 flex-shrink-0">
      <div class="p-3.5 rounded-2xl bg-red-950/70 border border-red-500/40 text-red-200 text-xs flex items-start gap-2 shadow-xl backdrop-blur-xl">
        <span class="text-sm">⚠️</span>
        <div id="errorMessage" class="flex-1 font-sans leading-relaxed"></div>
        <button onclick="hideError()" class="text-zinc-400 hover:text-white text-xs px-1">✕</button>
      </div>
    </div>

    <!-- KHU VỰC NHẬP LIỆU DOCK KÍNH LỎNG (FLOATING LIQUID DOCK) -->
    <footer id="stickyInputFooter" class="flex-shrink-0 z-20 w-full px-3 sm:px-4 py-3 pb-[max(0.75rem,env(safe-area-inset-bottom,0.75rem))]">
      <div class="max-w-4xl mx-auto w-full">
        <!-- Tệp đính kèm -->
        <div id="filePreviewBar" class="hidden flex flex-wrap gap-2 mb-2 p-2 rounded-2xl glass-surface max-h-32 overflow-y-auto"></div>

        <div class="glass-surface rounded-3xl p-2.5 sm:p-3 shadow-[0_12px_40px_rgba(0,0,0,0.45)] transition-all duration-300 accent-focus">
          <form id="chatForm" class="flex flex-col gap-2">
            <div class="flex items-center justify-between pb-1 px-1 border-b border-white/10 text-xs">
              <div class="flex items-center gap-2">
                <button type="button" id="webSearchToggleBtn" class="flex items-center gap-1.5 px-2.5 py-1 rounded-xl text-[11px] font-medium border transition cursor-pointer glass-btn">
                  <span class="text-xs">🌐</span>
                  <span id="webSearchBtnText">Google Search: BẬT</span>
                  <span id="webSearchIndicator" class="w-1.5 h-1.5 rounded-full bg-emerald-400 shadow-[0_0_8px_#34d399]"></span>
                </button>
                <span id="fileCountBadge" class="hidden text-[11px] accent-badge font-medium px-2 py-0.5 rounded-lg border"></span>
              </div>
              <span id="inputHintLabel" class="hidden sm:inline text-zinc-400 text-[11px]">Enter: Xuống dòng • Bấm nút Gửi để gửi tin nhắn</span>
            </div>

            <div class="flex items-end gap-2 pt-0.5">
              <input type="file" id="fileInput" class="hidden" multiple accept=".jpg,.jpeg,.png,.webp,.gif,.heic,.pdf,.txt,.csv,.json,.md,.js,.py,.html,.ts,.mp3,.wav,.m4a" />
              <button type="button" id="attachFileBtn" class="h-10 w-10 flex items-center justify-center rounded-2xl glass-btn text-zinc-300 hover:text-white transition flex-shrink-0 active:scale-95" title="Đính kèm tệp tin/hình ảnh">📎</button>

              <textarea id="messageInput" rows="1" placeholder="Nhập câu hỏi... (Gõ /image để vẽ ảnh)" class="flex-1 max-h-36 min-h-[40px] bg-transparent border-0 text-white placeholder-zinc-500 px-2 py-2 focus:outline-none resize-none leading-relaxed" style="font-size: 16px !important;"></textarea>

              <div class="flex items-center gap-1.5 flex-shrink-0">
                <button type="button" id="stopBtn" class="hidden h-10 px-3.5 items-center gap-1.5 rounded-2xl border border-red-500/50 bg-red-950/60 text-red-200 text-xs font-semibold animate-pulse shadow-lg backdrop-blur-md">
                  <span id="stopBtnLabel">⏹️ Dừng</span>
                </button>
                <button type="submit" id="sendBtn" class="h-10 px-4 rounded-2xl accent-gradient-bg text-white font-semibold text-xs transition active:scale-95 flex items-center gap-1.5">
                  <span id="sendBtnLabel">Gửi</span>
                  <span>→</span>
                </button>
              </div>
            </div>
          </form>
        </div>
      </div>
    </footer>

    <!-- CÀI ĐẶT MODAL (Kính lỏng Liquid Glass) -->
    <div id="settingsModal" class="hidden absolute inset-0 z-50 bg-black/70 backdrop-blur-2xl flex items-center justify-center p-3 sm:p-4">
      <div class="glass-surface rounded-3xl max-w-lg w-full p-4 sm:p-6 shadow-2xl space-y-4 text-zinc-100 max-h-full flex flex-col border border-white/15">
        
        <div class="flex items-center justify-between border-b border-white/10 pb-3 flex-shrink-0">
          <h3 class="font-semibold text-sm text-white flex items-center gap-2">
            <span>⚙</span><span id="settingsModalTitle">Cài đặt API & Mô hình</span>
          </h3>
          <button id="closeSettingsBtn" class="text-zinc-400 hover:text-white p-1 text-sm rounded-lg hover:bg-white/10 transition">✕</button>
        </div>

        <div id="settingsModalScroll" class="space-y-4 text-xs overflow-y-auto pr-1 flex-1 pb-16">
          
          <!-- CHỌN CHỦ ĐỀ MÀU GIAO DIỆN (ACCENT COLOR THEME) -->
          <div class="p-3.5 rounded-2xl glass-surface space-y-2.5">
            <label id="lblAccentTheme" class="text-zinc-400 uppercase font-semibold text-[10px] block">🎨 Màu sắc chủ đạo (Liquid Theme)</label>
            <div class="grid grid-cols-5 gap-2" id="accentThemeGrid">
              <button type="button" data-accent="violet" class="accent-option flex flex-col items-center gap-1 p-2 rounded-xl border border-white/10 glass-btn">
                <span class="w-5 h-5 rounded-full bg-gradient-to-br from-violet-500 to-indigo-600 shadow-md"></span>
                <span class="text-[9px] font-medium">Violet</span>
              </button>
              <button type="button" data-accent="ocean" class="accent-option flex flex-col items-center gap-1 p-2 rounded-xl border border-white/10 glass-btn">
                <span class="w-5 h-5 rounded-full bg-gradient-to-br from-cyan-400 to-blue-600 shadow-md"></span>
                <span class="text-[9px] font-medium">Ocean</span>
              </button>
              <button type="button" data-accent="emerald" class="accent-option flex flex-col items-center gap-1 p-2 rounded-xl border border-white/10 glass-btn">
                <span class="w-5 h-5 rounded-full bg-gradient-to-br from-emerald-400 to-teal-600 shadow-md"></span>
                <span class="text-[9px] font-medium">Emerald</span>
              </button>
              <button type="button" data-accent="rose" class="accent-option flex flex-col items-center gap-1 p-2 rounded-xl border border-white/10 glass-btn">
                <span class="w-5 h-5 rounded-full bg-gradient-to-br from-rose-400 to-pink-600 shadow-md"></span>
                <span class="text-[9px] font-medium">Rose</span>
              </button>
              <button type="button" data-accent="amber" class="accent-option flex flex-col items-center gap-1 p-2 rounded-xl border border-white/10 glass-btn">
                <span class="w-5 h-5 rounded-full bg-gradient-to-br from-amber-400 to-orange-600 shadow-md"></span>
                <span class="text-[9px] font-medium">Amber</span>
              </button>
            </div>
          </div>

          <!-- TABS NHÀ CUNG CẤP -->
          <div class="p-1 glass-btn rounded-xl flex gap-1 text-[11px] font-semibold text-center">
             <button id="tabNativeApi" class="flex-1 py-2 rounded-lg accent-badge shadow-sm transition border">✦ Google Gemini (Native)</button>
             <button id="tabCustomApi" class="flex-1 py-2 rounded-lg text-zinc-400 hover:text-zinc-200 transition">🌐 Custom OpenAI Endpoint</button>
          </div>

          <!-- GEMINI NATIVE -->
          <div id="nativeConfigArea" class="p-3.5 rounded-2xl glass-surface space-y-2.5">
            <div class="flex items-center justify-between">
              <label id="lblGeminiKey" class="font-semibold text-xs flex items-center gap-1.5">
                Google Gemini API Key
              </label>
              <div class="flex items-center gap-2">
                <button type="button" id="testApiKeyBtn" class="px-2.5 py-1 rounded-lg glass-btn text-[10px] font-semibold">⚡ Kiểm tra kết nối</button>
                <a href="https://aistudio.google.com/app/apikey" target="_blank" rel="noreferrer" id="linkGetKey" class="text-[10px] citation-link flex items-center gap-0.5">Lấy Key ↗</a>
              </div>
            </div>
            <input type="password" id="apiKeyInput" placeholder="AIzaSy..." class="w-full bg-white/5 border border-white/10 rounded-xl px-3 py-2 text-zinc-100 font-mono text-xs focus:outline-none transition" />
            <p class="text-[9px] text-zinc-400 italic">* Kết nối trực tiếp đến Google AI Studio, hỗ trợ đầy đủ Search, File, Safety Settings.</p>
          </div>

          <!-- CUSTOM PROVIDER -->
          <div id="customConfigArea" class="hidden p-3.5 rounded-2xl glass-surface space-y-3">
            <div>
              <label id="lblCustomEndpoint" class="text-[10px] text-zinc-400 block mb-1">API Endpoint URL (Base URL):</label>
              <input type="text" id="customEndpointInput" placeholder="https://api.openai.com/v1" class="w-full bg-white/5 border border-white/10 rounded-xl px-3 py-2 text-zinc-100 font-mono text-xs focus:outline-none" />
            </div>
            <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
              <div>
                <label id="lblCustomKey" class="text-[10px] text-zinc-400 block mb-1">API Key của Endpoint:</label>
                <input type="password" id="customApiKeyInput" placeholder="sk-..." class="w-full bg-white/5 border border-white/10 rounded-xl px-3 py-2 text-zinc-100 font-mono text-xs focus:outline-none" />
              </div>
              <div>
                <label id="lblCustomModel" class="text-[10px] text-zinc-400 block mb-1">Tên Model Tùy Chỉnh:</label>
                <input type="text" id="customModelInput" placeholder="gemini-4-hydrogen, gpt-4o..." class="w-full bg-white/5 border border-white/10 rounded-xl px-3 py-2 text-zinc-100 font-mono text-xs focus:outline-none" />
              </div>
            </div>
            <div class="flex items-center justify-between">
              <p id="lblCustomNote" class="text-[9px] text-zinc-400 italic flex-1">
                * Yêu cầu gửi đi sẽ được biên dịch sang định dạng chuẩn của OpenAI.
              </p>
              <button type="button" id="testCustomKeyBtn" class="px-2.5 py-1 rounded-lg glass-btn text-[10px] font-semibold text-zinc-300">⚡ Kiểm tra kết nối</button>
            </div>
          </div>
          
          <div id="testKeyStatus" class="hidden text-[10px] px-2.5 py-1.5 rounded-xl border leading-tight backdrop-blur-md"></div>

          <!-- MODEL SELECT -->
          <div class="space-y-2">
            <div class="flex items-center justify-between">
              <label id="lblModelConfig" class="text-zinc-400 uppercase font-semibold text-[10px]">Cấu hình Mô hình (Model)</label>
              <button type="button" id="fetchModelsBtn" class="px-2.5 py-0.5 rounded-lg glass-btn text-[10px] text-zinc-300 hover:text-white transition">🔄 Quét models</button>
            </div>
            <div>
              <input type="text" id="modelCustomInput" placeholder="gemini-4-hydrogen, gemini-4-argon, gemini-4-carbon..." class="w-full bg-white/5 border border-white/10 rounded-xl px-3 py-2 text-zinc-100 font-mono text-xs focus:outline-none" />
            </div>
            <div>
              <select id="modelSelect" class="w-full bg-[#0a0c16] border border-white/10 rounded-xl px-3 py-2 text-zinc-200 text-xs focus:outline-none">
                <option value="gemini-4-hydrogen">gemini-4-hydrogen (Mới • Nhanh & Tư duy)</option>
                <option value="gemini-4-argon">gemini-4-argon (Mới • Cân bằng & Đa năng)</option>
                <option value="gemini-4-carbon">gemini-4-carbon (Mới • Lập luận cực sâu)</option>
                <option value="gemini-2.5-flash">gemini-2.5-flash (Thế hệ trước • Nhanh)</option>
                <option value="gemini-2.5-pro">gemini-2.5-pro (Thế hệ trước • Pro)</option>
                <option value="gemini-2.0-flash">gemini-2.0-flash</option>
              </select>
            </div>
            <div id="fetchStatusText" class="hidden text-[10px] mt-1 px-2 py-1 rounded-xl border backdrop-blur-md"></div>
          </div>

          <!-- SYSTEM INSTRUCTION -->
          <div class="pt-3 border-t border-white/10">
            <div class="flex justify-between items-center mb-1.5">
              <label id="lblSysPrompt" class="text-zinc-400 text-[10px] uppercase font-semibold">Chỉ thị hệ thống (System Instruction)</label>
              <div class="flex gap-1">
                <select id="presetSelect" class="bg-[#0a0c16] border border-white/10 text-zinc-200 text-[10px] rounded-lg px-2 py-0.5 focus:outline-none max-w-[130px] truncate"></select>
                <button id="addPresetBtn" type="button" class="px-2 py-0.5 glass-btn text-zinc-300 rounded-lg text-[10px]">➕ Thêm</button>
                <button id="delPresetBtn" type="button" class="px-2 py-0.5 glass-btn bg-red-950/40 text-red-300 border-red-500/30 rounded-lg text-[10px]">🗑 Xóa</button>
              </div>
            </div>
            <textarea id="systemInstructionInput" rows="2" placeholder="Ví dụ: Bạn là trợ lý lập trình chuyên nghiệp..." class="w-full bg-white/5 border border-white/10 rounded-xl p-2.5 text-zinc-100 text-xs focus:outline-none resize-none leading-relaxed"></textarea>
          </div>

          <!-- THINKING LEVEL -->
          <div class="pt-3 border-t border-white/10 space-y-2">
            <div class="flex items-center justify-between">
              <label id="lblThinkingTitle" class="text-[10px] uppercase tracking-wider font-semibold text-zinc-300 flex items-center gap-1">
                <span>🧠</span> Mức độ tư duy (Thinking Level)
              </label>
            </div>
            <div class="grid grid-cols-2 sm:grid-cols-4 gap-1.5" id="thinkingButtons">
              <button type="button" data-level="off" class="thinking-btn p-2 rounded-xl border border-white/10 glass-btn text-left">
                <div class="font-semibold text-xs">⚡ Off</div>
                <span id="lblThinkOff" class="text-[9px] text-zinc-500 font-mono">Tắt</span>
              </button>
              <button type="button" data-level="minimal" class="thinking-btn p-2 rounded-xl border border-white/10 glass-btn text-left">
                <div class="font-semibold text-xs">🧘 Min</div>
                <span id="lblThinkMin" class="text-[9px] text-zinc-500 font-mono">Tối giản</span>
              </button>
              <button type="button" data-level="low" class="thinking-btn p-2 rounded-xl border border-amber-400/60 bg-amber-400/15 text-left">
                <div class="font-semibold text-xs text-amber-200">⏱️ Low</div>
                <span id="lblThinkLow" class="text-[9px] text-amber-300 font-mono">Nhanh</span>
              </button>
              <button type="button" data-level="medium" class="thinking-btn p-2 rounded-xl border border-white/10 glass-btn text-left">
                <div class="font-semibold text-xs">⚖️ Med</div>
                <span id="lblThinkMed" class="text-[9px] text-zinc-500 font-mono">Cân bằng</span>
              </button>
              <button type="button" data-level="high" class="thinking-btn p-2 rounded-xl border border-white/10 glass-btn text-left">
                <div class="font-semibold text-xs">🔬 High</div>
                <span id="lblThinkHigh" class="text-[9px] text-zinc-500 font-mono">Sâu</span>
              </button>
              <button type="button" data-level="xhigh" class="thinking-btn p-2 rounded-xl border border-white/10 glass-btn text-left">
                <div class="font-semibold text-xs">🔥 XHigh</div>
                <span id="lblThinkXHigh" class="text-[9px] text-zinc-500 font-mono">Cực sâu</span>
              </button>
            </div>
          </div>

          <!-- TEMPERATURE & TOP P -->
          <div id="samplingControlsWrapper" class="pt-3 border-t border-white/10 space-y-2 transition-opacity duration-200">
            <div class="grid grid-cols-2 gap-3">
              <div>
                <div class="flex justify-between items-center mb-1">
                  <label id="lblCreativity" class="text-zinc-400 text-[10px] uppercase font-semibold">Độ sáng tạo (Temp)</label>
                  <span id="tempValue" class="text-amber-300 font-mono text-xs">0.7</span>
                </div>
                <input type="range" id="temperatureInput" min="0" max="1.5" step="0.1" value="0.7" class="w-full cursor-pointer" />
              </div>
              <div>
                <div class="flex justify-between items-center mb-1">
                  <label id="lblTopP" class="text-zinc-400 text-[10px] uppercase font-semibold">Top-P</label>
                  <span id="topPValue" class="text-amber-300 font-mono text-xs">0.95</span>
                </div>
                <input type="range" id="topPInput" min="0" max="1.0" step="0.05" value="0.95" class="w-full cursor-pointer" />
              </div>
            </div>
            <p id="gemini4SamplingNote" class="hidden text-[10px] text-zinc-400 italic">
              * Gemini 4 tự động tối ưu tham số lấy mẫu
            </p>
          </div>

          <!-- SAFETY SETTINGS -->
          <div class="pt-3 border-t border-white/10">
            <div class="flex justify-between items-center mb-1.5">
              <label id="lblSafetySettings" class="text-zinc-400 text-[10px] uppercase font-semibold">Safety Settings (JSON Gemini)</label>
            </div>
            <textarea id="safetySettingsInput" rows="3" class="w-full bg-white/5 border border-white/10 rounded-xl p-2 text-zinc-100 font-mono text-[10px] focus:outline-none resize-none leading-relaxed"></textarea>
          </div>

          <!-- NGÔN NGỮ GIAO DIỆN -->
          <div class="flex items-center justify-between pt-3 border-t border-white/10">
            <label id="lblLanguage" class="text-zinc-400 text-[10px] uppercase font-semibold">Ngôn ngữ giao diện</label>
            <div class="flex glass-btn p-0.5 rounded-xl text-[10px]">
              <button type="button" id="modalLangViBtn" class="px-2.5 py-1 rounded-lg font-medium transition">Tiếng Việt</button>
              <button type="button" id="modalLangEnBtn" class="px-2.5 py-1 rounded-lg font-medium transition">English</button>
            </div>
          </div>

        </div>

        <div class="flex items-center justify-end gap-2 pt-3 border-t border-white/10 flex-shrink-0">
          <button id="cancelSettingsBtn" class="px-4 py-2 rounded-xl glass-btn text-xs text-zinc-300 hover:text-white transition">Đóng</button>
          <button id="saveSettingsBtn" class="px-5 py-2 rounded-xl accent-gradient-bg text-white font-semibold text-xs active:scale-95 transition">Lưu Cài Đặt</button>
        </div>
      </div>
    </div>
  </div>

  <script>
    const safeStore = {
      get: (k) => { try { return localStorage.getItem(k); } catch(e) { return null; } },
      set: (k, v) => { try { localStorage.setItem(k, v); } catch(e) {} }
    };

    const ACCENT_THEMES = {
      violet: {
        primary: "#8b5cf6",
        secondary: "#6366f1",
        light: "#c4b5fd",
        glow: "rgba(124, 58, 237, 0.35)",
        soft: "rgba(139, 92, 246, 0.22)",
        border: "rgba(167, 139, 250, 0.4)",
        orb1: "radial-gradient(circle, rgba(124, 58, 237, 0.28), rgba(79, 70, 229, 0.12))",
        orb2: "radial-gradient(circle, rgba(6, 182, 212, 0.2), rgba(59, 130, 246, 0.1))",
        orb3: "radial-gradient(circle, rgba(236, 72, 153, 0.14), rgba(139, 92, 246, 0.08))"
      },
      ocean: {
        primary: "#06b6d4",
        secondary: "#2563eb",
        light: "#67e8f9",
        glow: "rgba(6, 182, 212, 0.35)",
        soft: "rgba(6, 182, 212, 0.2)",
        border: "rgba(103, 232, 249, 0.4)",
        orb1: "radial-gradient(circle, rgba(6, 182, 212, 0.3), rgba(37, 99, 235, 0.14))",
        orb2: "radial-gradient(circle, rgba(59, 130, 246, 0.22), rgba(14, 165, 233, 0.1))",
        orb3: "radial-gradient(circle, rgba(45, 212, 191, 0.15), rgba(37, 99, 235, 0.08))"
      },
      emerald: {
        primary: "#10b981",
        secondary: "#0d9488",
        light: "#6ee7b7",
        glow: "rgba(16, 185, 129, 0.35)",
        soft: "rgba(16, 185, 129, 0.2)",
        border: "rgba(110, 231, 183, 0.4)",
        orb1: "radial-gradient(circle, rgba(16, 185, 129, 0.28), rgba(13, 148, 136, 0.14))",
        orb2: "radial-gradient(circle, rgba(52, 211, 153, 0.2), rgba(6, 182, 212, 0.1))",
        orb3: "radial-gradient(circle, rgba(163, 230, 53, 0.14), rgba(16, 185, 129, 0.08))"
      },
      rose: {
        primary: "#f43f5e",
        secondary: "#db2777",
        light: "#fda4af",
        glow: "rgba(244, 63, 94, 0.35)",
        soft: "rgba(244, 63, 94, 0.2)",
        border: "rgba(253, 164, 175, 0.4)",
        orb1: "radial-gradient(circle, rgba(244, 63, 94, 0.28), rgba(219, 39, 119, 0.14))",
        orb2: "radial-gradient(circle, rgba(232, 121, 249, 0.2), rgba(244, 63, 94, 0.1))",
        orb3: "radial-gradient(circle, rgba(251, 146, 60, 0.14), rgba(219, 39, 119, 0.08))"
      },
      amber: {
        primary: "#f59e0b",
        secondary: "#ea580c",
        light: "#fcd34d",
        glow: "rgba(245, 158, 11, 0.35)",
        soft: "rgba(245, 158, 11, 0.2)",
        border: "rgba(252, 211, 77, 0.4)",
        orb1: "radial-gradient(circle, rgba(245, 158, 11, 0.28), rgba(234, 88, 12, 0.14))",
        orb2: "radial-gradient(circle, rgba(251, 191, 36, 0.2), rgba(244, 63, 94, 0.1))",
        orb3: "radial-gradient(circle, rgba(234, 179, 8, 0.14), rgba(234, 88, 12, 0.08))"
      }
    };

    const I18N = {
      vi: {
        langBtn: "EN",
        history: "Lịch sử trò chuyện",
        historySub: "Quản lý cuộc trò chuyện",
        newChat: "Cuộc trò chuyện mới",
        swipeHint: "Vuốt mép để mở",
        clearAll: "Xóa tất cả",
        deleteConfirm: "Bạn có chắc chắn muốn xóa toàn bộ lịch sử trò chuyện?",
        searchOn: "Search: BẬT",
        searchOff: "Search: TẮT",
        searchBtnOn: "Google Search: BẬT",
        searchBtnOff: "Google Search: TẮT",
        exportHtml: "Xuất HTML",
        settings: "Cài đặt",
        readyTitle: "Sẵn sàng phản hồi",
        readySub: "Hỗ trợ phân tích văn bản, đính kèm tệp tin, tìm kiếm Google theo thời gian thực và API Endpoint tùy chỉnh.",
        prompt1: "🌐 Tin tức công nghệ mới & nguồn",
        prompt2: "🐍 Python parse JSON chuẩn",
        jumpBottom: "↓ Cuộn xuống cuối",
        inputHint: "Enter: Xuống dòng • Bấm nút Gửi để gửi tin nhắn",
        inputPlaceholder: "Nhập câu hỏi... (Gõ /image để vẽ ảnh)",
        send: "Gửi",
        stop: "⏹️ Dừng",
        attachedCount: "tệp đính kèm",
        settingsTitle: "Cài đặt API & Mô hình",
        accentTheme: "🎨 Màu sắc chủ đạo (Liquid Theme)",
        geminiKey: "Google Gemini API Key",
        getKey: "Lấy Key ↗",
        testKey: "⚡ Kiểm tra kết nối",
        testing: "⏳ Đang thử...",
        customEndpoint: "API Endpoint URL (Base URL):",
        customKey: "API Key của Endpoint:",
        customModel: "Tên Model Tùy Chỉnh:",
        modelConfig: "Cấu hình Mô hình (Model)",
        scanModels: "🔄 Quét models",
        scanning: "⏳ Đang quét...",
        thinkingTitle: "Mức độ tư duy (Thinking Level)",
        thinkOff: "Tắt",
        thinkMin: "Tối giản",
        thinkLow: "Nhanh",
        thinkMed: "Cân bằng",
        thinkHigh: "Sâu",
        thinkXHigh: "Cực sâu",
        creativity: "Độ sáng tạo (Temp)",
        gemini4SamplingNote: "* Gemini 4 tự động tối ưu tham số lấy mẫu",
        sysPrompt: "Chỉ thị hệ thống (System Instruction)",
        language: "Ngôn ngữ giao diện",
        close: "Đóng",
        save: "Lưu Cài Đặt",
        userLabel: "Bạn",
        editQuestion: "✏️ Chỉnh sửa câu hỏi",
        cancel: "Hủy",
        saveAndResend: "Lưu & Gửi lại",
        edit: "Sửa",
        copy: "Sao chép",
        copied: "Đã chép!",
        thinkingDetails: "🧠 Quá trình suy luận (Thinking)",
        sourcesTitle: "🌐 Nguồn tham khảo từ Google Search:",
        retry: "Thử lại",
        regenerate: "Tạo lại",
        stoppedNote: "*(Đã dừng tạo phản hồi)*",
        invalidJson: "Safety Settings JSON không hợp lệ! Vui lòng kiểm tra lại.",
        addPresetTitle: "Tên Preset mới:",
        addPreset: "➕ Thêm",
        delPreset: "🗑 Xóa",
        confirmDelPreset: "Bạn có chắc chắn muốn xóa preset này?"
      },
      en: {
        langBtn: "VI",
        history: "Chat History",
        historySub: "Manage conversations",
        newChat: "New Conversation",
        swipeHint: "Swipe edge to open",
        clearAll: "Clear All",
        deleteConfirm: "Are you sure you want to clear all chat history?",
        searchOn: "Search: ON",
        searchOff: "Search: OFF",
        searchBtnOn: "Google Search: ON",
        searchBtnOff: "Google Search: OFF",
        exportHtml: "Export HTML",
        settings: "Settings",
        readyTitle: "Ready to Assist",
        readySub: "Multimodal AI assistant supporting text analysis, file attachments, real-time Google Search, and custom endpoints.",
        prompt1: "🌐 Latest tech news & sources",
        prompt2: "🐍 Python JSON parse snippet",
        jumpBottom: "↓ Jump to latest",
        inputHint: "Enter: New line • Tap Send button to submit",
        inputPlaceholder: "Type your message... (Use /image to generate art)",
        send: "Send",
        stop: "⏹️ Stop",
        attachedCount: "file(s) attached",
        settingsTitle: "API & Model Settings",
        accentTheme: "🎨 Accent Color (Liquid Theme)",
        geminiKey: "Google Gemini API Key",
        getKey: "Get Key ↗",
        testKey: "⚡ Test Connection",
        testing: "⏳ Testing...",
        customEndpoint: "API Endpoint URL (Base URL):",
        customKey: "Endpoint API Key:",
        customModel: "Custom Model Name:",
        modelConfig: "Model Configuration",
        scanModels: "🔄 Scan models",
        scanning: "⏳ Scanning...",
        thinkingTitle: "Thinking Level",
        thinkOff: "Off",
        thinkMin: "Minimal",
        thinkLow: "Fast",
        thinkMed: "Balanced",
        thinkHigh: "Deep",
        thinkXHigh: "Ultra Deep",
        creativity: "Creativity (Temp)",
        gemini4SamplingNote: "* Gemini 4 automatically optimizes sampling parameters",
        sysPrompt: "System Instruction",
        language: "Interface Language",
        close: "Close",
        save: "Save Settings",
        userLabel: "You",
        editQuestion: "✏️ Edit Question",
        cancel: "Cancel",
        saveAndResend: "Save & Resend",
        edit: "Edit",
        copy: "Copy",
        copied: "Copied!",
        thinkingDetails: "🧠 Thinking Process",
        sourcesTitle: "🌐 Sources & Citations via Google Search:",
        retry: "Retry",
        regenerate: "Regenerate",
        stoppedNote: "*(Response generation stopped)*",
        invalidJson: "Invalid Safety Settings JSON! Please check again.",
        addPresetTitle: "New Preset Name:",
        addPreset: "➕ Add",
        delPreset: "🗑 Delete",
        confirmDelPreset: "Are you sure you want to delete this preset?"
      }
    };

    let storedModel = (safeStore.get("gemini_model") || "gemini-4-hydrogen").replace(/^models\//, "").trim();

    const defaultSafetySettings = [
      { "category": "HARM_CATEGORY_HARASSMENT", "threshold": "BLOCK_NONE" },
      { "category": "HARM_CATEGORY_HATE_SPEECH", "threshold": "BLOCK_NONE" },
      { "category": "HARM_CATEGORY_SEXUALLY_EXPLICIT", "threshold": "BLOCK_NONE" },
      { "category": "HARM_CATEGORY_DANGEROUS_CONTENT", "threshold": "BLOCK_NONE" },
      { "category": "HARM_CATEGORY_CIVIC_INTEGRITY", "threshold": "BLOCK_NONE" }
    ];

    const defaultPresets = [
      { id: "p_default", name: "Mặc định (General)", text: "Bạn là một trợ lý AI thông minh, nhiệt tình và khách quan." },
      { id: "p_coder", name: "Lập trình viên (Coder)", text: "Bạn là một Senior Developer. Trả lời ngắn gọn, cung cấp mã nguồn chính xác và tối ưu." }
    ];

    const STATE = {
      apiKey: safeStore.get("gemini_api_key") || "",
      customEndpoint: safeStore.get("custom_endpoint") || "",
      customApiKey: safeStore.get("custom_api_key") || "",
      customModel: safeStore.get("custom_model") || "",
      useCustomProvider: safeStore.get("use_custom_provider") === "true",
      model: storedModel,
      sysPresets: [],
      activePresetId: "",
      safetySettings: safeStore.get("gemini_safety_settings") || JSON.stringify(defaultSafetySettings, null, 2),
      temperature: parseFloat(safeStore.get("gemini_temperature") || "0.7"),
      topP: parseFloat(safeStore.get("gemini_top_p") || "0.95"),
      thinkingLevel: safeStore.get("gemini_thinking_level") || "low",
      theme: safeStore.get("gemini_theme") || "dark",
      accent: safeStore.get("gemini_accent") || "violet",
      lang: safeStore.get("gemini_lang") || "vi",
      webSearchEnabled: safeStore.get("gemini_web_search") !== "false",
      sessions: [],
      currentSessionId: "",
      isSidebarOpen: false,
      currentFiles: [],
      isGenerating: false,
      abortController: null,
      editingMessageIndex: null
    };

    try {
      const p = safeStore.get("gemini_sys_presets");
      if (p) STATE.sysPresets = JSON.parse(p);
    } catch(e){}
    if (!STATE.sysPresets || STATE.sysPresets.length === 0) STATE.sysPresets = defaultPresets;
    STATE.activePresetId = safeStore.get("gemini_active_preset") || STATE.sysPresets[0].id;
    if (!STATE.sysPresets.find(p => p.id === STATE.activePresetId)) STATE.activePresetId = STATE.sysPresets[0].id;

    function isGemini4Model(modelName) {
      return (modelName || "").toLowerCase().includes("gemini-4-");
    }

    function escapeHtml(s) {
      if (typeof s !== "string") s = String(s || "");
      return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&#039;");
    }

    function setupMarkedRenderer() {
      if (!window.marked) return;
      const renderer = new marked.Renderer();

      renderer.code = function(code, lang) {
        const rawCode = (typeof code === "object" && code !== null) ? (code.text || "") : (code || "");
        const rawLang = (typeof code === "object" && code !== null) ? (code.lang || "") : (lang || "");
        const cleanLang = (rawLang || "").trim().toLowerCase();

        let highlighted = "";
        if (window.hljs && cleanLang && hljs.getLanguage(cleanLang)) {
          try {
            highlighted = hljs.highlight(rawCode, { language: cleanLang, ignoreIllegals: true }).value;
          } catch (_) {
            highlighted = escapeHtml(rawCode);
          }
        } else {
          highlighted = escapeHtml(rawCode);
        }

        const codeId = "cb_" + Math.random().toString(36).substring(2, 9);
        const copyLabel = STATE.lang === "en" ? "Copy" : "Sao chép";
        return `
          <div class="code-block-wrapper">
            <div class="code-block-header">
              <div class="flex items-center gap-2 font-mono">
                <span class="w-2.5 h-2.5 rounded-full inline-block" style="background: var(--accent-primary);"></span>
                <span class="text-[10px] uppercase font-bold text-zinc-300 tracking-wider">${escapeHtml(cleanLang || "CODE")}</span>
              </div>
              <button type="button" class="copy-code-btn flex items-center gap-1.5 px-2.5 py-1 rounded-lg text-[11px] font-medium glass-btn text-zinc-300 hover:text-white transition" onclick="copyCodeBlock(this, '${codeId}')">
                <span class="copy-icon">📋</span><span class="copy-label">${copyLabel}</span>
              </button>
            </div>
            <pre><code id="${codeId}" class="hljs font-mono">${highlighted}</code></pre>
          </div>
        `;
      };

      renderer.link = function(href, title, text) {
        const url = (typeof href === "object" && href !== null) ? (href.href || "") : (href || "");
        const titleText = (typeof href === "object" && href !== null) ? (href.title || "") : (title || "");
        const content = (typeof href === "object" && href !== null) ? (href.text || "") : (text || "");
        const titleAttr = titleText ? ` title="${escapeHtml(titleText)}"` : "";
        return `<a href="${escapeHtml(url)}" target="_blank" rel="noopener noreferrer" class="citation-link inline-flex items-center gap-0.5"${titleAttr}><span>${content}</span><span class="text-[10px] opacity-75">↗</span></a>`;
      };

      marked.use({ renderer, breaks: true, gfm: true });
    }

    window.copyCodeBlock = function(btn, codeId) {
      const codeEl = document.getElementById(codeId);
      if (!codeEl) return;
      navigator.clipboard.writeText(codeEl.textContent || codeEl.innerText).then(() => {
        const icon = btn.querySelector(".copy-icon");
        const label = btn.querySelector(".copy-label");
        if (icon) icon.innerText = "✓";
        if (label) label.innerText = STATE.lang === "en" ? "Copied!" : "Đã sao chép!";
        setTimeout(() => {
          if (icon) icon.innerText = "📋";
          if (label) label.innerText = STATE.lang === "en" ? "Copy" : "Sao chép";
        }, 2000);
      });
    };

    window.copyMessageByIndex = function(btn, idx) {
      const cur = getCurrentSession();
      const msg = cur?.messages?.[idx];
      if (!msg || !msg.text) return;
      navigator.clipboard.writeText(msg.text).then(() => {
        const orig = btn.innerHTML;
        btn.innerHTML = `<span>✓</span><span>${STATE.lang === "en" ? "Copied!" : "Đã chép!"}</span>`;
        btn.classList.add("text-emerald-400");
        setTimeout(() => {
          btn.innerHTML = orig;
          btn.classList.remove("text-emerald-400");
        }, 2000);
      });
    };

    function loadSavedSessions() {
      try {
        const saved = safeStore.get("gemini_sessions_v3");
        if (saved) {
          const parsed = JSON.parse(saved);
          if (Array.isArray(parsed) && parsed.length > 0) STATE.sessions = parsed;
        }
      } catch (_) {}
      if (!STATE.sessions || STATE.sessions.length === 0) {
        STATE.sessions = [{ id: "sess_" + Date.now(), title: STATE.lang === "en" ? "New Conversation" : "Cuộc trò chuyện mới", messages: [], updatedAt: Date.now() }];
      }
      const savedId = safeStore.get("gemini_curr_session");
      STATE.currentSessionId = (savedId && STATE.sessions.some(s => s.id === savedId)) ? savedId : STATE.sessions[0].id;
    }

    function saveSessions() {
      safeStore.set("gemini_sessions_v3", JSON.stringify(STATE.sessions));
      safeStore.set("gemini_curr_session", STATE.currentSessionId);
    }

    function getCurrentSession() {
      return STATE.sessions.find(s => s.id === STATE.currentSessionId) || STATE.sessions[0];
    }

    const chatMain = document.getElementById("chatMain");
    const messagesContainer = document.getElementById("messagesContainer");
    const emptyState = document.getElementById("emptyState");
    const chatForm = document.getElementById("chatForm");
    const messageInput = document.getElementById("messageInput");
    const sendBtn = document.getElementById("sendBtn");
    const stopBtn = document.getElementById("stopBtn");
    const fileInput = document.getElementById("fileInput");
    const attachFileBtn = document.getElementById("attachFileBtn");
    const filePreviewBar = document.getElementById("filePreviewBar");
    const fileCountBadge = document.getElementById("fileCountBadge");
    const errorBanner = document.getElementById("errorBanner");
    const errorMessage = document.getElementById("errorMessage");
    const currentModelBadge = document.getElementById("currentModelBadge");
    const themeToggleBtn = document.getElementById("themeToggleBtn");
    const openSettingsBtn = document.getElementById("openSettingsBtn");
    const settingsModal = document.getElementById("settingsModal");
    const closeSettingsBtn = document.getElementById("closeSettingsBtn");
    const cancelSettingsBtn = document.getElementById("cancelSettingsBtn");
    const saveSettingsBtn = document.getElementById("saveSettingsBtn");
    const apiKeyInput = document.getElementById("apiKeyInput");
    
    const tabNativeApi = document.getElementById("tabNativeApi");
    const tabCustomApi = document.getElementById("tabCustomApi");
    const nativeConfigArea = document.getElementById("nativeConfigArea");
    const customConfigArea = document.getElementById("customConfigArea");
    
    const testApiKeyBtn = document.getElementById("testApiKeyBtn");
    const testCustomKeyBtn = document.getElementById("testCustomKeyBtn");
    const testKeyStatus = document.getElementById("testKeyStatus");
    
    const customEndpointInput = document.getElementById("customEndpointInput");
    const customApiKeyInput = document.getElementById("customApiKeyInput");
    const customModelInput = document.getElementById("customModelInput");
    
    const modelCustomInput = document.getElementById("modelCustomInput");
    const modelSelect = document.getElementById("modelSelect");
    const fetchModelsBtn = document.getElementById("fetchModelsBtn");
    const fetchStatusText = document.getElementById("fetchStatusText");
    
    const presetSelect = document.getElementById("presetSelect");
    const addPresetBtn = document.getElementById("addPresetBtn");
    const delPresetBtn = document.getElementById("delPresetBtn");
    const systemInstructionInput = document.getElementById("systemInstructionInput");
    
    const safetySettingsInput = document.getElementById("safetySettingsInput");
    const samplingControlsWrapper = document.getElementById("samplingControlsWrapper");
    const gemini4SamplingNote = document.getElementById("gemini4SamplingNote");
    const temperatureInput = document.getElementById("temperatureInput");
    const tempValue = document.getElementById("tempValue");
    const topPInput = document.getElementById("topPInput");
    const topPValue = document.getElementById("topPValue");
    const thinkingHeaderLabel = document.getElementById("thinkingHeaderLabel");
    const sidebarToggleBtn = document.getElementById("sidebarToggleBtn");
    const chatSidebar = document.getElementById("chatSidebar");
    const sidebarBackdrop = document.getElementById("sidebarBackdrop");
    const closeSidebarBtn = document.getElementById("closeSidebarBtn");
    const newSessionBtn = document.getElementById("newSessionBtn");
    const sessionsList = document.getElementById("sessionsList");
    const clearAllSessionsBtn = document.getElementById("clearAllSessionsBtn");
    const webSearchToggleBtn = document.getElementById("webSearchToggleBtn");
    const webSearchBtnText = document.getElementById("webSearchBtnText");
    const webSearchIndicator = document.getElementById("webSearchIndicator");
    const headerSearchToggleBtn = document.getElementById("headerSearchToggleBtn");
    const headerSearchStatusText = document.getElementById("headerSearchStatusText");
    const scrollToBottomBtn = document.getElementById("scrollToBottomBtn");
    const exportHtmlBtn = document.getElementById("exportHtmlBtn");
    const langToggleBtn = document.getElementById("langToggleBtn");
    const langToggleLabel = document.getElementById("langToggleLabel");
    const modalLangViBtn = document.getElementById("modalLangViBtn");
    const modalLangEnBtn = document.getElementById("modalLangEnBtn");

    function resizeTextarea() {
      messageInput.style.height = "auto";
      messageInput.style.height = Math.min(messageInput.scrollHeight, 160) + "px";
    }

    function applyAccentTheme(accentKey) {
      const t = ACCENT_THEMES[accentKey] || ACCENT_THEMES.violet;
      STATE.accent = accentKey;
      safeStore.set("gemini_accent", accentKey);

      const rootStyle = document.documentElement.style;
      rootStyle.setProperty("--accent-primary", t.primary);
      rootStyle.setProperty("--accent-secondary", t.secondary);
      rootStyle.setProperty("--accent-light", t.light);
      rootStyle.setProperty("--accent-glow", t.glow);
      rootStyle.setProperty("--accent-soft", t.soft);
      rootStyle.setProperty("--accent-border", t.border);
      rootStyle.setProperty("--orb-1", t.orb1);
      rootStyle.setProperty("--orb-2", t.orb2);
      rootStyle.setProperty("--orb-3", t.orb3);

      document.querySelectorAll(".accent-option").forEach(btn => {
        const isSelected = btn.getAttribute("data-accent") === accentKey;
        btn.style.borderColor = isSelected ? t.primary : "rgba(255,255,255,0.1)";
        btn.style.background = isSelected ? t.soft : "";
      });
    }

    function init() {
      setupMarkedRenderer();
      loadSavedSessions();
      applyAccentTheme(STATE.accent);
      applyTheme(STATE.theme);
      applyLanguage(STATE.lang);
      updateModelBadge();
      
      switchApiTab(STATE.useCustomProvider);

      apiKeyInput.value = STATE.apiKey;
      customEndpointInput.value = STATE.customEndpoint;
      customApiKeyInput.value = STATE.customApiKey;
      customModelInput.value = STATE.customModel;

      modelCustomInput.value = STATE.model;
      syncModelSelectValue(STATE.model);
      
      renderPresetsDropdown();
      
      safetySettingsInput.value = STATE.safetySettings;
      temperatureInput.value = STATE.temperature;
      tempValue.innerText = STATE.temperature;
      topPInput.value = STATE.topP;
      topPValue.innerText = STATE.topP.toFixed(2);

      setThinkingLevel(STATE.thinkingLevel);
      syncUIForActiveModel(getEffectiveModelName());
      renderSessionsList();
      renderMessages();
      setupEventListeners();
      setupMobileViewportHandling();
      setupSwipeGestures();
    }

    function setupSwipeGestures() {
      let startX = 0, startY = 0;
      document.addEventListener("touchstart", (e) => {
        if (e.touches.length !== 1) return;
        startX = e.touches[0].clientX;
        startY = e.touches[0].clientY;
      }, { passive: true });

      document.addEventListener("touchend", (e) => {
        if (e.changedTouches.length !== 1) return;
        const dx = e.changedTouches[0].clientX - startX;
        const dy = Math.abs(e.changedTouches[0].clientY - startY);

        if (!STATE.isSidebarOpen && startX <= 45 && dx > 55 && dy < 70) {
          openSidebar();
        } else if (STATE.isSidebarOpen && dx < -55 && dy < 70) {
          closeSidebar();
        }
      }, { passive: true });
    }

    function getEffectiveModelName() {
      if (!settingsModal.classList.contains("hidden")) {
        return STATE.useCustomProvider
          ? (customModelInput.value.trim() || STATE.customModel || "")
          : (modelCustomInput.value.trim() || modelSelect.value || STATE.model || "");
      }
      return (STATE.useCustomProvider && STATE.customModel) ? STATE.customModel : STATE.model;
    }

    function syncModelSelectValue(modelName) {
      const clean = (modelName || "").replace(/^models\//, "").trim();
      const opts = Array.from(modelSelect.options);
      const found = opts.find(o => o.value === clean);
      if (found) modelSelect.value = clean;
    }

    function syncUIForActiveModel(modelName) {
      const isG4 = isGemini4Model(modelName);
      const offBtn = document.querySelector('.thinking-btn[data-level="off"]');
      const minBtn = document.querySelector('.thinking-btn[data-level="minimal"]');
      const xhighBtn = document.querySelector('.thinking-btn[data-level="xhigh"]');

      if (isG4) {
        if (offBtn) { offBtn.classList.add("hidden"); offBtn.disabled = true; }
        if (minBtn) { minBtn.classList.add("hidden"); minBtn.disabled = true; }
        if (xhighBtn) { xhighBtn.classList.remove("hidden"); xhighBtn.disabled = false; }

        if (STATE.thinkingLevel === "off" || STATE.thinkingLevel === "minimal") {
          setThinkingLevel("low");
          safeStore.set("gemini_thinking_level", "low");
        } else {
          setThinkingLevel(STATE.thinkingLevel);
        }

        if (samplingControlsWrapper) {
          samplingControlsWrapper.style.opacity = "0.4";
          samplingControlsWrapper.style.pointerEvents = "none";
        }
        if (temperatureInput) temperatureInput.disabled = true;
        if (topPInput) topPInput.disabled = true;
        if (gemini4SamplingNote) gemini4SamplingNote.classList.remove("hidden");
      } else {
        if (offBtn) { offBtn.classList.remove("hidden"); offBtn.disabled = false; }
        if (minBtn) { minBtn.classList.remove("hidden"); minBtn.disabled = false; }
        if (xhighBtn) { xhighBtn.classList.add("hidden"); xhighBtn.disabled = true; }

        if (STATE.thinkingLevel === "xhigh") {
          setThinkingLevel("high");
          safeStore.set("gemini_thinking_level", "high");
        } else {
          setThinkingLevel(STATE.thinkingLevel);
        }

        if (samplingControlsWrapper) {
          samplingControlsWrapper.style.opacity = "1";
          samplingControlsWrapper.style.pointerEvents = "auto";
        }
        if (temperatureInput) temperatureInput.disabled = false;
        if (topPInput) topPInput.disabled = false;
        if (gemini4SamplingNote) gemini4SamplingNote.classList.add("hidden");
      }
    }

    function switchApiTab(isCustom) {
      STATE.useCustomProvider = isCustom;
      if (!isCustom) {
        tabNativeApi.className = "flex-1 py-2 rounded-lg accent-badge shadow-sm transition border";
        tabCustomApi.className = "flex-1 py-2 rounded-lg text-zinc-400 hover:text-zinc-200 transition";
        nativeConfigArea.classList.remove("hidden");
        customConfigArea.classList.add("hidden");
      } else {
        tabNativeApi.className = "flex-1 py-2 rounded-lg text-zinc-400 hover:text-zinc-200 transition";
        tabCustomApi.className = "flex-1 py-2 rounded-lg accent-badge shadow-sm transition border";
        nativeConfigArea.classList.add("hidden");
        customConfigArea.classList.remove("hidden");
      }
      testKeyStatus.classList.add("hidden");
      syncUIForActiveModel(getEffectiveModelName());
    }

    tabNativeApi.onclick = () => switchApiTab(false);
    tabCustomApi.onclick = () => switchApiTab(true);

    function renderPresetsDropdown() {
      presetSelect.innerHTML = "";
      STATE.sysPresets.forEach(p => {
        const o = document.createElement("option");
        o.value = p.id;
        o.innerText = p.name;
        if (p.id === STATE.activePresetId) o.selected = true;
        presetSelect.appendChild(o);
      });
      const activeObj = STATE.sysPresets.find(p => p.id === STATE.activePresetId);
      systemInstructionInput.value = activeObj ? activeObj.text : "";
    }

    presetSelect.onchange = () => {
      STATE.activePresetId = presetSelect.value;
      const activeObj = STATE.sysPresets.find(p => p.id === STATE.activePresetId);
      systemInstructionInput.value = activeObj ? activeObj.text : "";
    };

    systemInstructionInput.oninput = (e) => {
      const activeObj = STATE.sysPresets.find(p => p.id === STATE.activePresetId);
      if (activeObj) activeObj.text = e.target.value;
    };

    addPresetBtn.onclick = () => {
      const d = I18N[STATE.lang] || I18N.vi;
      const name = prompt(d.addPresetTitle, "Preset " + (STATE.sysPresets.length + 1));
      if (name && name.trim()) {
        const newP = { id: "p_" + Date.now(), name: name.trim(), text: "" };
        STATE.sysPresets.push(newP);
        STATE.activePresetId = newP.id;
        renderPresetsDropdown();
        systemInstructionInput.focus();
      }
    };

    delPresetBtn.onclick = () => {
      const d = I18N[STATE.lang] || I18N.vi;
      if (STATE.sysPresets.length <= 1) {
        alert("Phải có ít nhất 1 preset!");
        return;
      }
      if (confirm(d.confirmDelPreset)) {
        STATE.sysPresets = STATE.sysPresets.filter(p => p.id !== STATE.activePresetId);
        STATE.activePresetId = STATE.sysPresets[0].id;
        renderPresetsDropdown();
      }
    };

    function setupMobileViewportHandling() {
      const root = document.getElementById("appRoot");
      const footer = document.getElementById("stickyInputFooter");
      if (!root) return;

      const syncViewport = () => {
        if (window.visualViewport) {
          const vv = window.visualViewport;
          if (window.scrollY !== 0) window.scrollTo(0, 0);
          if (document.body.scrollTop !== 0) document.body.scrollTop = 0;
          if (document.documentElement.scrollTop !== 0) document.documentElement.scrollTop = 0;

          root.style.height = `${vv.height}px`;
          root.style.top = `${vv.offsetTop}px`;
          root.style.left = `${vv.offsetLeft}px`;
          root.style.width = `${vv.width}px`;

          const isKeyboard = (window.innerHeight - vv.height) > 100;
          if (footer) {
            footer.style.paddingBottom = isKeyboard ? "0.5rem" : "max(0.75rem, env(safe-area-inset-bottom, 0.75rem))";
          }
        }
      };

      if (window.visualViewport) {
        window.visualViewport.addEventListener("resize", syncViewport);
        window.visualViewport.addEventListener("scroll", syncViewport);
      }
      window.addEventListener("resize", syncViewport);
      window.addEventListener("scroll", () => {
        if (window.scrollY !== 0) window.scrollTo(0, 0);
      }, { passive: false });

      messageInput.addEventListener("focus", () => {
        setTimeout(syncViewport, 80);
        setTimeout(syncViewport, 200);
        setTimeout(() => {
          syncViewport();
          chatMain.scrollTop = chatMain.scrollHeight;
        }, 350);
      });

      messageInput.addEventListener("blur", () => {
        setTimeout(syncViewport, 100);
        setTimeout(syncViewport, 300);
      });

      chatMain.addEventListener("scroll", () => {
        const dist = chatMain.scrollHeight - chatMain.scrollTop - chatMain.clientHeight;
        scrollToBottomBtn.classList.toggle("hidden", dist <= 120);
      }, { passive: true });

      scrollToBottomBtn.onclick = () => {
        chatMain.scrollTo({ top: chatMain.scrollHeight, behavior: "smooth" });
      };

      syncViewport();
    }

    function applyLanguage(lang) {
      STATE.lang = lang;
      safeStore.set("gemini_lang", lang);
      const d = I18N[lang] || I18N.vi;

      langToggleLabel.innerText = d.langBtn;
      modalLangViBtn.className = lang === "vi" ? "px-2.5 py-1 rounded-lg font-medium accent-badge border" : "px-2.5 py-1 rounded-lg font-medium text-zinc-400 hover:text-white";
      modalLangEnBtn.className = lang === "en" ? "px-2.5 py-1 rounded-lg font-medium accent-badge border" : "px-2.5 py-1 rounded-lg font-medium text-zinc-400 hover:text-white";

      document.getElementById("sidebarTitle").innerText = d.history;
      document.getElementById("sidebarSubtitle").innerText = d.historySub;
      document.getElementById("newSessionLabel").innerText = d.newChat;
      document.getElementById("swipeHintLabel").innerText = d.swipeHint;
      document.getElementById("clearAllSessionsBtn").innerText = d.clearAll;
      document.getElementById("exportHtmlBtnLabel").innerText = d.exportHtml;
      document.getElementById("openSettingsLabel").innerText = d.settings;

      document.getElementById("emptyStateTitle").innerText = d.readyTitle;
      document.getElementById("emptyStateSub").innerText = d.readySub;
      document.getElementById("quickPrompt1").innerText = d.prompt1;
      document.getElementById("quickPrompt2").innerText = d.prompt2;
      document.getElementById("scrollToBottomLabel").innerText = d.jumpBottom;

      document.getElementById("inputHintLabel").innerText = d.inputHint;
      document.getElementById("messageInput").placeholder = d.inputPlaceholder;
      document.getElementById("sendBtnLabel").innerText = d.send;
      document.getElementById("stopBtnLabel").innerText = d.stop;

      document.getElementById("settingsModalTitle").innerText = d.settingsTitle;
      document.getElementById("lblAccentTheme").innerText = d.accentTheme;
      document.getElementById("lblGeminiKey").innerHTML = d.geminiKey;
      document.getElementById("linkGetKey").innerText = d.getKey;
      document.getElementById("testApiKeyBtn").innerText = d.testKey;
      document.getElementById("testCustomKeyBtn").innerText = d.testKey;
      
      document.getElementById("lblCustomEndpoint").innerText = d.customEndpoint;
      document.getElementById("lblCustomKey").innerText = d.customKey;
      document.getElementById("lblCustomModel").innerText = d.customModel;
      document.getElementById("lblModelConfig").innerText = d.modelConfig;
      document.getElementById("fetchModelsBtn").innerText = d.scanModels;
      document.getElementById("lblThinkingTitle").innerHTML = `<span>🧠</span> ${d.thinkingTitle}`;
      document.getElementById("lblThinkOff").innerText = d.thinkOff;
      document.getElementById("lblThinkMin").innerText = d.thinkMin;
      document.getElementById("lblThinkLow").innerText = d.thinkLow;
      document.getElementById("lblThinkMed").innerText = d.thinkMed;
      document.getElementById("lblThinkHigh").innerText = d.thinkHigh;
      const lblThinkXHigh = document.getElementById("lblThinkXHigh");
      if (lblThinkXHigh) lblThinkXHigh.innerText = d.thinkXHigh;
      document.getElementById("lblCreativity").innerText = d.creativity;
      if (gemini4SamplingNote) gemini4SamplingNote.innerText = d.gemini4SamplingNote;
      document.getElementById("lblSysPrompt").innerText = d.sysPrompt;
      document.getElementById("lblLanguage").innerText = d.language;
      document.getElementById("cancelSettingsBtn").innerText = d.close;
      document.getElementById("saveSettingsBtn").innerText = d.save;
      
      document.getElementById("addPresetBtn").innerText = d.addPreset;
      document.getElementById("delPresetBtn").innerText = d.delPreset;

      updateSearchToggleUI();
      updateThinkingBadges();
      renderSessionsList();
      renderMessages();
    }

    function toggleLanguage() {
      applyLanguage(STATE.lang === "vi" ? "en" : "vi");
    }

    function updateSearchToggleUI() {
      const d = I18N[STATE.lang] || I18N.vi;
      if (STATE.webSearchEnabled) {
        webSearchBtnText.innerText = d.searchBtnOn;
        webSearchIndicator.className = "w-1.5 h-1.5 rounded-full bg-emerald-400 shadow-[0_0_8px_#34d399]";
        webSearchToggleBtn.className = "flex items-center gap-1.5 px-2.5 py-1 rounded-xl text-[11px] font-medium border border-emerald-500/40 bg-emerald-950/40 text-emerald-300 transition cursor-pointer backdrop-blur-md";
        headerSearchStatusText.innerText = d.searchOn;
        headerSearchToggleBtn.className = "hidden sm:inline-flex items-center gap-1.5 px-2.5 py-1 rounded-xl text-[11px] font-medium border border-emerald-500/40 bg-emerald-950/40 text-emerald-300 transition cursor-pointer backdrop-blur-md";
      } else {
        webSearchBtnText.innerText = d.searchBtnOff;
        webSearchIndicator.className = "w-1.5 h-1.5 rounded-full bg-zinc-500";
        webSearchToggleBtn.className = "flex items-center gap-1.5 px-2.5 py-1 rounded-xl text-[11px] font-medium border border-white/10 glass-btn text-zinc-400 transition cursor-pointer";
        headerSearchStatusText.innerText = d.searchOff;
        headerSearchToggleBtn.className = "hidden sm:inline-flex items-center gap-1.5 px-2.5 py-1 rounded-xl text-[11px] font-medium border border-white/10 glass-btn text-zinc-400 transition cursor-pointer";
      }
      safeStore.set("gemini_web_search", STATE.webSearchEnabled ? "true" : "false");
    }

    function toggleWebSearch() {
      STATE.webSearchEnabled = !STATE.webSearchEnabled;
      updateSearchToggleUI();
    }

    function updateModelBadge() {
      const activeName = (STATE.useCustomProvider && STATE.customModel) ? STATE.customModel : STATE.model;
      currentModelBadge.innerHTML = `<span class="w-1.5 h-1.5 rounded-full" style="background: ${STATE.useCustomProvider ? '#fbbf24' : 'var(--accent-primary)'};"></span>${escapeHtml(activeName)}`;
    }

    function updateThinkingBadges() {
      const isEn = STATE.lang === "en";
      const labels = isEn 
        ? { off: "OFF", minimal: "MIN", low: "LOW", medium: "MED", high: "HIGH", xhigh: "XHIGH" }
        : { off: "TẮT", minimal: "MIN", low: "THẤP", medium: "VỪA", high: "CAO", xhigh: "CỰC SÂU" };
      if (thinkingHeaderLabel) thinkingHeaderLabel.innerText = labels[STATE.thinkingLevel] || (isEn ? "LOW" : "THẤP");
    }

    function setThinkingLevel(lvl) {
      STATE.thinkingLevel = lvl;
      document.querySelectorAll(".thinking-btn").forEach(btn => {
        const isHidden = btn.classList.contains("hidden");
        const isTarget = btn.getAttribute("data-level") === lvl;
        btn.className = (isTarget 
          ? "thinking-btn p-2 rounded-xl border border-amber-400/70 bg-amber-400/20 text-left transition shadow-[0_0_12px_rgba(251,191,36,0.15)]"
          : "thinking-btn p-2 rounded-xl border border-white/10 glass-btn text-left transition")
          + (isHidden ? " hidden" : "");
      });
      updateThinkingBadges();
    }

    function getThinkingConfigObject(model, lvl) {
      const m = (model || "").toLowerCase();

      if (isGemini4Model(m)) {
        const validG4Levels = ["low", "medium", "high", "xhigh"];
        const normalized = validG4Levels.includes(lvl) ? lvl : "low";
        return { thinkingLevel: normalized };
      }

      const isGemini25 = m.includes("2.5");
      if (lvl === "off") return isGemini25 ? { thinkingBudget: 0 } : undefined;
      if (lvl === "minimal") return isGemini25 ? { thinkingBudget: 128 } : undefined; 
      if (lvl === "low") return isGemini25 ? { thinkingBudget: 1024 } : { thinkingLevel: "LOW" };
      if (lvl === "high") return isGemini25 ? { thinkingBudget: 8192 } : { thinkingLevel: "HIGH" };
      if (lvl === "xhigh") return isGemini25 ? { thinkingBudget: 16384 } : { thinkingLevel: "HIGH" };
      if (lvl === "medium") return isGemini25 ? undefined : { thinkingLevel: "MEDIUM" };
      return undefined;
    }

    function openSidebar() {
      STATE.isSidebarOpen = true;
      chatSidebar.classList.remove("-translate-x-full");
      sidebarBackdrop.classList.remove("hidden");
    }

    function closeSidebar() {
      STATE.isSidebarOpen = false;
      chatSidebar.classList.add("-translate-x-full");
      sidebarBackdrop.classList.add("hidden");
    }

    function renderSessionsList() {
      sessionsList.innerHTML = "";
      const defaultTitle = STATE.lang === "en" ? "New Conversation" : "Cuộc trò chuyện mới";
      STATE.sessions.forEach((s) => {
        const isCurrent = s.id === STATE.currentSessionId;
        const card = document.createElement("div");
        card.className = "flex items-center justify-between p-2.5 rounded-xl cursor-pointer text-xs transition " + (
          isCurrent 
            ? "glass-card-user text-white shadow-md" 
            : "text-zinc-400 hover:text-white hover:bg-white/5"
        );
        card.innerHTML = `
          <div class="flex items-center gap-2 flex-1 truncate">
            <span>${isCurrent ? "💬" : "🗨️"}</span>
            <span class="truncate font-medium">${escapeHtml(s.title || defaultTitle)}</span>
          </div>
          <button class="delete-btn p-1 text-zinc-500 hover:text-red-400 rounded-lg hover:bg-white/10 transition">✕</button>
        `;
        card.onclick = (e) => {
          if (e.target.closest(".delete-btn")) {
            e.stopPropagation();
            deleteSession(s.id);
            return;
          }
          switchSession(s.id);
        };
        sessionsList.appendChild(card);
      });
    }

    function switchSession(id) {
      STATE.currentSessionId = id;
      STATE.editingMessageIndex = null;
      saveSessions();
      renderSessionsList();
      renderMessages();
      closeSidebar();
    }

    function createNewSession() {
      const defaultTitle = STATE.lang === "en" ? "New Conversation" : "Cuộc trò chuyện mới";
      const newS = { id: "sess_" + Date.now(), title: defaultTitle, messages: [], updatedAt: Date.now() };
      STATE.sessions.unshift(newS);
      STATE.currentSessionId = newS.id;
      STATE.editingMessageIndex = null;
      saveSessions();
      renderSessionsList();
      renderMessages();
      closeSidebar();
      messageInput.focus();
    }

    function deleteSession(id) {
      const defaultTitle = STATE.lang === "en" ? "New Conversation" : "Cuộc trò chuyện mới";
      if (STATE.sessions.length <= 1) {
        STATE.sessions[0].messages = [];
        STATE.sessions[0].title = defaultTitle;
      } else {
        STATE.sessions = STATE.sessions.filter(s => s.id !== id);
        if (STATE.currentSessionId === id) STATE.currentSessionId = STATE.sessions[0].id;
      }
      saveSessions();
      renderSessionsList();
      renderMessages();
    }

    function setupEventListeners() {
      chatForm.onsubmit = (e) => {
        e.preventDefault();
        handleSendMessage();
      };

      messageInput.oninput = resizeTextarea;

      messageInput.onkeydown = (e) => {
        if (e.key === "Enter") {
          setTimeout(resizeTextarea, 0);
        }
      };

      attachFileBtn.onclick = () => fileInput.click();
      fileInput.onchange = (e) => {
        if (e.target.files && e.target.files.length > 0) {
          handleIncomingFiles(Array.from(e.target.files));
          fileInput.value = "";
        }
      };

      stopBtn.onclick = () => {
        if (STATE.abortController) { STATE.abortController.abort(); STATE.abortController = null; }
        setGenerating(false);
      };

      document.querySelectorAll(".accent-option").forEach(btn => {
        btn.onclick = () => applyAccentTheme(btn.getAttribute("data-accent"));
      });

      langToggleBtn.onclick = toggleLanguage;
      modalLangViBtn.onclick = () => applyLanguage("vi");
      modalLangEnBtn.onclick = () => applyLanguage("en");

      themeToggleBtn.onclick = () => applyTheme(STATE.theme === "dark" ? "light" : "dark");
      sidebarToggleBtn.onclick = openSidebar;
      closeSidebarBtn.onclick = closeSidebar;
      sidebarBackdrop.onclick = closeSidebar;
      newSessionBtn.onclick = createNewSession;
      clearAllSessionsBtn.onclick = () => {
        const d = I18N[STATE.lang] || I18N.vi;
        if (confirm(d.deleteConfirm)) {
          const defaultTitle = STATE.lang === "en" ? "New Conversation" : "Cuộc trò chuyện mới";
          STATE.sessions = [{ id: "sess_" + Date.now(), title: defaultTitle, messages: [], updatedAt: Date.now() }];
          STATE.currentSessionId = STATE.sessions[0].id;
          saveSessions();
          renderSessionsList();
          renderMessages();
          closeSidebar();
        }
      };

      webSearchToggleBtn.onclick = toggleWebSearch;
      headerSearchToggleBtn.onclick = toggleWebSearch;
      exportHtmlBtn.onclick = exportSingleHtmlFile;

      document.querySelectorAll(".thinking-btn").forEach(btn => {
        btn.onclick = () => setThinkingLevel(btn.getAttribute("data-level"));
      });

      temperatureInput.oninput = (e) => { tempValue.innerText = e.target.value; };
      topPInput.oninput = (e) => { topPValue.innerText = parseFloat(e.target.value).toFixed(2); };

      modelSelect.onchange = () => {
        if (modelSelect.value) {
          if (STATE.useCustomProvider) {
            customModelInput.value = modelSelect.value;
          } else {
            modelCustomInput.value = modelSelect.value;
          }
          syncUIForActiveModel(modelSelect.value);
        }
      };

      modelCustomInput.oninput = () => {
        syncModelSelectValue(modelCustomInput.value);
        syncUIForActiveModel(modelCustomInput.value);
      };

      customModelInput.oninput = () => {
        syncUIForActiveModel(customModelInput.value);
      };

      openSettingsBtn.onclick = showSettings;
      closeSettingsBtn.onclick = hideSettings;
      cancelSettingsBtn.onclick = hideSettings;
      saveSettingsBtn.onclick = saveSettings;
      fetchModelsBtn.onclick = handleFetchModels;

      testApiKeyBtn.onclick = async () => handleTestConnection(false, testApiKeyBtn);
      testCustomKeyBtn.onclick = async () => handleTestConnection(true, testCustomKeyBtn);

      window.addEventListener("paste", (e) => {
        if (!e.clipboardData) return;
        const files = [];
        for (let i = 0; i < e.clipboardData.items.length; i++) {
          if (e.clipboardData.items[i].kind === "file") {
            const f = e.clipboardData.items[i].getAsFile();
            if (f) files.push(f);
          }
        }
        if (files.length > 0) handleIncomingFiles(files);
      });
    }
    
    async function handleTestConnection(isCustom, btnElement) {
      const d = I18N[STATE.lang] || I18N.vi;
      btnElement.disabled = true;
      btnElement.innerText = d.testing;
      testKeyStatus.className = "text-[10px] px-2.5 py-1.5 rounded-xl border accent-badge backdrop-blur-md";
      testKeyStatus.innerText = STATE.lang === "en" ? "Testing connection..." : "Đang kiểm tra kết nối...";
      testKeyStatus.classList.remove("hidden");

      try {
        if (isCustom) {
          let ep = customEndpointInput.value.trim();
          if (!ep) throw new Error(STATE.lang === "en" ? "Endpoint URL is empty" : "Chưa nhập Endpoint URL");
          ep = ep.replace(/\/+$/, "");
          if (!ep.endsWith("/chat/completions")) ep += "/chat/completions";
          const cKey = customApiKeyInput.value.trim();
          const mod = customModelInput.value.trim() || "gemini-4-hydrogen";

          const headers = { "Content-Type": "application/json" };
          if (cKey) headers["Authorization"] = `Bearer ${cKey}`;

          const testPayload = {
            model: mod,
            messages: [{ role: "user", content: "ping" }],
            max_tokens: 5
          };

          const res = await fetch(ep, {
            method: "POST",
            headers,
            body: JSON.stringify(testPayload)
          });
          if (!res.ok) throw new Error(`HTTP ${res.status}: ${await res.text()}`);
          testKeyStatus.className = "text-[10px] px-2.5 py-1.5 rounded-xl border text-emerald-300 bg-emerald-950/60 border-emerald-500/40 backdrop-blur-md";
          testKeyStatus.innerText = STATE.lang === "en" ? `✓ Custom Endpoint connected successfully! (${mod})` : `✓ Custom Endpoint kết nối thành công! (Model: ${mod})`;
        } else {
          const key = apiKeyInput.value.trim() || STATE.apiKey;
          if (!key) throw new Error(STATE.lang === "en" ? "Gemini API Key is empty" : "Chưa nhập Google Gemini API Key");
          const mod = (modelCustomInput.value.trim() || STATE.model).replace(/^models\//, "");
          const res = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(mod)}:generateContent?key=${encodeURIComponent(key)}`, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ contents: [{ parts: [{ text: "ping" }] }] })
          });
          const data = await res.json();
          if (!res.ok) throw new Error(data.error?.message || `HTTP ${res.status}`);
          testKeyStatus.className = "text-[10px] px-2.5 py-1.5 rounded-xl border text-emerald-300 bg-emerald-950/60 border-emerald-500/40 backdrop-blur-md";
          testKeyStatus.innerText = STATE.lang === "en" ? `✓ Google API Key is valid & connected! (${mod})` : `✓ Google API Key hợp lệ và hoạt động tốt! (${mod})`;
        }
      } catch (err) {
        testKeyStatus.className = "text-[10px] px-2.5 py-1.5 rounded-xl border text-rose-300 bg-rose-950/60 border-rose-500/40 backdrop-blur-md";
        testKeyStatus.innerText = (STATE.lang === "en" ? "Error: " : "Lỗi: ") + err.message;
      } finally {
        btnElement.disabled = false;
        btnElement.innerText = d.testKey;
      }
    }

    function applyTheme(theme) {
      STATE.theme = theme;
      safeStore.set("gemini_theme", theme);
      if (theme === "light") {
        document.documentElement.classList.remove("dark");
        themeToggleBtn.innerText = "☀️";
      } else {
        document.documentElement.classList.add("dark");
        themeToggleBtn.innerText = "🌙";
      }
      if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.themeChangeHandler) {
        window.webkit.messageHandlers.themeChangeHandler.postMessage(theme);
      }
    }

    function showSettings() {
      apiKeyInput.value = STATE.apiKey;
      customEndpointInput.value = STATE.customEndpoint;
      customApiKeyInput.value = STATE.customApiKey;
      customModelInput.value = STATE.customModel;
      
      applyAccentTheme(STATE.accent);
      switchApiTab(STATE.useCustomProvider);

      modelCustomInput.value = STATE.model;
      syncModelSelectValue(STATE.model);
      renderPresetsDropdown();
      safetySettingsInput.value = STATE.safetySettings;
      temperatureInput.value = STATE.temperature;
      topPInput.value = STATE.topP;
      setThinkingLevel(STATE.thinkingLevel);
      syncUIForActiveModel(STATE.useCustomProvider ? STATE.customModel : STATE.model);
      
      fetchStatusText.classList.add("hidden");
      testKeyStatus.classList.add("hidden");
      settingsModal.classList.remove("hidden");
    }

    function hideSettings() {
      settingsModal.classList.add("hidden");
      syncUIForActiveModel(getEffectiveModelName());
    }

    function saveSettings() {
      try {
        const parsedSafety = JSON.parse(safetySettingsInput.value.trim() || "[]");
        STATE.safetySettings = JSON.stringify(parsedSafety, null, 2);
      } catch (e) {
        const d = I18N[STATE.lang] || I18N.vi;
        alert(d.invalidJson);
        return; 
      }

      STATE.apiKey = apiKeyInput.value.trim();
      STATE.customEndpoint = customEndpointInput.value.trim();
      STATE.customApiKey = customApiKeyInput.value.trim();
      STATE.customModel = customModelInput.value.trim();

      const chosenModel = (modelCustomInput.value.trim() || modelSelect.value || "gemini-4-hydrogen").replace(/^models\//, "");
      STATE.model = chosenModel;
      
      const activeEffectiveModel = STATE.useCustomProvider ? STATE.customModel : STATE.model;
      if (isGemini4Model(activeEffectiveModel) && (STATE.thinkingLevel === "off" || STATE.thinkingLevel === "minimal")) {
        STATE.thinkingLevel = "low";
      }

      safeStore.set("gemini_sys_presets", JSON.stringify(STATE.sysPresets));
      safeStore.set("gemini_active_preset", STATE.activePresetId);

      STATE.temperature = parseFloat(temperatureInput.value);
      STATE.topP = parseFloat(topPInput.value);

      safeStore.set("gemini_api_key", STATE.apiKey);
      safeStore.set("use_custom_provider", STATE.useCustomProvider ? "true" : "false");
      safeStore.set("custom_endpoint", STATE.customEndpoint);
      safeStore.set("custom_api_key", STATE.customApiKey);
      safeStore.set("custom_model", STATE.customModel);
      safeStore.set("gemini_model", STATE.model);
      safeStore.set("gemini_safety_settings", STATE.safetySettings);
      safeStore.set("gemini_temperature", STATE.temperature.toString());
      safeStore.set("gemini_top_p", STATE.topP.toString());
      safeStore.set("gemini_thinking_level", STATE.thinkingLevel);

      updateModelBadge();
      updateThinkingBadges();
      hideSettings();
      hideError();
    }

    async function handleFetchModels() {
      const isCustom = STATE.useCustomProvider;
      const d = I18N[STATE.lang] || I18N.vi;
      fetchModelsBtn.disabled = true;
      fetchModelsBtn.innerText = d.scanning;
      fetchStatusText.className = "text-[10px] mt-1 px-2.5 py-1.5 rounded-xl border text-zinc-300 glass-surface";
      fetchStatusText.innerText = STATE.lang === "en" ? "Loading..." : "Đang tải...";
      fetchStatusText.classList.remove("hidden");

      try {
        if (isCustom) {
          let ep = customEndpointInput.value.trim().replace(/\/+$/, "");
          if (!ep) throw new Error(STATE.lang === "en" ? "Endpoint URL is empty" : "Chưa nhập Endpoint URL");
          let url = ep.endsWith("/chat/completions") ? ep.replace("/chat/completions", "/models") : (ep.endsWith("/models") ? ep : ep + "/models");
          const headers = { "Content-Type": "application/json" };
          const cKey = customApiKeyInput.value.trim();
          if (cKey) headers["Authorization"] = `Bearer ${cKey}`;

          const res = await fetch(url, { headers });
          if (!res.ok) throw new Error(`HTTP ${res.status}`);
          const data = await res.json();
          const list = Array.isArray(data) ? data : (data.data || []);
          const ids = list
            .map(m => (typeof m === "string" ? m : (m.id || m.name || "")).replace(/^models\//, ""))
            .filter(Boolean);
          if (ids.length === 0) throw new Error(STATE.lang === "en" ? "No models returned" : "Không tìm thấy model nào từ Endpoint.");

          ids.sort((a, b) => {
            const aG4 = a.toLowerCase().includes("gemini-4-") ? 0 : 1;
            const bG4 = b.toLowerCase().includes("gemini-4-") ? 0 : 1;
            return aG4 - bG4;
          });

          modelSelect.innerHTML = "";
          ids.forEach(id => {
            const o = document.createElement("option");
            o.value = id; o.innerText = id;
            if (id === customModelInput.value.trim()) o.selected = true;
            modelSelect.appendChild(o);
          });
          fetchStatusText.className = "text-[10px] mt-1 px-2.5 py-1.5 rounded-xl border text-emerald-300 bg-emerald-950/40 border-emerald-500/40 backdrop-blur-md";
          fetchStatusText.innerText = STATE.lang === "en" ? `✓ Loaded ${ids.length} models from Custom Endpoint.` : `✓ Đã nạp ${ids.length} mô hình từ Custom Endpoint.`;
        } else {
          const gKey = apiKeyInput.value.trim() || STATE.apiKey;
          if (!gKey) throw new Error(STATE.lang === "en" ? "Please enter Google API Key first." : "Vui lòng nhập Google API Key trước.");
          const res = await fetch(`https://generativelanguage.googleapis.com/v1beta/models?key=${encodeURIComponent(gKey)}`);
          if (!res.ok) throw new Error(`HTTP ${res.status}`);
          const data = await res.json();
          const valid = (data.models || []).filter(m => {
            const id = (m.name || "").replace(/^models\//, "").toLowerCase();
            const supportsGen = m.supportedGenerationMethods?.includes("generateContent");
            return supportsGen || id.includes("gemini-4-");
          });
          if (valid.length === 0) throw new Error(STATE.lang === "en" ? "No generateContent models found" : "Không tìm thấy model nào hỗ trợ generateContent.");

          valid.sort((a, b) => {
            const aG4 = (a.name || "").toLowerCase().includes("gemini-4-") ? 0 : 1;
            const bG4 = (b.name || "").toLowerCase().includes("gemini-4-") ? 0 : 1;
            return aG4 - bG4;
          });

          modelSelect.innerHTML = "";
          valid.forEach(m => {
            const id = m.name.replace(/^models\//, "");
            const o = document.createElement("option");
            o.value = id;
            o.innerText = `${id} ${m.displayName ? '(' + m.displayName + ')' : ''}`;
            if (id === (modelCustomInput.value.trim() || STATE.model)) o.selected = true;
            modelSelect.appendChild(o);
          });
          fetchStatusText.className = "text-[10px] mt-1 px-2.5 py-1.5 rounded-xl border text-emerald-300 bg-emerald-950/40 border-emerald-500/40 backdrop-blur-md";
          fetchStatusText.innerText = STATE.lang === "en" ? `✓ Loaded ${valid.length} models from Google API.` : `✓ Đã nạp ${valid.length} mô hình từ Google API.`;
        }
      } catch (err) {
        fetchStatusText.className = "text-[10px] mt-1 px-2.5 py-1.5 rounded-xl border text-rose-300 bg-rose-950/40 border-rose-500/30 backdrop-blur-md";
        fetchStatusText.innerText = (STATE.lang === "en" ? "Error: " : "Lỗi: ") + err.message;
      } finally {
        fetchModelsBtn.disabled = false;
        fetchModelsBtn.innerText = d.scanModels;
      }
    }

    async function handleIncomingFiles(list) {
      hideError();
      const textExtensions = [".txt", ".csv", ".json", ".md", ".js", ".py", ".html", ".ts", ".jsx", ".tsx", ".css", ".sql", ".sh", ".env"];
      for (const f of list) {
        if (f.size > 20 * 1024 * 1024) { showError(`File ${f.name} > 20MB.`); continue; }
        const ext = "." + f.name.split(".").pop().toLowerCase();
        
        if (textExtensions.includes(ext) || f.type.startsWith("text/")) {
          try {
            const content = await readFileAsText(f);
            STATE.currentFiles.push({
              name: f.name,
              size: f.size,
              category: "text",
              textContent: content
            });
          } catch (e) { showError(e.message); }
        } else {
          try {
            const res = await readFileAsBase64(f);
            STATE.currentFiles.push(res);
          } catch (e) { showError(e.message); }
        }
      }
      renderFilePreviews();
    }

    function readFileAsText(file) {
      return new Promise((resolve, reject) => {
        const reader = new FileReader();
        reader.onload = () => resolve(reader.result);
        reader.onerror = () => reject(new Error(`Failed to read file ${file.name}`));
        reader.readAsText(file);
      });
    }

    function readFileAsBase64(file) {
      return new Promise((resolve, reject) => {
        const reader = new FileReader();
        reader.onload = () => {
          const res = reader.result;
          const comma = res.indexOf(",");
          let mime = file.type;
          if (!mime) {
            const ext = file.name.split(".").pop().toLowerCase();
            if (ext === "pdf") mime = "application/pdf";
            else if (["jpg", "jpeg"].includes(ext)) mime = "image/jpeg";
            else if (ext === "png") mime = "image/png";
            else if (ext === "webp") mime = "image/webp";
            else mime = "application/octet-stream";
          }
          resolve({
            name: file.name,
            size: file.size,
            mimeType: mime,
            dataBase64: res.substring(comma + 1),
            previewUrl: res,
            category: mime.startsWith("image/") ? "image" : "document"
          });
        };
        reader.onerror = () => reject(new Error("Failed to read file."));
        reader.readAsDataURL(file);
      });
    }

    function renderFilePreviews() {
      if (STATE.currentFiles.length === 0) {
        filePreviewBar.classList.add("hidden");
        fileCountBadge.classList.add("hidden");
        return;
      }
      filePreviewBar.classList.remove("hidden");
      fileCountBadge.classList.remove("hidden");
      fileCountBadge.innerText = `${STATE.currentFiles.length} ${(I18N[STATE.lang] || I18N.vi).attachedCount}`;
      filePreviewBar.innerHTML = STATE.currentFiles.map((f, i) => `
        <div class="flex items-center gap-2 p-1.5 rounded-xl glass-btn text-xs">
          ${f.category === "image" ? `<img src="${f.previewUrl}" class="w-8 h-8 rounded-lg object-cover" />` : `<span class="text-base">${f.category === 'text' ? '📝' : '📄'}</span>`}
          <span class="max-w-[120px] truncate text-zinc-200 font-medium">${escapeHtml(f.name)}</span>
          <button type="button" onclick="removeCurrentFile(${i})" class="p-1 text-zinc-400 hover:text-rose-400 rounded-lg transition">✕</button>
        </div>
      `).join("");
    }

    function removeCurrentFile(i) {
      STATE.currentFiles.splice(i, 1);
      renderFilePreviews();
    }

    window.quickPrompt = function(txt) {
      messageInput.value = txt;
      resizeTextarea();
      messageInput.focus();
    };

    window.startEditMessage = function(idx) {
      STATE.editingMessageIndex = idx;
      renderMessages();
    };

    window.cancelEditMessage = function() {
      STATE.editingMessageIndex = null;
      renderMessages();
    };

    window.saveAndResendMessage = async function(idx) {
      const cur = getCurrentSession();
      const textarea = document.getElementById(`editTextarea_${idx}`);
      if (!textarea) return;
      const newText = textarea.value.trim();
      if (!newText) return;

      cur.messages[idx].text = newText;
      STATE.editingMessageIndex = null;
      cur.messages = cur.messages.slice(0, idx + 1);
      saveSessions();
      renderMessages();
      await triggerModelResponse();
    };

    window.retryGeneration = async function(msgIndex) {
      if (STATE.isGenerating) return;
      const cur = getCurrentSession();
      if (typeof msgIndex === "number" && msgIndex < cur.messages.length) {
        cur.messages = cur.messages.slice(0, msgIndex);
      }
      saveSessions();
      renderMessages();
      await triggerModelResponse();
    };

    async function handleSendMessage() {
      if (STATE.isGenerating) return;
      let text = messageInput.value.trim();
      const files = [...STATE.currentFiles];
      if (!text && files.length === 0) return;

      if (!STATE.useCustomProvider && !STATE.apiKey) {
        showError(STATE.lang === "en" ? "Please enter Gemini API Key." : "Vui lòng nhập Google Gemini API Key.");
        showSettings();
        return;
      }
      if (STATE.useCustomProvider && !STATE.customEndpoint) {
        showError(STATE.lang === "en" ? "Please enter Custom Endpoint URL." : "Vui lòng nhập Custom Endpoint URL.");
        showSettings();
        return;
      }
      hideError();

      const textFiles = files.filter(f => f.category === "text");
      const binaryFiles = files.filter(f => f.category !== "text");
      if (textFiles.length > 0) {
        let appended = STATE.lang === "en" ? "\n\n--- ATTACHED FILE CONTENT ---" : "\n\n--- NỘI DUNG TỆP ĐÍNH KÈM ---";
        textFiles.forEach(tf => {
          appended += `\n[${tf.name}]\n\`\`\`\n${tf.textContent}\n\`\`\`\n`;
        });
        text = text ? (text + appended) : appended.trim();
      }

      const cur = getCurrentSession();
      if (cur.messages.length === 0 && text) {
        cur.title = text.substring(0, 30) + (text.length > 30 ? "..." : "");
      }
      cur.messages.push({ role: "user", text, files: binaryFiles, timestamp: Date.now() });

      messageInput.value = "";
      messageInput.style.height = "auto";
      STATE.currentFiles = [];
      renderFilePreviews();
      saveSessions();
      renderSessionsList();
      renderMessages();

      await triggerModelResponse();
    }

    let _streamRafId = null;
    let _pendingStreamMsg = null;

    function scheduleStreamUpdate(botMsg) {
      _pendingStreamMsg = botMsg;
      if (_streamRafId) return;
      _streamRafId = requestAnimationFrame(() => {
        _streamRafId = null;
        applyStreamUpdate(_pendingStreamMsg);
      });
    }

    function applyStreamUpdate(botMsg) {
      if (!botMsg) return;

      const prose = document.getElementById("streamingProse");
      if (!prose) {
        renderMessages();
        return;
      }

      const thoughtDetails = document.getElementById("streamingThought");
      if (thoughtDetails) {
        const thoughtBody = thoughtDetails.querySelector(".stream-thought-body");
        if (botMsg.thought) {
          thoughtDetails.classList.remove("hidden");
          if (thoughtBody && thoughtBody.textContent !== botMsg.thought) {
            thoughtBody.textContent = botMsg.thought;
          }
        } else {
          thoughtDetails.classList.add("hidden");
        }
      }

      let parsedHtml = "";
      try {
        parsedHtml = window.marked ? marked.parse(botMsg.text || "") : escapeHtml(botMsg.text || "");
      } catch (_) {
        parsedHtml = escapeHtml(botMsg.text || "");
      }
      prose.innerHTML = parsedHtml;

      const dist = chatMain.scrollHeight - chatMain.scrollTop - chatMain.clientHeight;
      if (dist < 180) {
        chatMain.scrollTop = chatMain.scrollHeight;
      }
    }

    async function triggerModelResponse() {
      const cur = getCurrentSession();
      if (cur.messages.length === 0) return;

      setGenerating(true);
      const botMsg = {
        role: "model",
        text: "",
        thought: "",
        timestamp: Date.now(),
        groundingMetadata: null,
        isError: false,
        errorMessage: ""
      };
      cur.messages.push(botMsg);
      renderMessages();
      scrollToBottom();

      try {
        STATE.abortController = new AbortController();
        const historyForApi = cur.messages.slice(0, -1);
        const result = await callAPI(historyForApi, STATE.abortController.signal, (chunkText, thoughtText, metadata) => {
          botMsg.text = chunkText;
          botMsg.thought = thoughtText;

          const hadGrounding = !!(botMsg.groundingMetadata?.groundingChunks?.length);
          const hasGrounding = !!(metadata?.groundingChunks?.length);
          if (metadata) botMsg.groundingMetadata = metadata;

          if (hasGrounding && !hadGrounding) {
            renderMessages();
            scrollToBottom(false);
          } else {
            scheduleStreamUpdate(botMsg);
          }
        });

        botMsg.text = result.text;
        botMsg.thought = result.thought;
        if (result.groundingMetadata) botMsg.groundingMetadata = result.groundingMetadata;
      } catch (err) {
        if (err.name === "AbortError") {
          botMsg.text += `\n\n${(I18N[STATE.lang] || I18N.vi).stoppedNote}`;
        } else {
          botMsg.isError = true;
          botMsg.errorMessage = err.message || (STATE.lang === "en" ? "API Connection Error" : "Lỗi kết nối API");
        }
      } finally {
        if (_streamRafId) { cancelAnimationFrame(_streamRafId); _streamRafId = null; }
        _pendingStreamMsg = null;
        saveSessions();
        renderMessages();
        setGenerating(false);
        STATE.abortController = null;
        scrollToBottom();
      }
    }

    function scrollToBottom(smooth = true) {
      setTimeout(() => {
        chatMain.scrollTo({ top: chatMain.scrollHeight, behavior: smooth ? "smooth" : "auto" });
      }, 30);
    }

    async function callAPI(history, signal, onChunk) {
      let accumulated = "";
      let thoughts = "";
      let latestGroundingMetadata = null;
      
      const activeObj = STATE.sysPresets.find(p => p.id === STATE.activePresetId);
      const activeSysText = activeObj ? activeObj.text : "";

      let isImagePrompt = false;
      const msgsData = [];
      history.forEach(m => {
        if (m.isError) return;
        const role = m.role === "model" ? "assistant" : "user";
        
        let cText = m.text || " ";
        if (role === "user" && cText.trim().toLowerCase().startsWith("/image ")) {
            isImagePrompt = true;
            cText = cText.trim().substring(7).trim(); 
        }

        if (m.files?.length > 0 && role === "user") {
          const contents = [];
          if (cText) contents.push({ type: "text", text: cText });
          m.files.forEach(f => {
            if (f.category === "image") {
              contents.push({ type: "image_url", image_url: { url: `data:${f.mimeType};base64,${f.dataBase64}` } });
            }
          });
          msgsData.push({ role: "user", content: contents, _rawTextForGemini: cText });
        } else {
          msgsData.push({ role, content: cText, _rawTextForGemini: cText });
        }
      });

      if (STATE.useCustomProvider) {
        let ep = STATE.customEndpoint.replace(/\/+$/, "");
        if (!ep.endsWith("/chat/completions")) ep += "/chat/completions";

        const activeCustomModel = (STATE.customModel || "gemini-4-hydrogen").trim();
        const isGoogleOrG4 = ep.toLowerCase().includes("://googleapis.com") ||
                             ep.toLowerCase().includes("googleapis.com") ||
                             isGemini4Model(activeCustomModel);

        let sysInstruction = activeSysText;
        if (STATE.webSearchEnabled) {
          sysInstruction += (sysInstruction ? "\n\n" : "") + (STATE.lang === "en" 
            ? "When citing facts from real-time web search, provide markdown hyperlinks [Source Name](URL)." 
            : "Khi trích dẫn dữ liệu từ web, hãy cung cấp link Markdown dạng [Tên nguồn](URL).");
        }
        
        const payloadMsgs = sysInstruction ? [{ role: "system", content: sysInstruction }, ...msgsData] : msgsData;
        payloadMsgs.forEach(m => delete m._rawTextForGemini);

        const headers = { "Content-Type": "application/json" };
        if (STATE.customApiKey) headers["Authorization"] = `Bearer ${STATE.customApiKey}`;

        const openAiBody = {
          model: activeCustomModel,
          messages: payloadMsgs,
          stream: true
        };

        if (!isGoogleOrG4) {
          openAiBody.temperature = STATE.temperature;
          openAiBody.top_p = STATE.topP;
        } else {
          delete openAiBody.temperature;
          delete openAiBody.top_p;
          delete openAiBody.frequency_penalty;
          delete openAiBody.presence_penalty;
        }

        const res = await fetch(ep, {
          method: "POST",
          headers,
          body: JSON.stringify(openAiBody),
          signal
        });

        if (!res.ok) throw new Error(`HTTP ${res.status}: ${await res.text()}`);

        const reader = res.body?.getReader();
        const decoder = new TextDecoder("utf-8");
        let buffer = "";

        while (true) {
          if (signal?.aborted) break;
          const { done, value } = await reader.read();
          if (done) {
            if (buffer && buffer.trim()) {
              const trimmed = buffer.trim();
              if (trimmed.startsWith("data:")) {
                const data = trimmed.replace(/^data:\s*/, "");
                if (data && data !== "[DONE]") {
                  try {
                    const parsed = JSON.parse(data);
                    const delta = parsed.choices?.[0]?.delta;
                    const r = delta?.reasoning_content || delta?.reasoning || delta?.thought;
                    if (r) thoughts += r;
                    if (delta?.content) accumulated += delta.content;
                  } catch (_) {}
                }
              }
            }
            break;
          }

          buffer += decoder.decode(value, { stream: true });
          const lines = buffer.split(/\r?\n/);
          buffer = lines.pop() || "";

          for (const line of lines) {
            const trimmed = line.trim();
            if (!trimmed || !trimmed.startsWith("data:")) continue;
            const data = trimmed.replace(/^data:\s*/, "");
            if (!data || data === "[DONE]") continue;

            try {
              const parsed = JSON.parse(data);
              const delta = parsed.choices?.[0]?.delta;
              const r = delta?.reasoning_content || delta?.reasoning || delta?.thought;
              if (r) thoughts += r;
              if (delta?.content) accumulated += delta.content;
              onChunk?.(accumulated, thoughts, null);
            } catch (_) {}
          }
        }
        return { text: accumulated || (STATE.lang === "en" ? "(No response)" : "(Không có phản hồi)"), thought: thoughts, groundingMetadata: null };
      }

      const activeKey = STATE.apiKey;
      let cleanModel = (STATE.model || "gemini-4-hydrogen").replace(/^models\//, "").trim();
      if (isImagePrompt) {
          cleanModel = "imagen-3.0-generate-002"; 
      }

      const contents = [];
      for (const m of history) {
        if (m.isError || (!m.text && (!m.files || m.files.length === 0))) continue;
        const parts = [];
        if (m.files && m.files.length > 0) {
          m.files.forEach(f => {
            if (f.dataBase64 && f.mimeType) {
              parts.push({ inlineData: { mimeType: f.mimeType, data: f.dataBase64 } });
            }
          });
        }
        
        let cText = m.text || "";
        if (m.role === "user" && cText.trim().toLowerCase().startsWith("/image ")) {
            cText = cText.trim().substring(7).trim();
        }
        if (cText) parts.push({ text: cText });
        if (parts.length === 0) continue;

        const role = m.role === "model" ? "model" : "user";
        if (contents.length > 0 && contents[contents.length - 1].role === role) {
          contents[contents.length - 1].parts.push(...parts);
        } else {
          contents.push({ role, parts });
        }
      }

      while (contents.length > 0 && contents[0].role !== "user") {
        contents.shift();
      }
      if (contents.length === 0) {
        contents.push({ role: "user", parts: [{ text: STATE.lang === "en" ? "Hello" : "Xin chào" }] });
      }

      const isG4 = isGemini4Model(cleanModel);
      const generationConfig = {
        maxOutputTokens: 8192
      };

      if (!isG4) {
        generationConfig.temperature = STATE.temperature;
        generationConfig.topP = STATE.topP;
      } else {
        delete generationConfig.temperature;
        delete generationConfig.topP;
        delete generationConfig.topK;
      }

      if (!isImagePrompt) {
          const thinkingObj = getThinkingConfigObject(cleanModel, STATE.thinkingLevel);
          if (thinkingObj) generationConfig.thinkingConfig = thinkingObj;
      }

      const payload = { contents, generationConfig };

      if (!isImagePrompt) {
          try {
            const parsedSafety = JSON.parse(STATE.safetySettings);
            if (Array.isArray(parsedSafety) && parsedSafety.length > 0) {
              payload.safetySettings = parsedSafety;
            }
          } catch (e) {}

          if (STATE.webSearchEnabled) {
            payload.tools = [{ googleSearch: {} }];
          }

          let sysInstruction = activeSysText;
          if (STATE.webSearchEnabled) {
            const searchSys = "You have real-time Google Search grounding enabled. Search Google for current facts, cite sources clearly with markdown hyperlinks.";
            sysInstruction = sysInstruction ? `${sysInstruction}\n\n${searchSys}` : searchSys;
          }
          if (sysInstruction) {
            payload.systemInstruction = { parts: [{ text: sysInstruction }] };
          }
      }

      const url = `https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(cleanModel)}:streamGenerateContent?alt=sse&key=${encodeURIComponent(activeKey)}`;
      let res = await fetch(url, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(payload),
        signal
      });

      if (!res.ok && res.status === 400 && payload.generationConfig?.thinkingConfig && !isG4) {
        delete payload.generationConfig.thinkingConfig;
        res = await fetch(url, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(payload),
          signal
        });
      }

      if (!res.ok) {
        const errText = await res.text();
        let errMsg = `HTTP ${res.status}`;
        try {
          const parsed = JSON.parse(errText);
          if (parsed.error?.message) errMsg = parsed.error.message;
        } catch (_) { errMsg = errText || errMsg; }
        if (res.status === 429) {
          errMsg = STATE.lang === "en" ? "Rate limit exceeded (429). Please wait a moment." : "Đã vượt hạn mức yêu cầu (Rate Limit 429). Vui lòng đợi vài giây rồi thử lại.";
        }
        throw new Error(errMsg);
      }

      const reader = res.body?.getReader();
      const decoder = new TextDecoder("utf-8");
      let buffer = "";

      while (true) {
        if (signal?.aborted) break;
        const { done, value } = await reader.read();
        if (done) {
          if (buffer && buffer.trim()) {
            const trimmed = buffer.trim();
            if (trimmed.startsWith("data:")) {
              const data = trimmed.replace(/^data:\s*/, "");
              if (data && data !== "[DONE]") {
                try {
                  const parsed = JSON.parse(data);
                  const candidate = parsed.candidates?.[0];
                  if (candidate) {
                    if (candidate.groundingMetadata) latestGroundingMetadata = candidate.groundingMetadata;
                    const parts = candidate.content?.parts;
                    if (Array.isArray(parts)) {
                      for (const p of parts) {
                        if (p.thought === true || p.thought) thoughts += (p.text || "");
                        else if (p.text) accumulated += p.text;
                      }
                    }
                  }
                } catch (_) {}
              }
            }
          }
          break;
        }

        buffer += decoder.decode(value, { stream: true });
        const lines = buffer.split(/\r?\n/);
        buffer = lines.pop() || "";

        for (const line of lines) {
          const trimmed = line.trim();
          if (!trimmed || !trimmed.startsWith("data:")) continue;
          const data = trimmed.replace(/^data:\s*/, "");
          if (!data || data === "[DONE]") continue;

          try {
            const parsed = JSON.parse(data);
            const candidate = parsed.candidates?.[0];
            if (candidate) {
              if (candidate.groundingMetadata) latestGroundingMetadata = candidate.groundingMetadata;
              const parts = candidate.content?.parts;
              if (Array.isArray(parts)) {
                for (const p of parts) {
                  if (p.thought === true || p.thought) {
                    thoughts += (p.text || "");
                  } else if (p.text) {
                    accumulated += p.text;
                  }
                  if (p.inlineData && p.inlineData.data) {
                    const mime = p.inlineData.mimeType || "image/jpeg";
                    accumulated += `\n\n![Generated Image](data:${mime};base64,${p.inlineData.data})\n\n`;
                  }
                }
              }
              onChunk?.(accumulated, thoughts, latestGroundingMetadata);
            }
          } catch (_) {}
        }
      }

      return {
        text: accumulated || (STATE.lang === "en" ? "(No response)" : "(Không có phản hồi)"),
        thought: thoughts,
        groundingMetadata: latestGroundingMetadata
      };
    }

    function renderMessages() {
      const msgs = getCurrentSession().messages || [];
      const d = I18N[STATE.lang] || I18N.vi;

      if (msgs.length === 0) {
        emptyState.classList.remove("hidden");
        messagesContainer.innerHTML = "";
        return;
      }
      emptyState.classList.add("hidden");

      messagesContainer.innerHTML = msgs.map((m, idx) => {
        const isUser = m.role === "user";
        const isEditing = STATE.editingMessageIndex === idx;
        const isGeneratingCurrent = !isUser && STATE.isGenerating && idx === msgs.length - 1;

        let filesHtml = "";
        if (m.files?.length > 0) {
          filesHtml = `<div class="flex flex-wrap gap-2 mb-2">` + m.files.map(f =>
            f.category === "image"
              ? `<a href="${f.previewUrl}" target="_blank" rel="noopener"><img src="${f.previewUrl}" class="max-w-[180px] sm:max-w-[240px] max-h-48 rounded-xl border border-white/20 object-cover shadow-sm hover:opacity-90 transition" /></a>`
              : `<div class="p-2 rounded-xl glass-btn text-xs flex items-center gap-2"><span>📄</span><span class="truncate max-w-[120px] font-mono">${escapeHtml(f.name)}</span></div>`
          ).join("") + `</div>`;
        }

        if (isUser) {
          if (isEditing) {
            return `
              <div class="flex gap-2.5 flex-row-reverse items-start">
                <div class="w-8 h-8 rounded-xl accent-badge border flex items-center justify-center text-xs font-semibold shadow-inner">${d.userLabel}</div>
                <div class="p-3.5 rounded-3xl max-w-[90%] sm:max-w-[85%] w-full glass-surface shadow-xl space-y-2">
                  <div class="text-[11px] accent-badge inline-block px-2 py-0.5 rounded-lg border font-semibold">${d.editQuestion}</div>
                  <textarea id="editTextarea_${idx}" rows="3" class="w-full bg-white/5 border border-white/10 rounded-2xl p-2.5 text-white focus:outline-none resize-none leading-relaxed ios-fix-input">${escapeHtml(m.text)}</textarea>
                  <div class="flex items-center justify-end gap-2 pt-1">
                    <button type="button" onclick="cancelEditMessage()" class="px-3 py-1.5 rounded-xl glass-btn text-zinc-300 hover:text-white text-xs transition">${d.cancel}</button>
                    <button type="button" onclick="saveAndResendMessage(${idx})" class="px-3.5 py-1.5 rounded-xl accent-gradient-bg text-white font-semibold text-xs transition">${d.saveAndResend}</button>
                  </div>
                </div>
              </div>
            `;
          }

          return `
            <div class="flex gap-2.5 flex-row-reverse items-start group">
              <div class="w-8 h-8 rounded-xl accent-badge border flex items-center justify-center text-xs font-semibold flex-shrink-0 shadow-inner">${d.userLabel}</div>
              <div class="space-y-1 max-w-[85%]">
                <div class="p-3.5 sm:p-4 rounded-3xl text-xs sm:text-sm glass-card-user text-white break-words">
                  ${filesHtml}
                  <div class="whitespace-pre-wrap leading-relaxed">${escapeHtml(m.text)}</div>
                </div>
                <div class="flex items-center justify-end gap-2 opacity-80 sm:opacity-0 group-hover:opacity-100 transition px-1 text-[11px] text-zinc-400">
                  <button type="button" onclick="startEditMessage(${idx})" class="hover:text-white px-1.5 py-0.5 rounded-lg hover:bg-white/10 transition">✏️ ${d.edit}</button>
                  <span>•</span>
                  <button type="button" onclick="copyMessageByIndex(this, ${idx})" class="hover:text-zinc-200 px-1.5 py-0.5 rounded-lg hover:bg-white/10 transition">📋 ${d.copy}</button>
                </div>
              </div>
            </div>
          `;
        }

        let body = "";
        if (!m.text && !m.thought && isGeneratingCurrent) {
          body = `<div class="flex items-center gap-1.5 py-2"><span class="w-2.5 h-2.5 rounded-full typing-dot" style="background: var(--accent-primary);"></span><span class="w-2.5 h-2.5 rounded-full typing-dot" style="background: var(--accent-primary);"></span><span class="w-2.5 h-2.5 rounded-full typing-dot" style="background: var(--accent-primary);"></span></div>`;
        } else {
          try {
            body = window.marked ? marked.parse(m.text || "") : escapeHtml(m.text || "");
          } catch (_) {
            body = escapeHtml(m.text || "");
          }
        }

        let thoughtHtml = "";
        if (m.thought || isGeneratingCurrent) {
          const hideClass = (!m.thought && isGeneratingCurrent) ? " hidden" : "";
          thoughtHtml = `
            <details ${isGeneratingCurrent ? 'id="streamingThought"' : ''} class="mb-3 rounded-2xl glass-btn p-2.5 text-xs${hideClass}">
              <summary class="cursor-pointer text-[11px] font-mono text-zinc-400 select-none hover:text-zinc-200">
                ${d.thinkingDetails}
              </summary>
              <div class="stream-thought-body mt-2 text-zinc-400 font-mono text-[11px] whitespace-pre-wrap leading-relaxed border-t border-white/10 pt-2">${escapeHtml(m.thought || "")}</div>
            </details>
          `;
        }

        let sourcesHtml = "";
        if (m.groundingMetadata?.groundingChunks?.length > 0) {
          const chips = m.groundingMetadata.groundingChunks.map(c => {
            const web = c.web;
            if (!web || !web.uri) return "";
            let host = "web";
            try { host = new URL(web.uri).hostname.replace(/^www\./, ""); } catch (_) {}
            return `
              <a href="${escapeHtml(web.uri)}" target="_blank" rel="noopener noreferrer" class="inline-flex items-center gap-1 px-2.5 py-1 rounded-xl glass-btn text-[11px] citation-link transition">
                <span>🔗</span><span class="max-w-[140px] truncate font-medium">${escapeHtml(web.title || host)}</span>
                <span class="text-[9px] text-zinc-400 font-mono">(${escapeHtml(host)})</span>
              </a>
            `;
          }).filter(Boolean).join("");

          sourcesHtml = `
            <div class="mt-3 pt-3 border-t border-white/10 space-y-1.5">
              <div class="text-[11px] font-semibold text-zinc-300">${d.sourcesTitle}</div>
              <div class="flex flex-wrap gap-1.5 pt-0.5">${chips}</div>
            </div>
          `;
        }

        let errorHtml = "";
        if (m.isError) {
          errorHtml = `
            <div class="mt-2 p-3 rounded-2xl bg-rose-950/70 border border-rose-500/40 text-rose-200 text-xs flex items-center justify-between gap-2 shadow-lg backdrop-blur-md">
              <div class="flex items-center gap-2"><span>⚠️</span><span>${escapeHtml(m.errorMessage)}</span></div>
              <button type="button" onclick="retryGeneration(${idx})" class="px-3 py-1.5 rounded-xl bg-rose-900 hover:bg-rose-800 text-white font-semibold text-xs transition">🔄 ${d.retry}</button>
            </div>
          `;
        }

        return `
          <div class="flex gap-2.5 flex-row items-start group">
            <div class="w-8 h-8 rounded-xl accent-badge border flex items-center justify-center text-xs font-semibold flex-shrink-0 shadow-inner">✦</div>
            <div class="space-y-1 max-w-[90%] sm:max-w-[85%] w-full">
              <div ${isGeneratingCurrent ? 'id="streamingBubble"' : ''} class="p-3.5 sm:p-5 rounded-3xl text-xs sm:text-sm glass-surface text-zinc-200 border ${m.isError ? "border-rose-500/50" : "border-white/10"} break-words">
                ${thoughtHtml}
                <div ${isGeneratingCurrent ? 'id="streamingProse"' : ''} class="prose-content">${body}</div>
                ${sourcesHtml}
                ${errorHtml}
              </div>
              ${!isGeneratingCurrent && !m.isError && m.text ? `
                <div class="flex items-center gap-2 opacity-80 sm:opacity-0 group-hover:opacity-100 transition px-1 text-[11px] text-zinc-400">
                  <button type="button" onclick="copyMessageByIndex(this, ${idx})" class="hover:text-zinc-200 px-2 py-0.5 rounded-lg hover:bg-white/10 transition">📋 ${d.copy}</button>
                  <span>•</span>
                  <button type="button" onclick="retryGeneration(${idx})" class="hover:text-white px-2 py-0.5 rounded-lg hover:bg-white/10 transition">🔄 ${d.regenerate}</button>
                </div>
              ` : ""}
            </div>
          </div>
        `;
      }).join("");
    }

    function setGenerating(isGen) {
      STATE.isGenerating = isGen;
      sendBtn.classList.toggle("hidden", isGen);
      stopBtn.classList.toggle("hidden", !isGen);
    }

    function showError(msg) { errorBanner.classList.remove("hidden"); errorMessage.innerText = msg; }
    function hideError() { errorBanner.classList.add("hidden"); }

    function exportSingleHtmlFile() {
      const clone = document.documentElement.cloneNode(true);
      const apiInputInClone = clone.querySelector("#apiKeyInput");
      if (apiInputInClone) apiInputInClone.value = "";
      const customKeyInClone = clone.querySelector("#customApiKeyInput");
      if (customKeyInClone) customKeyInClone.value = "";

      const fullHtml = "<!DOCTYPE html>\n" + clone.outerHTML;
      const blob = new Blob([fullHtml], { type: "text/html;charset=utf-8" });
      const url = URL.createObjectURL(blob);
      const a = document.createElement("a");
      a.href = url;
      a.download = "multimodal-ai-chat-liquid-glass.html";
      document.body.appendChild(a);
      a.click();
      document.body.removeChild(a);
      URL.revokeObjectURL(url);
    }

    if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
    else init();
  </script>
</body>
</html>
"""#
