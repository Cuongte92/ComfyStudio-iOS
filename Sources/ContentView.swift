import SwiftUI
import WebKit
import PhotosUI
import UniformTypeIdentifiers

struct ContentView: View {
    var body: some View {
        ComfyHybridWebView(htmlContent: embeddedHybridHTML)
            .ignoresSafeArea(.container, edges: .bottom)
            .background(Color(red: 9/255, green: 9/255, blue: 11/255))
            .preferredColorScheme(.dark)
    }
}

struct ComfyHybridWebView: UIViewRepresentable {
    let htmlContent: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")

        let cc = config.userContentController
        cc.add(context.coordinator, name: "nativeImagePickerHandler")
        cc.add(context.coordinator, name: "saveImageHandler")
        cc.add(context.coordinator, name: "scanLocalModelsHandler")
        cc.add(context.coordinator, name: "importLocalModelHandler")
        cc.add(context.coordinator, name: "generateLocalHandler")
        cc.add(context.coordinator, name: "cancelLocalHandler")

        let webView = WKWebView(frame: .zero, configuration: config)
        context.coordinator.webView = webView
        webView.isOpaque = false
        webView.backgroundColor = UIColor(red: 9/255, green: 9/255, blue: 11/255, alpha: 1.0)
        webView.scrollView.backgroundColor = UIColor(red: 9/255, green: 9/255, blue: 11/255, alpha: 1.0)
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.uiDelegate = context.coordinator

        context.coordinator.ensureLocalDirectories()
        webView.loadHTMLString(htmlContent, baseURL: URL(string: "https://localhost"))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        let cc = uiView.configuration.userContentController
        cc.removeScriptMessageHandler(forName: "nativeImagePickerHandler")
        cc.removeScriptMessageHandler(forName: "saveImageHandler")
        cc.removeScriptMessageHandler(forName: "scanLocalModelsHandler")
        cc.removeScriptMessageHandler(forName: "importLocalModelHandler")
        cc.removeScriptMessageHandler(forName: "generateLocalHandler")
        cc.removeScriptMessageHandler(forName: "cancelLocalHandler")
    }

    class Coordinator: NSObject, WKScriptMessageHandler, WKUIDelegate, PHPickerViewControllerDelegate, UIDocumentPickerDelegate {
        weak var webView: WKWebView?
        private var pickerMode: String = "image"

        var documentsURL: URL {
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        }

        func ensureLocalDirectories() {
            let modelsDir = documentsURL.appendingPathComponent("Models")
            let lorasDir = documentsURL.appendingPathComponent("LoRAs")
            try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(at: lorasDir, withIntermediateDirectories: true)

            let readmeURL = documentsURL.appendingPathComponent("Huong_dan_chep_model.txt")
            if !FileManager.default.fileExists(atPath: readmeURL.path) {
                let note = "Chep file model (.safetensors / .gguf) vao thu muc Models, va file LoRA vao thu muc LoRAs roi mo app ComfyStudio bam Quet."
                try? note.write(to: readmeURL, atomically: true, encoding: .utf8)
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            switch message.name {
            case "nativeImagePickerHandler":
                self.pickerMode = "image"
                DispatchQueue.main.async { self.showImageSourceSheet() }

            case "importLocalModelHandler":
                self.pickerMode = "model"
                DispatchQueue.main.async {
                    let docPicker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
                    docPicker.allowsMultipleSelection = false
                    docPicker.delegate = self
                    self.presentViewController(docPicker)
                }

            case "scanLocalModelsHandler":
                self.scanAndSendLocalModels()

            case "generateLocalHandler":
                if let params = message.body as? [String: Any] {
                    self.runLocalGeneration(params: params)
                }

            case "cancelLocalHandler":
                SDWrapper.shared().cancelGeneration()

            case "saveImageHandler":
                if let dataUrl = message.body as? String {
                    self.handleSaveBase64Image(dataUrl: dataUrl)
                }

            default:
                break
            }
        }

        private func scanAndSendLocalModels() {
            ensureLocalDirectories()
            let fm = FileManager.default
            var modelsList: [[String: String]] = []
            var lorasList: [[String: String]] = []
            let allowedExts = ["safetensors", "gguf", "ckpt"]

            let searchDirs = [documentsURL.appendingPathComponent("Models"), documentsURL]
            var seenPaths = Set<String>()

            for dir in searchDirs {
                if let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) {
                    for url in items {
                        let ext = url.pathExtension.lowercased()
                        if allowedExts.contains(ext) && !seenPaths.contains(url.path) {
                            seenPaths.insert(url.path)
                            let sizeBytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                            let sizeGB = String(format: "%.2f GB", Double(sizeBytes) / 1_073_741_824.0)
                            modelsList.append([
                                "name": "\(url.lastPathComponent) (\(sizeGB))",
                                "path": url.path
                            ])
                        }
                    }
                }
            }

            let lorasDir = documentsURL.appendingPathComponent("LoRAs")
            if let loraItems = try? fm.contentsOfDirectory(at: lorasDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                for url in loraItems {
                    let ext = url.pathExtension.lowercased()
                    if allowedExts.contains(ext) {
                        lorasList.append([
                            "name": url.lastPathComponent,
                            "path": url.path
                        ])
                    }
                }
            }

            let payload: [String: Any] = ["models": modelsList, "loras": lorasList]
            if let jsonData = try? JSONSerialization.data(withJSONObject: payload),
               let jsonStr = String(data: jsonData, encoding: .utf8) {
                DispatchQueue.main.async {
                    self.webView?.evaluateJavaScript("window.receiveLocalModelsList(\(jsonStr));", completionHandler: nil)
                }
            }
        }

        private func runLocalGeneration(params: [String: Any]) {
            guard let modelPath = params["modelPath"] as? String, !modelPath.isEmpty else {
                DispatchQueue.main.async {
                    self.webView?.evaluateJavaScript("window.onLocalGenError('Chưa chọn file Model Local trên iPhone!');", completionHandler: nil)
                }
                return
            }

            let loraPath = params["loraPath"] as? String
            let loraStrength = (params["loraStrength"] as? NSNumber)?.floatValue ?? 0.8
            let prompt = params["prompt"] as? String ?? ""
            let negativePrompt = params["negativePrompt"] as? String ?? ""
            let width = (params["width"] as? NSNumber)?.int32Value ?? 1024
            let height = (params["height"] as? NSNumber)?.int32Value ?? 1024
            let steps = (params["steps"] as? NSNumber)?.int32Value ?? 8
            let cfg = (params["cfg"] as? NSNumber)?.floatValue ?? 2.0
            let seed = (params["seed"] as? NSNumber)?.int64Value ?? 42
            let initImage = params["initImage"] as? String
            let maskImage = params["maskImage"] as? String
            let denoise = (params["denoise"] as? NSNumber)?.floatValue ?? 0.75

            SDWrapper.shared().generateImage(
                withModelPath: modelPath,
                loraPath: (loraPath == "None" || loraPath == "") ? nil : loraPath,
                loraStrength: loraStrength,
                prompt: prompt,
                negativePrompt: negativePrompt,
                width: width,
                height: height,
                steps: steps,
                cfgScale: cfg,
                seed: seed,
                initImageBase64: initImage,
                maskImageBase64: maskImage,
                denoise: denoise,
                progress: { step, totalSteps, elapsed in
                    self.webView?.evaluateJavaScript("window.onLocalGenProgress(\(step), \(totalSteps), \(elapsed));", completionHandler: nil)
                },
                completion: { base64Png, errorMsg in
                    if let err = errorMsg {
                        let safeErr = err.replacingOccurrences(of: "'", with: "\\'")
                        self.webView?.evaluateJavaScript("window.onLocalGenError('\(safeErr)');", completionHandler: nil)
                    } else if let b64 = base64Png {
                        self.webView?.evaluateJavaScript("window.onLocalGenComplete('\(b64)');", completionHandler: nil)
                    }
                }
            )
        }

        private func showImageSourceSheet() {
            let sheet = UIAlertController(title: "Chọn ảnh nguồn", message: nil, preferredStyle: .actionSheet)
            sheet.addAction(UIAlertAction(title: "Thư viện ảnh (Photo Library)", style: .default) { _ in
                var config = PHPickerConfiguration()
                config.selectionLimit = 1
                config.filter = .images
                let picker = PHPickerViewController(configuration: config)
                picker.delegate = self
                self.presentViewController(picker)
            })
            sheet.addAction(UIAlertAction(title: "Chọn từ Tệp (Files)", style: .default) { _ in
                let docPicker = UIDocumentPickerViewController(forOpeningContentTypes: [.image], asCopy: true)
                docPicker.allowsMultipleSelection = false
                docPicker.delegate = self
                self.presentViewController(docPicker)
            })
            sheet.addAction(UIAlertAction(title: "Hủy", style: .cancel))
            presentViewController(sheet)
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard let provider = results.first?.itemProvider, provider.canLoadObject(ofClass: UIImage.self) else { return }
            provider.loadObject(ofClass: UIImage.self) { object, _ in
                if let image = object as? UIImage, let pngData = image.pngData() {
                    let base64 = "data:image/png;base64," + pngData.base64EncodedString()
                    DispatchQueue.main.async {
                        self.webView?.evaluateJavaScript("window.receiveNativeSourceImage('\(base64)');", completionHandler: nil)
                    }
                }
            }
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            if pickerMode == "image" {
                guard let data = try? Data(contentsOf: url), let image = UIImage(data: data), let pngData = image.pngData() else { return }
                let base64 = "data:image/png;base64," + pngData.base64EncodedString()
                DispatchQueue.main.async {
                    self.webView?.evaluateJavaScript("window.receiveNativeSourceImage('\(base64)');", completionHandler: nil)
                }
            } else {
                let destURL = documentsURL.appendingPathComponent("Models").appendingPathComponent(url.lastPathComponent)
                try? FileManager.default.removeItem(at: destURL)
                try? FileManager.default.copyItem(at: url, to: destURL)
                self.scanAndSendLocalModels()
            }
        }

        private func handleSaveBase64Image(dataUrl: String) {
            guard let commaRange = dataUrl.range(of: ",") else { return }
            let base64Str = String(dataUrl[commaRange.upperBound...])
            guard let data = Data(base64Encoded: base64Str), let image = UIImage(data: data) else { return }

            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("ComfyStudio_\(Int(Date().timeIntervalSince1970)).png")
            try? data.write(to: tempURL)

            DispatchQueue.main.async {
                let activityVC = UIActivityViewController(activityItems: [image, tempURL], applicationActivities: nil)
                self.presentViewController(activityVC)
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
    }
}

let embeddedHybridHTML = #"""
<!doctype html>
<html lang="vi" class="dark">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no, viewport-fit=cover" />
    <title>ComfyStudio Hybrid — A19 Pro Metal & Cloud</title>
    <script src="https://cdn.tailwindcss.com"></script>
    <script>
      tailwind.config = {
        darkMode: 'class',
        theme: {
          extend: {
            colors: {
              zinc: { 850: '#1c1c21', 925: '#121216', 950: '#09090b' },
              primary: { 400: '#818cf8', 500: '#6366f1', 600: '#4f46e5' }
            }
          }
        }
      }
    </script>
    <style>
      html, body { overscroll-behavior-y: none; -webkit-text-size-adjust: 100%; background-color: #09090b; }
      ::-webkit-scrollbar { width: 4px; height: 4px; }
      ::-webkit-scrollbar-track { background: transparent; }
      ::-webkit-scrollbar-thumb { background: rgba(255,255,255,0.16); border-radius: 4px; }
      .glass-panel {
        background: rgba(20, 20, 26, 0.76);
        backdrop-filter: blur(22px) saturate(180%);
        -webkit-backdrop-filter: blur(22px) saturate(180%);
        border: 1px solid rgba(255, 255, 255, 0.09);
        box-shadow: inset 0 1px 0 rgba(255, 255, 255, 0.08), 0 8px 24px rgba(0, 0, 0, 0.35);
      }
      .checkerboard-pattern {
        background-color: #0c0c10;
        background-image: linear-gradient(45deg, #15151b 25%, transparent 25%),
                          linear-gradient(-45deg, #15151b 25%, transparent 25%),
                          linear-gradient(45deg, transparent 75%, #15151b 75%),
                          linear-gradient(-45deg, transparent 75%, #15151b 75%);
        background-size: 20px 20px;
        background-position: 0 0, 0 10px, 10px -10px, -10px 0px;
      }
      #canvas-wrapper, #mask-canvas, #base-canvas { touch-action: none; -webkit-user-select: none; user-select: none; }
      input[type="text"], input[type="number"], textarea, select { font-size: 16px !important; }
    </style>
  </head>
  <body class="bg-zinc-950 text-zinc-100 min-h-screen flex flex-col font-sans antialiased pb-[env(safe-area-inset-bottom)]">

    <div id="toast-container" class="fixed top-3 right-3 left-3 sm:left-auto sm:w-96 z-50 flex flex-col gap-2 pointer-events-none"></div>

    <!-- Vòng tròn preview cỡ cọ giữa màn hình -->
    <div id="brush-preview-overlay" class="fixed inset-0 pointer-events-none z-40 flex items-center justify-center hidden">
      <div id="brush-preview-circle" class="rounded-full border-2 border-rose-400 bg-rose-500/30 shadow-lg"></div>
    </div>

    <!-- Header -->
    <header class="border-b border-white/10 bg-zinc-950/85 backdrop-blur-xl sticky top-0 z-30 px-3.5 py-2.5 pt-[max(0.65rem,env(safe-area-inset-top))]">
      <div class="max-w-[1720px] mx-auto flex flex-col sm:flex-row sm:items-center justify-between gap-2.5">
        <div class="flex items-center justify-between">
          <div class="flex items-center gap-2.5">
            <div class="h-8 w-8 rounded-xl bg-gradient-to-tr from-indigo-600 to-violet-500 flex items-center justify-center font-bold text-white shadow-lg shadow-indigo-500/30">⚡</div>
            <div>
              <div class="flex items-center gap-1.5">
                <span class="font-bold tracking-tight text-white text-sm">ComfyStudio</span>
                <span id="header-engine-badge" class="text-[9px] font-mono uppercase bg-emerald-950 text-emerald-300 px-1.5 py-0.5 rounded border border-emerald-700/60">A19 Pro Metal</span>
              </div>
              <div class="text-[10px] text-zinc-400">Dual Engine · Offline & Tunnel</div>
            </div>
          </div>

          <!-- Bộ chuyển Engine: Local iPhone vs Colab Server -->
          <div class="flex items-center bg-zinc-900 p-1 rounded-xl border border-white/10 text-xs">
            <button id="engine-local-btn" type="button" class="px-2.5 py-1 rounded-lg font-semibold bg-emerald-600 text-white shadow transition">📱 Local</button>
            <button id="engine-cloud-btn" type="button" class="px-2.5 py-1 rounded-lg font-medium text-zinc-400 hover:text-white transition">☁️ Colab</button>
          </div>
        </div>

        <!-- Thanh công cụ Engine Local -->
        <div id="local-header-bar" class="flex items-center justify-between gap-2 bg-zinc-900/80 px-3 py-1.5 rounded-xl border border-white/10 text-xs">
          <span class="text-zinc-300 truncate">Tệp: <strong class="text-emerald-400 font-mono">ComfyStudio/Models</strong></span>
          <div class="flex items-center gap-1.5 shrink-0">
            <button id="btn-import-model" type="button" class="px-2.5 py-1 rounded-lg bg-zinc-800 hover:bg-zinc-700 text-amber-300 border border-amber-500/30 text-[11px] font-medium">+ Nạp File</button>
            <button id="btn-scan-local" type="button" class="px-2.5 py-1 rounded-lg bg-emerald-600 hover:bg-emerald-500 text-white text-[11px] font-semibold">🔄 Quét</button>
          </div>
        </div>

        <!-- Thanh công cụ Engine Colab -->
        <div id="cloud-header-bar" class="hidden flex items-center gap-1.5 w-full sm:max-w-xl">
          <div class="relative flex-1">
            <input id="server-url-input" type="text" class="w-full bg-zinc-900/90 border border-zinc-700/80 rounded-xl pl-3 pr-20 py-1.5 text-zinc-200 placeholder-zinc-500 font-mono focus:outline-none focus:ring-1 focus:ring-indigo-500" placeholder="https://xxxx.trycloudflare.com" />
            <div class="absolute inset-y-0 right-1.5 flex items-center gap-1.5">
              <button id="btn-paste-url" type="button" class="px-2 py-1 text-[10px] bg-zinc-800 hover:bg-zinc-700 text-zinc-200 rounded-lg border border-zinc-700">📋 Dán</button>
              <span id="connection-status-dot" class="w-2.5 h-2.5 rounded-full bg-zinc-500"></span>
            </div>
          </div>
          <button id="btn-connect" type="button" class="flex items-center gap-1 bg-indigo-600 hover:bg-indigo-500 text-white text-xs font-semibold px-3.5 py-2 rounded-xl shadow-md transition whitespace-nowrap">
            <svg id="connect-spinner" class="w-3.5 h-3.5 animate-spin hidden" viewBox="0 0 24 24" fill="none"><circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle><path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8v8H4z"></path></svg>
            <span id="connect-text">Kết nối</span>
          </button>
        </div>
      </div>
    </header>

    <!-- Main Grid -->
    <main class="flex-1 max-w-[1720px] w-full mx-auto p-3 sm:p-4 grid grid-cols-1 lg:grid-cols-12 gap-4">

      <!-- CỘT TRÁI (5 cols) -->
      <section class="lg:col-span-5 flex flex-col gap-3.5">

        <!-- Mode Tabs -->
        <div class="glass-panel rounded-2xl p-1.5">
          <div id="tabs-grid" class="grid grid-cols-4 gap-1 bg-zinc-950/80 p-1 rounded-xl border border-white/5 text-xs">
            <button id="tab-t2i" data-mode="t2i" type="button" class="mode-tab py-1.5 rounded-lg font-semibold bg-indigo-600 text-white text-center shadow">T2I</button>
            <button id="tab-i2i" data-mode="i2i" type="button" class="mode-tab py-1.5 rounded-lg font-medium text-zinc-400 text-center">I2I</button>
            <button id="tab-depth" data-mode="depth" type="button" class="mode-tab py-1.5 rounded-lg font-medium text-zinc-400 text-center">Depth</button>
            <button id="tab-inpaint" data-mode="inpaint" type="button" class="mode-tab py-1.5 rounded-lg font-medium text-zinc-400 text-center">Inpaint</button>
          </div>
        </div>

        <!-- Khối Ảnh Nguồn (I2I / Depth / Inpaint) -->
        <div id="source-image-panel" class="hidden glass-panel rounded-2xl p-3.5 space-y-2.5 border-indigo-500/30">
          <div class="flex items-center justify-between">
            <span id="source-panel-title" class="text-xs font-semibold text-indigo-300">Ảnh Nguồn (Reference Image)</span>
            <button id="btn-pick-source-image" type="button" class="px-3 py-1 rounded-lg bg-indigo-600 hover:bg-indigo-500 text-white text-xs font-medium shadow">🖼️ Chọn Ảnh iPhone</button>
          </div>

          <!-- Denoise cho I2I / Inpaint -->
          <div id="denoise-box" class="pt-1 border-t border-white/10">
            <div class="flex items-center justify-between mb-1 text-xs">
              <span class="text-zinc-300">Mức độ vẽ lại (Denoise):</span>
              <span id="denoise-val" class="text-indigo-400 font-mono font-bold">0.75</span>
            </div>
            <input id="denoise-slider" type="range" min="0.1" max="1.0" step="0.05" value="0.75" class="w-full accent-indigo-500 h-1.5">
          </div>

          <!-- Depth ControlNet (Chỉ dùng cho Colab) -->
          <div id="depth-settings-box" class="hidden pt-1 border-t border-white/10 space-y-2">
            <div>
              <label class="block text-[11px] text-zinc-400 mb-1">ControlNet Depth Model (Colab):</label>
              <select id="select-controlnet" class="w-full bg-zinc-950 border border-zinc-700 rounded-xl px-2.5 py-1.5 text-zinc-200 font-mono">
                <option value="">(Tự động dò ControlNet Depth)</option>
              </select>
            </div>
            <div>
              <div class="flex items-center justify-between mb-1 text-xs">
                <span class="text-zinc-300">Độ bám khối Depth (Strength):</span>
                <span id="depth-strength-val" class="text-cyan-400 font-mono font-bold">0.80</span>
              </div>
              <input id="depth-strength-slider" type="range" min="0.1" max="1.5" step="0.05" value="0.80" class="w-full accent-cyan-500 h-1.5">
            </div>
          </div>
        </div>

        <!-- Model & LoRA -->
        <div class="glass-panel rounded-2xl p-3.5 space-y-3">
          <div class="flex items-center justify-between">
            <h2 class="text-xs font-semibold uppercase tracking-wider text-zinc-400">Kiến trúc & Model</h2>
            <span id="arch-badge" class="text-[10px] font-mono px-2 py-0.5 rounded bg-emerald-950 text-emerald-300 border border-emerald-700/50">SDXL Metal</span>
          </div>

          <div>
            <select id="select-checkpoint" class="w-full bg-zinc-950/90 border border-zinc-700 rounded-xl px-2.5 py-2 text-zinc-200 font-mono">
              <option value="">(Đang quét model trên iPhone...)</option>
            </select>
          </div>

          <!-- LoRA -->
          <div class="bg-zinc-950/70 p-3 rounded-xl border border-white/5 space-y-2 text-xs">
            <div class="flex items-center justify-between">
              <label class="flex items-center gap-2 cursor-pointer font-semibold text-zinc-200">
                <input id="check-enable-lora" type="checkbox" class="w-4 h-4 rounded border-zinc-700 text-indigo-600 bg-zinc-900">
                <span>Kích hoạt LoRA</span>
              </label>
              <span id="lora-strength-val" class="text-indigo-400 font-mono font-bold">0.85</span>
            </div>
            <select id="select-lora" class="w-full bg-zinc-900 border border-zinc-700 rounded-xl px-2.5 py-1.5 text-zinc-200 font-mono">
              <option value="None">None</option>
            </select>
            <input id="lora-strength-slider" type="range" min="0.1" max="1.5" step="0.05" value="0.85" class="w-full accent-indigo-500 h-1.5">
          </div>
        </div>

        <!-- Prompts -->
        <div class="glass-panel rounded-2xl p-3.5 space-y-2.5">
          <div class="flex items-center justify-between">
            <label class="font-semibold text-emerald-400 text-xs">Positive Prompt</label>
            <div class="flex items-center gap-2">
              <button id="btn-enhance-prompt" type="button" class="bg-gradient-to-r from-indigo-600 to-violet-600 text-white text-[11px] font-medium px-2.5 py-1 rounded-lg shadow active:scale-95">✨ Phóng tác</button>
              <button id="btn-clear-positive" type="button" class="text-[11px] text-zinc-400 hover:text-zinc-200">Xóa</button>
            </div>
          </div>
          <textarea id="positive-prompt" rows="3" class="w-full bg-zinc-950/90 border border-zinc-700 rounded-xl p-2.5 text-zinc-100 leading-relaxed" placeholder="Mô tả ảnh muốn tạo...">masterpiece, best quality, ultra-detailed cinematic portrait of a handsome athletic man, natural skin texture, volumetric studio lighting, 8k raw photo</textarea>

          <!-- Prompt Chips -->
          <div class="flex flex-wrap items-center gap-1.5 text-[11px]">
            <button type="button" class="tag-chip bg-zinc-800/90 text-rose-300 px-2 py-0.5 rounded-lg border border-rose-800/60" data-tag="fixing his fingers, anatomically correct male hands, detailed five fingers, realistic palms">Sửa Ngón Tay</button>
            <button type="button" class="tag-chip bg-zinc-800/90 text-zinc-200 px-2 py-0.5 rounded-lg" data-tag="muscular athletic build, defined pectorals, six-pack abs">Cơ Bắp</button>
            <button type="button" class="tag-chip bg-zinc-800/90 text-zinc-200 px-2 py-0.5 rounded-lg" data-tag="natural skin pores, glistening sweat, micro details">Da Chân Thật</button>
          </div>

          <div id="negative-prompt-container" class="pt-1">
            <div class="flex items-center justify-between mb-1 text-xs">
              <label class="font-medium text-rose-400">Negative Prompt (SDXL)</label>
              <button id="btn-clear-negative" type="button" class="text-[11px] text-zinc-400 hover:text-zinc-200">Xóa</button>
            </div>
            <textarea id="negative-prompt" rows="2" class="w-full bg-zinc-950/90 border border-zinc-700 rounded-xl p-2 text-zinc-100">blurry, low quality, worst quality, distorted anatomy, bad hands, mutated fingers, extra limbs, watermark</textarea>
          </div>
        </div>

        <!-- Thông số & Batch -->
        <div class="glass-panel rounded-2xl p-3.5 space-y-3">
          <div class="flex items-center justify-between text-xs">
            <h2 class="font-semibold uppercase tracking-wider text-zinc-400">Thông Số Sinh Ảnh</h2>
            <div class="flex items-center gap-1 text-[11px]">
              <button type="button" class="preset-dim px-2 py-0.5 rounded-lg bg-zinc-800 text-zinc-200" data-w="1024" data-h="1024">1024²</button>
              <button type="button" class="preset-dim px-2 py-0.5 rounded-lg bg-zinc-800 text-zinc-200" data-w="832" data-h="1216">Dọc</button>
              <button type="button" class="preset-dim px-2 py-0.5 rounded-lg bg-zinc-800 text-zinc-200" data-w="1216" data-h="832">Ngang</button>
            </div>
          </div>

          <div class="flex items-center gap-2">
            <input id="input-width" type="number" step="64" value="1024" class="w-full bg-zinc-950/90 border border-zinc-700 rounded-xl p-1.5 text-center font-mono">
            <button id="btn-swap-dim" type="button" class="px-3 py-2 bg-zinc-800 rounded-xl text-zinc-200">⇄</button>
            <input id="input-height" type="number" step="64" value="1024" class="w-full bg-zinc-950/90 border border-zinc-700 rounded-xl p-1.5 text-center font-mono">
          </div>

          <!-- Batch Size (Chỉ bật khi ở chế độ Colab) -->
          <div id="cloud-batch-box" class="hidden bg-zinc-950/70 p-2.5 rounded-xl border border-white/5 text-xs">
            <div class="flex items-center justify-between">
              <span class="font-medium text-zinc-300">Số Lượng Ảnh (Batch Colab)</span>
              <div class="flex items-center gap-1.5">
                <button type="button" class="batch-preset px-2.5 py-1 rounded-lg bg-indigo-600 text-white font-mono font-bold text-xs" data-batch="1">1</button>
                <button type="button" class="batch-preset px-2.5 py-1 rounded-lg bg-zinc-800 text-zinc-300 font-mono text-xs" data-batch="2">2</button>
                <button type="button" class="batch-preset px-2.5 py-1 rounded-lg bg-zinc-800 text-zinc-300 font-mono text-xs" data-batch="4">4</button>
              </div>
            </div>
          </div>

          <div class="grid grid-cols-2 gap-3 text-xs">
            <div>
              <div class="flex justify-between mb-1"><span>Steps</span><span id="steps-val" class="font-mono text-indigo-400 font-bold">8</span></div>
              <input id="slider-steps" type="range" min="1" max="45" step="1" value="8" class="w-full accent-indigo-500">
            </div>
            <div>
              <div class="flex justify-between mb-1"><span>CFG Scale</span><span id="cfg-val" class="font-mono text-indigo-400 font-bold">2.0</span></div>
              <input id="slider-cfg" type="range" min="1.0" max="15.0" step="0.5" value="2.0" class="w-full accent-indigo-500">
            </div>
          </div>

          <div class="text-xs flex items-center justify-between pt-1">
            <label class="flex items-center gap-2 cursor-pointer text-zinc-300">
              <input id="check-random-seed" type="checkbox" checked class="w-4 h-4 rounded border-zinc-700 text-indigo-600 bg-zinc-950">
              <span>Random Seed</span>
            </label>
            <input id="input-seed" type="number" class="w-36 bg-zinc-950/90 border border-zinc-700 rounded-xl p-1.5 text-center font-mono" value="428591726">
          </div>
        </div>

        <!-- Nút Tạo Ảnh -->
        <div class="flex items-center gap-2">
          <button id="btn-generate" type="button" class="flex-1 flex items-center justify-center gap-2 bg-gradient-to-r from-emerald-600 to-teal-600 text-white font-bold py-3.5 px-4 rounded-2xl shadow-lg transition active:scale-[0.98] text-sm">
            <svg id="generate-spinner" class="w-4 h-4 animate-spin hidden" viewBox="0 0 24 24" fill="none"><circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle><path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8v8H4z"></path></svg>
            <span id="generate-btn-text">⚡ Tạo Ảnh Offline (A19 Pro)</span>
          </button>
          <button id="btn-interrupt" type="button" disabled class="px-4 py-3.5 rounded-2xl bg-zinc-850 text-zinc-300 border border-zinc-700 disabled:opacity-30 font-bold">■</button>
        </div>
      </section>

      <!-- CỘT PHẢI: CANVAS & GALLERY (7 cols) -->
      <section class="lg:col-span-7 flex flex-col gap-3.5">
        <div class="glass-panel rounded-2xl p-3">
          <div class="flex items-center justify-between text-xs mb-1.5">
            <span id="step-label" class="font-medium text-zinc-300">Sẵn sàng trên GPU Metal</span>
            <div class="flex items-center gap-2 font-mono text-[11px]">
              <span id="progress-percentage" class="text-emerald-400 font-bold">0%</span>
              <span id="timer-label" class="text-zinc-500">0.0s</span>
            </div>
          </div>
          <div class="w-full bg-zinc-950 rounded-full h-2 overflow-hidden border border-white/5">
            <div id="progress-fill" class="bg-gradient-to-r from-emerald-500 to-teal-400 h-full rounded-full transition-all duration-150" style="width: 0%"></div>
          </div>
        </div>

        <div class="glass-panel rounded-2xl overflow-hidden flex flex-col flex-1 min-h-[440px]">
          <div class="px-3.5 py-2.5 border-b border-white/10 bg-zinc-900/60 flex items-center justify-between text-xs">
            <span class="font-semibold text-zinc-200">Studio Canvas</span>
            <div class="flex items-center gap-2">
              <button id="btn-upload-canvas-img" type="button" class="text-indigo-400 font-medium">Nạp ảnh</button>
              <span class="text-zinc-700">|</span>
              <button id="btn-fullscreen" type="button" class="text-zinc-300">Toàn màn hình</button>
            </div>
          </div>

          <!-- Thanh cọ Inpaint -->
          <div id="brush-toolbar" class="hidden flex-wrap items-center justify-between px-3 py-2 bg-zinc-950/90 border-b border-white/10 text-xs gap-2">
            <div class="flex items-center bg-zinc-900 p-0.5 rounded-xl border border-zinc-800">
              <button id="btn-brush-mode" type="button" class="px-3 py-1 rounded-lg font-medium bg-rose-600 text-white">🖌️ Tô</button>
              <button id="btn-eraser-mode" type="button" class="px-3 py-1 rounded-lg font-medium text-zinc-400">🧹 Tẩy</button>
            </div>
            <div class="flex items-center gap-2 bg-zinc-900 px-2.5 py-1 rounded-xl border border-zinc-800">
              <span class="text-zinc-400 text-[11px]">Cỡ:</span>
              <input id="brush-size-slider" type="range" min="8" max="150" value="35" class="w-24 accent-rose-500 h-1.5">
              <span id="brush-size-val" class="text-rose-400 font-mono text-[11px] font-bold">35px</span>
            </div>
            <button id="btn-clear-mask" type="button" class="px-2.5 py-1 rounded-xl bg-zinc-900 text-zinc-300 text-[11px] border border-zinc-700">Xóa Mask</button>
          </div>

          <div class="relative flex-1 flex items-center justify-center p-3 checkerboard-pattern min-h-[340px] overflow-hidden">
            <div id="canvas-empty-state" class="flex flex-col items-center justify-center text-center p-6 max-w-xs text-zinc-500">
              <div class="w-14 h-14 rounded-2xl bg-zinc-900/90 border border-white/10 flex items-center justify-center text-2xl mb-3">🎨</div>
              <p class="text-xs text-zinc-300 font-semibold">Chưa có ảnh trên Canvas</p>
              <p class="text-[11px] mt-1 text-zinc-500">Dùng Local iPhone (SDXL offline) hoặc chuyển sang tab Colab để chạy Flux 2 / SDXL Server.</p>
            </div>

            <div id="canvas-generating-overlay" class="absolute inset-0 bg-zinc-950/80 backdrop-blur-sm flex flex-col items-center justify-center gap-2.5 z-20 hidden">
              <div class="w-12 h-12 rounded-full border-4 border-indigo-500/20 border-t-indigo-500 animate-spin"></div>
              <p id="overlay-status-text" class="text-xs font-semibold text-white">Đang xử lý Latents...</p>
            </div>

            <div id="canvas-wrapper" class="relative hidden max-w-full max-h-[480px] rounded-xl overflow-hidden shadow-2xl border border-white/15">
              <canvas id="base-canvas" class="block max-w-full max-h-[480px]"></canvas>
              <canvas id="mask-canvas" class="absolute inset-0 w-full h-full cursor-crosshair z-10"></canvas>
            </div>
          </div>

          <div class="p-3 bg-zinc-900/80 border-t border-white/10 flex items-center justify-between gap-2 text-xs">
            <div class="flex items-center gap-2">
              <button id="btn-download-image" type="button" disabled class="bg-indigo-600 hover:bg-indigo-500 text-white font-medium disabled:opacity-40 px-3 py-1.5 rounded-xl">💾 Lưu / Chia sẻ</button>
              <button id="btn-send-to-inpaint" type="button" disabled class="bg-rose-950/80 text-rose-200 disabled:opacity-40 px-3 py-1.5 rounded-xl border border-rose-700/70">🖌️ Inpaint</button>
            </div>
            <span id="meta-info" class="text-[11px] text-zinc-400 font-mono">Seed: --</span>
          </div>
        </div>

        <!-- Session Gallery -->
        <div class="glass-panel rounded-2xl p-3">
          <div class="flex items-center justify-between text-xs mb-2">
            <span class="font-semibold text-zinc-300">Lịch sử ảnh trong phiên</span>
            <span id="gallery-count" class="text-[11px] text-zinc-500 font-mono">0 ảnh</span>
          </div>
          <div id="gallery-tray" class="flex items-center gap-2 overflow-x-auto pb-1 min-h-[56px]">
            <div id="gallery-empty-notice" class="text-xs text-zinc-500 py-2">Ảnh tạo ra sẽ hiển thị tại đây.</div>
          </div>
        </div>
      </section>
    </main>

    <div id="fullscreen-modal" class="fixed inset-0 z-50 bg-black/95 flex items-center justify-center p-2 hidden">
      <img id="fullscreen-modal-img" class="max-w-full max-h-full object-contain rounded-lg" alt="Fullscreen" />
    </div>

    <script>
      const state = {
        engine: 'local', // 'local' hoặc 'cloud'
        serverUrl: localStorage.getItem('comfystudio_tunnel_url') || '',
        clientId: crypto.randomUUID ? crypto.randomUUID() : ('client_' + Math.random().toString(36).substring(2, 10)),
        ws: null,
        reconnectTimer: null,
        currentPromptId: null,
        currentMode: 't2i',
        batchSize: 1,
        isGenerating: false,
        brushMode: 'brush',
        brushSize: 35,
        isPainting: false,
        lastPoint: null,
        hasMaskDrawn: false,
        baseImageObj: null,

        localModels: [],
        localLoras: [],
        cloudModels: { checkpoints: [], unets: [], clips: [], vaes: [], loras: [], controlnets: [] },

        gallery: [],
        startTime: null,
        timerInterval: null
      };

      const el = {
        engineLocalBtn: document.getElementById('engine-local-btn'),
        engineCloudBtn: document.getElementById('engine-cloud-btn'),
        headerEngineBadge: document.getElementById('header-engine-badge'),
        localHeaderBar: document.getElementById('local-header-bar'),
        cloudHeaderBar: document.getElementById('cloud-header-bar'),
        serverUrlInput: document.getElementById('server-url-input'),
        btnPasteUrl: document.getElementById('btn-paste-url'),
        btnConnect: document.getElementById('btn-connect'),
        connectSpinner: document.getElementById('connect-spinner'),
        connectText: document.getElementById('connect-text'),
        connectionStatusDot: document.getElementById('connection-status-dot'),

        btnImportModel: document.getElementById('btn-import-model'),
        btnScanLocal: document.getElementById('btn-scan-local'),
        selectCheckpoint: document.getElementById('select-checkpoint'),
        archBadge: document.getElementById('arch-badge'),
        selectLora: document.getElementById('select-lora'),
        checkEnableLora: document.getElementById('check-enable-lora'),
        loraStrengthSlider: document.getElementById('lora-strength-slider'),
        loraStrengthVal: document.getElementById('lora-strength-val'),

        sourceImagePanel: document.getElementById('source-image-panel'),
        sourcePanelTitle: document.getElementById('source-panel-title'),
        btnPickSourceImage: document.getElementById('btn-pick-source-image'),
        denoiseBox: document.getElementById('denoise-box'),
        denoiseSlider: document.getElementById('denoise-slider'),
        denoiseVal: document.getElementById('denoise-val'),
        depthSettingsBox: document.getElementById('depth-settings-box'),
        selectControlnet: document.getElementById('select-controlnet'),
        depthStrengthSlider: document.getElementById('depth-strength-slider'),
        depthStrengthVal: document.getElementById('depth-strength-val'),

        positivePrompt: document.getElementById('positive-prompt'),
        negativePrompt: document.getElementById('negative-prompt'),
        negativePromptContainer: document.getElementById('negative-prompt-container'),
        inputWidth: document.getElementById('input-width'),
        inputHeight: document.getElementById('input-height'),
        cloudBatchBox: document.getElementById('cloud-batch-box'),
        sliderSteps: document.getElementById('slider-steps'),
        stepsVal: document.getElementById('steps-val'),
        sliderCfg: document.getElementById('slider-cfg'),
        cfgVal: document.getElementById('cfg-val'),
        inputSeed: document.getElementById('input-seed'),
        checkRandomSeed: document.getElementById('check-random-seed'),

        btnGenerate: document.getElementById('btn-generate'),
        generateSpinner: document.getElementById('generate-spinner'),
        generateBtnText: document.getElementById('generate-btn-text'),
        btnInterrupt: document.getElementById('btn-interrupt'),

        stepLabel: document.getElementById('step-label'),
        progressPercentage: document.getElementById('progress-percentage'),
        timerLabel: document.getElementById('timer-label'),
        progressFill: document.getElementById('progress-fill'),
        canvasEmptyState: document.getElementById('canvas-empty-state'),
        canvasGeneratingOverlay: document.getElementById('canvas-generating-overlay'),
        overlayStatusText: document.getElementById('overlay-status-text'),
        canvasWrapper: document.getElementById('canvas-wrapper'),
        baseCanvas: document.getElementById('base-canvas'),
        maskCanvas: document.getElementById('mask-canvas'),
        brushToolbar: document.getElementById('brush-toolbar'),
        btnBrushMode: document.getElementById('btn-brush-mode'),
        btnEraserMode: document.getElementById('btn-eraser-mode'),
        brushSizeSlider: document.getElementById('brush-size-slider'),
        brushSizeVal: document.getElementById('brush-size-val'),
        btnClearMask: document.getElementById('btn-clear-mask'),
        brushPreviewOverlay: document.getElementById('brush-preview-overlay'),
        brushPreviewCircle: document.getElementById('brush-preview-circle'),
        btnDownloadImage: document.getElementById('btn-download-image'),
        btnSendToInpaint: document.getElementById('btn-send-to-inpaint'),
        metaInfo: document.getElementById('meta-info'),
        galleryTray: document.getElementById('gallery-tray'),
        galleryCount: document.getElementById('gallery-count'),
        galleryEmptyNotice: document.getElementById('gallery-empty-notice'),
        toastContainer: document.getElementById('toast-container')
      };

      function showToast(msg, type = 'info') {
        const t = document.createElement('div');
        t.className = `p-3 rounded-2xl border text-xs shadow-2xl backdrop-blur-xl ${
          type === 'error' ? 'bg-rose-950/90 border-rose-700 text-rose-100' :
          type === 'success' ? 'bg-emerald-950/90 border-emerald-700 text-emerald-100' :
          'bg-zinc-900/90 border-zinc-700 text-zinc-100'
        }`;
        t.textContent = msg;
        el.toastContainer.appendChild(t);
        setTimeout(() => t.remove(), 3600);
      }

      function sanitizeUrl(raw) {
        if (!raw) return '';
        let u = raw.trim().replace(/\/+$/, '');
        if (!/^https?:\/\//i.test(u)) u = 'https://' + u;
        return u;
      }

      // === CHUYỂN ĐỔI ENGINE LOCAL <-> COLAB ===
      function switchEngine(target) {
        state.engine = target;
        if (target === 'local') {
          el.engineLocalBtn.className = 'px-2.5 py-1 rounded-lg font-semibold bg-emerald-600 text-white shadow transition';
          el.engineCloudBtn.className = 'px-2.5 py-1 rounded-lg font-medium text-zinc-400 hover:text-white transition';
          el.headerEngineBadge.textContent = 'A19 Pro Metal';
          el.headerEngineBadge.className = 'text-[9px] font-mono uppercase bg-emerald-950 text-emerald-300 px-1.5 py-0.5 rounded border border-emerald-700/60';
          el.localHeaderBar.classList.remove('hidden');
          el.cloudHeaderBar.classList.add('hidden');
          el.cloudBatchBox.classList.add('hidden');
          el.btnGenerate.className = 'flex-1 flex items-center justify-center gap-2 bg-gradient-to-r from-emerald-600 to-teal-600 text-white font-bold py-3.5 px-4 rounded-2xl shadow-lg transition active:scale-[0.98] text-sm';
          el.generateBtnText.textContent = '⚡ Tạo Ảnh Offline (A19 Pro)';
          el.archBadge.textContent = 'SDXL Metal';
          populateLocalDropdowns();
        } else {
          el.engineCloudBtn.className = 'px-2.5 py-1 rounded-lg font-semibold bg-indigo-600 text-white shadow transition';
          el.engineLocalBtn.className = 'px-2.5 py-1 rounded-lg font-medium text-zinc-400 hover:text-white transition';
          el.headerEngineBadge.textContent = 'Colab Tunnel';
          el.headerEngineBadge.className = 'text-[9px] font-mono uppercase bg-indigo-950 text-indigo-300 px-1.5 py-0.5 rounded border border-indigo-700/60';
          el.localHeaderBar.classList.add('hidden');
          el.cloudHeaderBar.classList.remove('hidden');
          el.cloudBatchBox.classList.remove('hidden');
          el.btnGenerate.className = 'flex-1 flex items-center justify-center gap-2 bg-gradient-to-r from-indigo-600 to-violet-600 text-white font-bold py-3.5 px-4 rounded-2xl shadow-lg transition active:scale-[0.98] text-sm';
          el.generateBtnText.textContent = '☁️ Tạo Ảnh Trên Colab';
          populateCloudDropdowns();
        }
      }

      // === LOCAL ENGINE CALLBACKS ===
      window.receiveLocalModelsList = function(data) {
        state.localModels = data.models || [];
        state.localLoras = data.loras || [];
        if (state.engine === 'local') populateLocalDropdowns();
      };

      function populateLocalDropdowns() {
        el.selectCheckpoint.innerHTML = '';
        if (state.localModels.length === 0) {
          el.selectCheckpoint.innerHTML = '<option value="">(Trống — Chép model vào Tệp/ComfyStudio/Models)</option>';
        } else {
          state.localModels.forEach(m => {
            const opt = document.createElement('option');
            opt.value = m.path; opt.textContent = m.name;
            el.selectCheckpoint.appendChild(opt);
          });
        }
        el.selectLora.innerHTML = '<option value="None">None</option>';
        state.localLoras.forEach(l => {
          const opt = document.createElement('option');
          opt.value = l.path; opt.textContent = l.name;
          el.selectLora.appendChild(opt);
        });
        el.negativePromptContainer.classList.remove('opacity-40');
      }

      window.onLocalGenProgress = function(step, totalSteps) {
        const pct = Math.min(99, Math.round((step / Math.max(1, totalSteps)) * 100));
        el.progressFill.style.width = `${pct}%`;
        el.progressPercentage.textContent = `${pct}%`;
        el.stepLabel.textContent = `A19 Pro Metal · Step ${step}/${totalSteps}`;
      };

      window.onLocalGenComplete = function(base64Png) {
        addGalleryThumb(base64Png);
        const im = new Image();
        im.onload = () => syncCanvasWithImage(im);
        im.src = base64Png;
        stopGenUI();
        el.progressFill.style.width = '100%';
        el.progressPercentage.textContent = '100%';
        el.stepLabel.textContent = 'Hoàn tất trên A19 Pro!';
        showToast('Tạo ảnh offline thành công!', 'success');
      };

      window.onLocalGenError = function(errMsg) {
        stopGenUI();
        showToast(errMsg, 'error');
      };

      // === COLAB CLOUD ENGINE ===
      function identifyCloudArch(modelName) {
        if ((modelName || '').toLowerCase().includes('flux')) {
          return { type: 'flux2', badge: 'Flux 2 Klein (FP8)', steps: 4, cfg: 1.0 };
        }
        return { type: 'sdxl', badge: 'SDXL Cloud', steps: 28, cfg: 7.0 };
      }

      function onCloudModelChange() {
        if (state.engine !== 'cloud') return;
        const arch = identifyCloudArch(el.selectCheckpoint.value);
        el.archBadge.textContent = arch.badge;
        el.sliderSteps.value = arch.steps; el.stepsVal.textContent = arch.steps;
        el.sliderCfg.value = arch.cfg; el.cfgVal.textContent = arch.cfg.toFixed(1);
        el.negativePromptContainer.classList.toggle('opacity-40', arch.type === 'flux2');
      }

      async function connectCloudServer() {
        const url = sanitizeUrl(el.serverUrlInput.value);
        if (!url) return showToast('Vui lòng nhập link Cloudflare Tunnel!', 'error');
        state.serverUrl = url;
        localStorage.setItem('comfystudio_tunnel_url', url);

        el.connectSpinner.classList.remove('hidden');
        el.btnConnect.disabled = true;
        el.connectText.textContent = 'Đang nạp...';

        try {
          initCloudWebSocket();
          const res = await fetch(`${url}/object_info`, { signal: AbortSignal.timeout(45000) });
          if (!res.ok) throw new Error(`HTTP ${res.status}`);
          const data = await res.json();

          state.cloudModels = {
            checkpoints: data?.CheckpointLoaderSimple?.input?.required?.ckpt_name?.[0] || [],
            unets: data?.UNETLoader?.input?.required?.unet_name?.[0] || data?.UNetLoader?.input?.required?.unet_name?.[0] || [],
            clips: data?.CLIPLoader?.input?.required?.clip_name?.[0] || [],
            vaes: data?.VAELoader?.input?.required?.vae_name?.[0] || [],
            loras: data?.LoraLoader?.input?.required?.lora_name?.[0] || [],
            controlnets: data?.ControlNetLoader?.input?.required?.control_net_name?.[0] || []
          };
          populateCloudDropdowns();
          showToast('Đã kết nối Colab ComfyUI!', 'success');
        } catch (e) {
          showToast(`Lỗi kết nối: ${e.message}`, 'error');
        } finally {
          el.connectSpinner.classList.add('hidden');
          el.btnConnect.disabled = false;
          el.connectText.textContent = 'Kết nối';
        }
      }

      function populateCloudDropdowns() {
        el.selectCheckpoint.innerHTML = '';
        const all = [...state.cloudModels.checkpoints, ...state.cloudModels.unets];
        if (!all.length) {
          el.selectCheckpoint.innerHTML = '<option value="">(Bấm Kết nối để nạp model từ Colab)</option>';
        } else {
          all.forEach(m => {
            const opt = document.createElement('option');
            opt.value = m; opt.textContent = m;
            el.selectCheckpoint.appendChild(opt);
          });
        }
        el.selectLora.innerHTML = '<option value="None">None</option>';
        state.cloudModels.loras.forEach(l => {
          const opt = document.createElement('option');
          opt.value = l; opt.textContent = l;
          el.selectLora.appendChild(opt);
        });
        el.selectControlnet.innerHTML = '<option value="">(Tự động dò Depth)</option>';
        state.cloudModels.controlnets.forEach(c => {
          const opt = document.createElement('option');
          opt.value = c; opt.textContent = c;
          if (c.toLowerCase().includes('depth')) opt.selected = true;
          el.selectControlnet.appendChild(opt);
        });
        onCloudModelChange();
      }

      async function uploadCloudImages(includeMask) {
        const url = sanitizeUrl(state.serverUrl);
        const baseBlob = await new Promise(r => el.baseCanvas.toBlob(r, 'image/png'));
        const fBase = new FormData();
        fBase.append('image', baseBlob, 'studio_source.png');
        fBase.append('overwrite', 'true');
        await fetch(`${url}/upload/image`, { method: 'POST', body: fBase });

        if (includeMask) {
          const res = await fetch(getMaskExportBase64());
          const maskBlob = await res.blob();
          const fMask = new FormData();
          fMask.append('image', maskBlob, 'studio_mask.png');
          fMask.append('overwrite', 'true');
          await fetch(`${url}/upload/image`, { method: 'POST', body: fMask });
        }
      }

      async function executeCloudGeneration() {
        const activeModel = el.selectCheckpoint.value;
        if (!activeModel) throw new Error('Chưa chọn Model trên Colab!');
        const arch = identifyCloudArch(activeModel);
        const width = parseInt(el.inputWidth.value) || 1024;
        const height = parseInt(el.inputHeight.value) || 1024;
        const steps = parseInt(el.sliderSteps.value) || 4;
        const cfg = parseFloat(el.sliderCfg.value) || 1.0;
        const posPrompt = el.positivePrompt.value.trim();
        const negPrompt = el.negativePrompt.value.trim();
        const batchSize = state.batchSize;

        let seed = parseInt(el.inputSeed.value);
        if (el.checkRandomSeed.checked || isNaN(seed)) {
          seed = Math.floor(Math.random() * 1000000000);
          el.inputSeed.value = seed;
        }

        const mode = state.currentMode;
        if (mode !== 't2i' && !state.baseImageObj) throw new Error(`Chế độ ${mode.toUpperCase()} cần chọn ảnh nguồn trước!`);
        if (mode === 'inpaint' && !state.hasMaskDrawn) throw new Error('Bạn chưa tô vùng mask cần sửa!');

        const denoise = (mode === 't2i' || mode === 'depth') ? 1.0 : (parseFloat(el.denoiseSlider.value) || 0.75);
        if (mode !== 't2i') await uploadCloudImages(mode === 'inpaint');

        const wf = {};
        if (arch.type === 'flux2') {
          wf["1"] = { class_type: "UNETLoader", inputs: { unet_name: activeModel, weight_dtype: "fp8_e4m3fn" } };
          const qwen = state.cloudModels.clips.find(c => c.includes('qwen')) || 'qwen_3_8b_fp8mixed.safetensors';
          wf["2"] = { class_type: "CLIPLoader", inputs: { clip_name: qwen, type: "flux2" } };
          const vae = state.cloudModels.vaes.find(v => v.includes('flux2-vae')) || 'flux2-vae.safetensors';
          wf["3"] = { class_type: "VAELoader", inputs: { vae_name: vae } };
          let curM = ["1", 0], curC = ["2", 0];
          if (el.checkEnableLora.checked && el.selectLora.value !== 'None') {
            wf["10"] = { class_type: "LoraLoader", inputs: { lora_name: el.selectLora.value, strength_model: parseFloat(el.loraStrengthSlider.value) || 1.0, strength_clip: 1.0, model: curM, clip: curC } };
            curM = ["10", 0]; curC = ["10", 1];
          }
          wf["4"] = { class_type: "CLIPTextEncode", inputs: { text: posPrompt, clip: curC } };
          wf["5"] = { class_type: "CLIPTextEncode", inputs: { text: "", clip: curC } };
          let posC = ["4", 0], negC = ["5", 0], latIn = ["6", 0];

          if (mode === 'inpaint') {
            wf["11"] = { class_type: "DifferentialDiffusion", inputs: { model: curM } }; curM = ["11", 0];
            wf["12"] = { class_type: "LoadImage", inputs: { image: "studio_source.png" } };
            wf["13"] = { class_type: "LoadImageMask", inputs: { image: "studio_mask.png", channel: "red" } };
            wf["14"] = { class_type: "VAEEncode", inputs: { pixels: ["12", 0], vae: ["3", 0] } };
            wf["15"] = { class_type: "SetLatentNoiseMask", inputs: { samples: ["14", 0], mask: ["13", 0] } };
            latIn = batchSize > 1 ? (wf["16"] = { class_type: "RepeatLatentBatch", inputs: { samples: ["15", 0], amount: batchSize } }, ["16", 0]) : ["15", 0];
          } else if (mode === 'i2i') {
            wf["12"] = { class_type: "LoadImage", inputs: { image: "studio_source.png" } };
            wf["14"] = { class_type: "VAEEncode", inputs: { pixels: ["12", 0], vae: ["3", 0] } };
            latIn = batchSize > 1 ? (wf["16"] = { class_type: "RepeatLatentBatch", inputs: { samples: ["14", 0], amount: batchSize } }, ["16", 0]) : ["14", 0];
          } else if (mode === 'depth') {
            const cn = el.selectControlnet.value;
            if (!cn) throw new Error('Thiếu model ControlNet Depth trên server!');
            wf["12"] = { class_type: "LoadImage", inputs: { image: "studio_source.png" } };
            wf["17"] = { class_type: "ControlNetLoader", inputs: { control_net_name: cn } };
            wf["18"] = { class_type: "ControlNetApplyAdvanced", inputs: { positive: posC, negative: negC, control_net: ["17", 0], image: ["12", 0], strength: parseFloat(el.depthStrengthSlider.value) || 0.8, start_percent: 0, end_percent: 1 } };
            posC = ["18", 0]; negC = ["18", 1];
            wf["6"] = { class_type: "EmptyLatentImage", inputs: { width, height, batch_size: batchSize } };
          } else {
            wf["6"] = { class_type: "EmptyLatentImage", inputs: { width, height, batch_size: batchSize } };
          }

          wf["7"] = { class_type: "KSampler", inputs: { seed, steps, cfg, sampler_name: "euler", scheduler: "simple", denoise, model: curM, positive: posC, negative: negC, latent_image: latIn } };
          wf["8"] = { class_type: "VAEDecode", inputs: { samples: ["7", 0], vae: ["3", 0] } };
          wf["9"] = { class_type: "SaveImage", inputs: { filename_prefix: "ComfyStudio_Flux", images: ["8", 0] } };
        } else {
          wf["1"] = { class_type: "CheckpointLoaderSimple", inputs: { ckpt_name: activeModel } };
          let curM = ["1", 0], curC = ["1", 1];
          if (el.checkEnableLora.checked && el.selectLora.value !== 'None') {
            wf["10"] = { class_type: "LoraLoader", inputs: { lora_name: el.selectLora.value, strength_model: parseFloat(el.loraStrengthSlider.value) || 0.8, strength_clip: 0.8, model: curM, clip: curC } };
            curM = ["10", 0]; curC = ["10", 1];
          }
          wf["2"] = { class_type: "CLIPTextEncode", inputs: { text: posPrompt, clip: curC } };
          wf["3"] = { class_type: "CLIPTextEncode", inputs: { text: negPrompt, clip: curC } };
          let posC = ["2", 0], negC = ["3", 0], latIn = ["4", 0];

          if (mode === 'inpaint') {
            wf["12"] = { class_type: "LoadImage", inputs: { image: "studio_source.png" } };
            wf["13"] = { class_type: "LoadImageMask", inputs: { image: "studio_mask.png", channel: "red" } };
            wf["14"] = { class_type: "VAEEncodeForInpaint", inputs: { pixels: ["12", 0], vae: ["1", 2], mask: ["13", 0], grow_mask_by: 6 } };
            latIn = batchSize > 1 ? (wf["16"] = { class_type: "RepeatLatentBatch", inputs: { samples: ["14", 0], amount: batchSize } }, ["16", 0]) : ["14", 0];
          } else if (mode === 'i2i') {
            wf["12"] = { class_type: "LoadImage", inputs: { image: "studio_source.png" } };
            wf["14"] = { class_type: "VAEEncode", inputs: { pixels: ["12", 0], vae: ["1", 2] } };
            latIn = batchSize > 1 ? (wf["16"] = { class_type: "RepeatLatentBatch", inputs: { samples: ["14", 0], amount: batchSize } }, ["16", 0]) : ["14", 0];
          } else if (mode === 'depth') {
            const cn = el.selectControlnet.value;
            if (!cn) throw new Error('Thiếu model ControlNet Depth trên server!');
            wf["12"] = { class_type: "LoadImage", inputs: { image: "studio_source.png" } };
            wf["17"] = { class_type: "ControlNetLoader", inputs: { control_net_name: cn } };
            wf["18"] = { class_type: "ControlNetApplyAdvanced", inputs: { positive: posC, negative: negC, control_net: ["17", 0], image: ["12", 0], strength: parseFloat(el.depthStrengthSlider.value) || 0.8, start_percent: 0, end_percent: 1 } };
            posC = ["18", 0]; negC = ["18", 1];
            wf["4"] = { class_type: "EmptyLatentImage", inputs: { width, height, batch_size: batchSize } };
          } else {
            wf["4"] = { class_type: "EmptyLatentImage", inputs: { width, height, batch_size: batchSize } };
          }

          wf["5"] = { class_type: "KSampler", inputs: { seed, steps, cfg, sampler_name: "dpmpp_2m", scheduler: "karras", denoise, model: curM, positive: posC, negative: negC, latent_image: latIn } };
          wf["6"] = { class_type: "VAEDecode", inputs: { samples: ["5", 0], vae: ["1", 2] } };
          wf["7"] = { class_type: "SaveImage", inputs: { filename_prefix: "ComfyStudio_SDXL", images: ["6", 0] } };
        }

        startGenUI('Đang xử lý trên Colab GPU...');
        const res = await fetch(`${sanitizeUrl(state.serverUrl)}/prompt`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ client_id: state.clientId, prompt: wf })
        });
        if (!res.ok) throw new Error(await res.text());
        const data = await res.json();
        state.currentPromptId = data.prompt_id;
        el.metaInfo.textContent = `Seed: ${seed} · Steps: ${steps}`;
      }

      function initCloudWebSocket() {
        if (state.reconnectTimer) clearTimeout(state.reconnectTimer);
        if (state.ws) { try { state.ws.close(); } catch(e){} }
        const wsUrl = sanitizeUrl(state.serverUrl).replace(/^http/, 'ws') + `/ws?clientId=${state.clientId}`;
        state.ws = new WebSocket(wsUrl);
        state.ws.onopen = () => { el.connectionStatusDot.className = 'w-2.5 h-2.5 rounded-full bg-emerald-500'; };
        state.ws.onmessage = (evt) => {
          if (typeof evt.data !== 'string') return;
          const msg = JSON.parse(evt.data);
          if (msg.type === 'progress') {
            const pct = Math.round((msg.data.value / msg.data.max) * 100);
            el.progressFill.style.width = `${pct}%`;
            el.progressPercentage.textContent = `${pct}%`;
            el.stepLabel.textContent = `Colab · Step ${msg.data.value}/${msg.data.max}`;
          } else if (msg.type === 'executed' && msg.data?.output?.images?.length) {
            const imgs = msg.data.output.images;
            imgs.forEach((img, idx) => {
              const imgUrl = `${sanitizeUrl(state.serverUrl)}/view?filename=${encodeURIComponent(img.filename)}&subfolder=${encodeURIComponent(img.subfolder||'')}&type=${encodeURIComponent(img.type||'output')}`;
              addGalleryThumb(imgUrl);
              if (idx === 0) {
                const im = new Image();
                im.crossOrigin = 'anonymous';
                im.onload = () => syncCanvasWithImage(im);
                im.src = imgUrl;
              }
            });
            stopGenUI();
            el.progressFill.style.width = '100%';
            el.progressPercentage.textContent = '100%';
            el.stepLabel.textContent = 'Hoàn tất!';
            showToast(`Đã nhận ${imgs.length} ảnh từ Colab!`, 'success');
          }
        };
        state.ws.onclose = () => {
          el.connectionStatusDot.className = 'w-2.5 h-2.5 rounded-full bg-amber-500';
          state.reconnectTimer = setTimeout(() => { if (state.serverUrl && state.engine === 'cloud') initCloudWebSocket(); }, 3000);
        };
      }

      // === CHUNG CHO CẢ 2 ENGINE ===
      function syncCanvasWithImage(img) {
        state.baseImageObj = img;
        const w = img.naturalWidth || img.width || 1024;
        const h = img.naturalHeight || img.height || 1024;
        el.baseCanvas.width = w; el.baseCanvas.height = h;
        el.maskCanvas.width = w; el.maskCanvas.height = h;
        const ctx = el.baseCanvas.getContext('2d');
        ctx.clearRect(0, 0, w, h);
        ctx.drawImage(img, 0, 0, w, h);
        clearMask();
        el.canvasEmptyState.classList.add('hidden');
        el.canvasWrapper.classList.remove('hidden');
        el.btnDownloadImage.disabled = false;
        el.btnSendToInpaint.disabled = false;
      }

      function clearMask() {
        el.maskCanvas.getContext('2d').clearRect(0, 0, el.maskCanvas.width, el.maskCanvas.height);
        state.hasMaskDrawn = false;
      }

      function getMaskExportBase64() {
        const mCanvas = document.createElement('canvas');
        mCanvas.width = el.baseCanvas.width; mCanvas.height = el.baseCanvas.height;
        const mCtx = mCanvas.getContext('2d');
        mCtx.fillStyle = '#000000'; mCtx.fillRect(0, 0, mCanvas.width, mCanvas.height);
        const mData = el.maskCanvas.getContext('2d').getImageData(0, 0, el.maskCanvas.width, el.maskCanvas.height);
        const expData = mCtx.getImageData(0, 0, mCanvas.width, mCanvas.height);
        for (let i = 0; i < mData.data.length; i += 4) {
          if (mData.data[i + 3] > 10) {
            expData.data[i] = 255; expData.data[i + 1] = 255; expData.data[i + 2] = 255; expData.data[i + 3] = 255;
          }
        }
        mCtx.putImageData(expData, 0, 0);
        return mCanvas.toDataURL('image/png');
      }

      function addGalleryThumb(url) {
        state.gallery.unshift(url);
        el.galleryCount.textContent = `${state.gallery.length} ảnh`;
        el.galleryEmptyNotice.classList.add('hidden');
        const d = document.createElement('div');
        d.className = 'shrink-0 w-14 h-14 rounded-xl overflow-hidden border border-white/15 hover:border-indigo-400 cursor-pointer transition';
        d.innerHTML = `<img src="${url}" class="w-full h-full object-cover">`;
        d.onclick = () => {
          const im = new Image();
          im.crossOrigin = 'anonymous';
          im.onload = () => syncCanvasWithImage(im);
          im.src = url;
        };
        el.galleryTray.prepend(d);
      }

      function startGenUI(statusTxt) {
        state.isGenerating = true;
        state.startTime = Date.now();
        el.btnGenerate.disabled = true;
        el.generateSpinner.classList.remove('hidden');
        el.btnInterrupt.disabled = false;
        el.overlayStatusText.textContent = statusTxt;
        el.canvasGeneratingOverlay.classList.remove('hidden');
        el.progressFill.style.width = '5%';
        clearInterval(state.timerInterval);
        state.timerInterval = setInterval(() => {
          el.timerLabel.textContent = `${((Date.now() - state.startTime) / 1000).toFixed(1)}s`;
        }, 100);
      }

      function stopGenUI() {
        state.isGenerating = false;
        clearInterval(state.timerInterval);
        el.btnGenerate.disabled = false;
        el.generateSpinner.classList.add('hidden');
        el.btnInterrupt.disabled = true;
        el.canvasGeneratingOverlay.classList.add('hidden');
      }

      async function handleGenerateClick() {
        if (state.isGenerating) return;
        if (state.engine === 'cloud') {
          try { await executeCloudGeneration(); } catch (e) { stopGenUI(); showToast(e.message, 'error'); }
          return;
        }

        // Local A19 Pro Metal
        const modelPath = el.selectCheckpoint.value;
        if (!modelPath) return showToast('Chưa chọn model! Hãy bấm Nạp File hoặc chép model vào Tệp/ComfyStudio/Models.', 'error');
        if (state.currentMode === 'depth') return showToast('Depth ControlNet chỉ hỗ trợ trên chế độ Colab!', 'info');
        if ((state.currentMode === 'i2i' || state.currentMode === 'inpaint') && !state.baseImageObj) return showToast('Hãy chọn ảnh nguồn trước!', 'error');
        if (state.currentMode === 'inpaint' && !state.hasMaskDrawn) return showToast('Hãy tô vùng mask cần sửa trên ảnh!', 'error');

        let seed = parseInt(el.inputSeed.value);
        if (el.checkRandomSeed.checked || isNaN(seed)) {
          seed = Math.floor(Math.random() * 1000000000);
          el.inputSeed.value = seed;
        }
        el.metaInfo.textContent = `Seed: ${seed} · Steps: ${el.sliderSteps.value}`;

        startGenUI('Đang chạy SDXL trên GPU A19 Pro...');
        window.webkit?.messageHandlers?.generateLocalHandler?.postMessage({
          modelPath,
          loraPath: el.checkEnableLora.checked ? el.selectLora.value : 'None',
          loraStrength: parseFloat(el.loraStrengthSlider.value) || 0.85,
          prompt: el.positivePrompt.value.trim(),
          negativePrompt: el.negativePrompt.value.trim(),
          width: parseInt(el.inputWidth.value) || 1024,
          height: parseInt(el.inputHeight.value) || 1024,
          steps: parseInt(el.sliderSteps.value) || 8,
          cfg: parseFloat(el.sliderCfg.value) || 2.0,
          seed,
          initImage: (state.currentMode !== 't2i') ? el.baseCanvas.toDataURL('image/png') : null,
          maskImage: (state.currentMode === 'inpaint') ? getMaskExportBase64() : null,
          denoise: parseFloat(el.denoiseSlider.value) || 0.75
        });
      }

      window.receiveNativeSourceImage = function(dataUrl) {
        const im = new Image();
        im.onload = () => { syncCanvasWithImage(im); showToast('Đã nạp ảnh nguồn!', 'success'); };
        im.src = dataUrl;
      };

      // Vẽ Mask
      function getCanvasPt(e) {
        const r = el.maskCanvas.getBoundingClientRect();
        return { x: (e.clientX - r.left) * (el.maskCanvas.width / r.width), y: (e.clientY - r.top) * (el.maskCanvas.height / r.height) };
      }
      function drawStroke(x, y, isStart) {
        const ctx = el.maskCanvas.getContext('2d');
        ctx.lineCap = 'round'; ctx.lineJoin = 'round'; ctx.lineWidth = state.brushSize;
        if (state.brushMode === 'eraser') {
          ctx.globalCompositeOperation = 'destination-out';
          ctx.strokeStyle = 'rgba(0,0,0,1)'; ctx.fillStyle = 'rgba(0,0,0,1)';
        } else {
          ctx.globalCompositeOperation = 'source-over';
          ctx.strokeStyle = 'rgba(244,63,94,0.65)'; ctx.fillStyle = 'rgba(244,63,94,0.65)';
          state.hasMaskDrawn = true;
        }
        if (isStart || !state.lastPoint) { ctx.beginPath(); ctx.arc(x, y, state.brushSize / 2, 0, Math.PI * 2); ctx.fill(); }
        else { ctx.beginPath(); ctx.moveTo(state.lastPoint.x, state.lastPoint.y); ctx.lineTo(x, y); ctx.stroke(); }
      }
      el.maskCanvas.addEventListener('pointerdown', e => {
        if (state.currentMode !== 'inpaint') return;
        e.preventDefault(); state.isPainting = true;
        const pt = getCanvasPt(e); state.lastPoint = pt; drawStroke(pt.x, pt.y, true);
      }, { passive: false });
      el.maskCanvas.addEventListener('pointermove', e => {
        if (!state.isPainting) return;
        e.preventDefault(); const pt = getCanvasPt(e); drawStroke(pt.x, pt.y, false); state.lastPoint = pt;
      }, { passive: false });
      window.addEventListener('pointerup', () => { state.isPainting = false; state.lastPoint = null; });

      // Gắn sự kiện
      el.engineLocalBtn.addEventListener('click', () => switchEngine('local'));
      el.engineCloudBtn.addEventListener('click', () => switchEngine('cloud'));
      el.btnConnect.addEventListener('click', connectCloudServer);
      el.btnPasteUrl.addEventListener('click', async () => { try { const t = await navigator.clipboard.readText(); if (t) el.serverUrlInput.value = t.trim(); } catch(_){} });
      el.selectCheckpoint.addEventListener('change', onCloudModelChange);

      el.btnScanLocal.addEventListener('click', () => window.webkit?.messageHandlers?.scanLocalModelsHandler?.postMessage('scan'));
      el.btnImportModel.addEventListener('click', () => window.webkit?.messageHandlers?.importLocalModelHandler?.postMessage('import'));
      el.btnPickSourceImage.addEventListener('click', () => window.webkit?.messageHandlers?.nativeImagePickerHandler?.postMessage('open'));
      document.getElementById('btn-upload-canvas-img').addEventListener('click', () => window.webkit?.messageHandlers?.nativeImagePickerHandler?.postMessage('open'));

      el.sliderSteps.addEventListener('input', e => el.stepsVal.textContent = e.target.value);
      el.sliderCfg.addEventListener('input', e => el.cfgVal.textContent = parseFloat(e.target.value).toFixed(1));
      el.denoiseSlider.addEventListener('input', e => el.denoiseVal.textContent = parseFloat(e.target.value).toFixed(2));
      el.depthStrengthSlider.addEventListener('input', e => el.depthStrengthVal.textContent = parseFloat(e.target.value).toFixed(2));
      el.loraStrengthSlider.addEventListener('input', e => el.loraStrengthVal.textContent = parseFloat(e.target.value).toFixed(2));

      el.brushSizeSlider.addEventListener('input', e => {
        state.brushSize = parseInt(e.target.value);
        el.brushSizeVal.textContent = `${state.brushSize}px`;
        el.brushPreviewOverlay.classList.remove('hidden');
        const vis = Math.max(12, Math.min(140, state.brushSize * 0.6));
        el.brushPreviewCircle.style.width = `${vis}px`; el.brushPreviewCircle.style.height = `${vis}px`;
      });
      el.brushSizeSlider.addEventListener('change', () => el.brushPreviewOverlay.classList.add('hidden'));

      document.querySelectorAll('.preset-dim').forEach(b => b.addEventListener('click', () => { el.inputWidth.value = b.dataset.w; el.inputHeight.value = b.dataset.h; }));
      document.getElementById('btn-swap-dim').addEventListener('click', () => { const t = el.inputWidth.value; el.inputWidth.value = el.inputHeight.value; el.inputHeight.value = t; });
      document.querySelectorAll('.tag-chip').forEach(c => c.addEventListener('click', () => { el.positivePrompt.value += `, ${c.dataset.tag}`; }));
      document.querySelectorAll('.batch-preset').forEach(btn => btn.addEventListener('click', () => {
        document.querySelectorAll('.batch-preset').forEach(b => b.className = 'batch-preset px-2.5 py-1 rounded-lg bg-zinc-800 text-zinc-300 font-mono text-xs');
        btn.className = 'batch-preset px-2.5 py-1 rounded-lg bg-indigo-600 text-white font-mono font-bold text-xs';
        state.batchSize = parseInt(btn.dataset.batch) || 1;
      }));

      document.querySelectorAll('.mode-tab').forEach(b => b.addEventListener('click', () => {
        state.currentMode = b.dataset.mode;
        document.querySelectorAll('.mode-tab').forEach(t => t.className = 'mode-tab py-1.5 rounded-lg font-medium text-zinc-400 text-center');
        b.className = 'mode-tab py-1.5 rounded-lg font-semibold bg-indigo-600 text-white text-center shadow';
        el.sourceImagePanel.classList.toggle('hidden', state.currentMode === 't2i');
        el.depthSettingsBox.classList.toggle('hidden', state.currentMode !== 'depth');
        el.denoiseBox.classList.toggle('hidden', state.currentMode === 'depth');
        el.brushToolbar.classList.toggle('hidden', state.currentMode !== 'inpaint');
        if (state.currentMode === 'inpaint') el.brushToolbar.classList.add('flex');
      }));

      el.btnBrushMode.addEventListener('click', () => { state.brushMode = 'brush'; el.btnBrushMode.className = 'px-3 py-1 rounded-lg font-medium bg-rose-600 text-white'; el.btnEraserMode.className = 'px-3 py-1 rounded-lg font-medium text-zinc-400'; });
      el.btnEraserMode.addEventListener('click', () => { state.brushMode = 'eraser'; el.btnEraserMode.className = 'px-3 py-1 rounded-lg font-medium bg-rose-600 text-white'; el.btnBrushMode.className = 'px-3 py-1 rounded-lg font-medium text-zinc-400'; });
      el.btnClearMask.addEventListener('click', clearMask);
      el.btnSendToInpaint.addEventListener('click', () => { document.getElementById('tab-inpaint').click(); showToast('Tô vùng cần sửa rồi bấm Tạo Ảnh.', 'info'); });
      el.btnDownloadImage.addEventListener('click', () => window.webkit?.messageHandlers?.saveImageHandler?.postMessage(el.baseCanvas.toDataURL('image/png')));
      document.getElementById('btn-fullscreen').addEventListener('click', () => { if (state.baseImageObj) { document.getElementById('fullscreen-modal-img').src = el.baseCanvas.toDataURL('image/png'); document.getElementById('fullscreen-modal').classList.remove('hidden'); } });
      document.getElementById('fullscreen-modal').addEventListener('click', () => document.getElementById('fullscreen-modal').classList.add('hidden'));
      document.getElementById('btn-enhance-prompt').addEventListener('click', () => { el.positivePrompt.value += ', masterpiece, best quality, photorealistic 8k raw photo, intricate details'; showToast('✨ Đã phóng tác Prompt!', 'success'); });
      document.getElementById('btn-clear-positive').addEventListener('click', () => el.positivePrompt.value = '');
      document.getElementById('btn-clear-negative').addEventListener('click', () => el.negativePrompt.value = '');
      el.btnGenerate.addEventListener('click', handleGenerateClick);
      el.btnInterrupt.addEventListener('click', async () => {
        if (state.engine === 'local') window.webkit?.messageHandlers?.cancelLocalHandler?.postMessage('cancel');
        else try { await fetch(`${sanitizeUrl(state.serverUrl)}/interrupt`, { method: 'POST' }); } catch(_) {}
        stopGenUI();
      });

      window.addEventListener('DOMContentLoaded', () => {
        el.serverUrlInput.value = state.serverUrl;
        setTimeout(() => window.webkit?.messageHandlers?.scanLocalModelsHandler?.postMessage('scan'), 300);
      });
    </script>
  </body>
</html>
"""#
