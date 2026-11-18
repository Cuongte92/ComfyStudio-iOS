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
                            modelsList.append(["name": "\(url.lastPathComponent) (\(sizeGB))", "path": url.path])
                        }
                    }
                }
            }

            let lorasDir = documentsURL.appendingPathComponent("LoRAs")
            if let loraItems = try? fm.contentsOfDirectory(at: lorasDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                for url in loraItems where allowedExts.contains(url.pathExtension.lowercased()) {
                    lorasList.append(["name": url.lastPathComponent, "path": url.path])
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
    <title>ComfyStudio Tri-Engine</title>
    <script src="https://cdn.tailwindcss.com"></script>
    <script>
      tailwind.config = {
        darkMode: 'class',
        theme: { extend: { colors: { zinc: { 850: '#1c1c21', 925: '#121216', 950: '#09090b' } } } }
      }
    </script>
    <style>
      html, body { overscroll-behavior-y: none; -webkit-text-size-adjust: 100%; background-color: #09090b; }
      .glass-panel { background: rgba(20, 20, 26, 0.76); backdrop-filter: blur(22px) saturate(180%); -webkit-backdrop-filter: blur(22px) saturate(180%); border: 1px solid rgba(255, 255, 255, 0.09); }
      .checkerboard-pattern { background-color: #0c0c10; background-image: linear-gradient(45deg, #15151b 25%, transparent 25%), linear-gradient(-45deg, #15151b 25%, transparent 25%), linear-gradient(45deg, transparent 75%, #15151b 75%), linear-gradient(-45deg, transparent 75%, #15151b 75%); background-size: 20px 20px; background-position: 0 0, 0 10px, 10px -10px, -10px 0px; }
      #canvas-wrapper, #mask-canvas, #base-canvas { touch-action: none; -webkit-user-select: none; user-select: none; }
      input[type="text"], input[type="number"], textarea, select { font-size: 16px !important; }
    </style>
  </head>
  <body class="bg-zinc-950 text-zinc-100 min-h-screen flex flex-col font-sans antialiased pb-[env(safe-area-inset-bottom)]">
    <div id="toast-container" class="fixed top-3 right-3 left-3 sm:left-auto sm:w-96 z-50 flex flex-col gap-2 pointer-events-none"></div>

    <header class="border-b border-white/10 bg-zinc-950/85 backdrop-blur-xl sticky top-0 z-30 px-3.5 py-2.5 pt-[max(0.65rem,env(safe-area-inset-top))]">
      <div class="max-w-[1720px] mx-auto flex flex-col sm:flex-row sm:items-center justify-between gap-2.5">
        <div class="flex items-center justify-between">
          <div class="flex items-center gap-2.5">
            <div class="h-8 w-8 rounded-xl bg-gradient-to-tr from-indigo-600 to-violet-500 flex items-center justify-center font-bold text-white shadow-lg">⚡</div>
            <div>
              <div class="flex items-center gap-1.5">
                <span class="font-bold tracking-tight text-white text-sm">ComfyStudio</span>
                <span id="header-engine-badge" class="text-[9px] font-mono uppercase bg-emerald-950 text-emerald-300 px-1.5 py-0.5 rounded border border-emerald-700/60">A19 Pro Metal</span>
              </div>
              <div class="text-[10px] text-zinc-400">Local · ComfyUI · DrawThings</div>
            </div>
          </div>
          <div class="flex items-center bg-zinc-900 p-1 rounded-xl border border-white/10 text-xs">
            <button id="engine-local-btn" type="button" class="px-2 py-1 rounded-lg font-semibold bg-emerald-600 text-white shadow">📱 Local</button>
            <button id="engine-cloud-btn" type="button" class="px-2 py-1 rounded-lg font-medium text-zinc-400">☁️ Comfy</button>
            <button id="engine-dt-btn" type="button" class="px-2 py-1 rounded-lg font-medium text-zinc-400">🔌 DT Server</button>
          </div>
        </div>

        <div id="local-header-bar" class="flex items-center justify-between gap-2 bg-zinc-900/80 px-3 py-1.5 rounded-xl border border-white/10 text-xs">
          <span class="text-zinc-300 truncate">Tệp: <strong class="text-emerald-400 font-mono">ComfyStudio/Models</strong></span>
          <div class="flex items-center gap-1.5 shrink-0">
            <button id="btn-import-model" type="button" class="px-2.5 py-1 rounded-lg bg-zinc-800 text-amber-300 border border-amber-500/30 text-[11px] font-medium">+ Nạp File</button>
            <button id="btn-scan-local" type="button" class="px-2.5 py-1 rounded-lg bg-emerald-600 text-white text-[11px] font-semibold">🔄 Quét</button>
          </div>
        </div>

        <div id="cloud-header-bar" class="hidden flex items-center gap-1.5 w-full sm:max-w-xl">
          <div class="relative flex-1">
            <input id="server-url-input" type="text" class="w-full bg-zinc-900/90 border border-zinc-700/80 rounded-xl pl-3 pr-20 py-1.5 text-zinc-200 placeholder-zinc-500 font-mono" placeholder="https://xxxx.trycloudflare.com" />
            <div class="absolute inset-y-0 right-1.5 flex items-center gap-1.5">
              <button id="btn-paste-url" type="button" class="px-2 py-1 text-[10px] bg-zinc-800 text-zinc-200 rounded-lg border border-zinc-700">📋 Dán</button>
              <span id="connection-status-dot" class="w-2.5 h-2.5 rounded-full bg-zinc-500"></span>
            </div>
          </div>
          <button id="btn-connect" type="button" class="bg-indigo-600 text-white text-xs font-semibold px-3.5 py-2 rounded-xl shadow-md whitespace-nowrap">Kết nối</button>
        </div>

        <div id="dt-header-bar" class="hidden flex items-center gap-1.5 w-full sm:max-w-xl">
          <div class="relative flex-1">
            <input id="dt-url-input" type="text" class="w-full bg-zinc-900/90 border border-amber-600/50 rounded-xl pl-3 pr-20 py-1.5 text-zinc-200 placeholder-zinc-500 font-mono" placeholder="https://xxxx.trycloudflare.com (DT Bridge)" />
            <div class="absolute inset-y-0 right-1.5 flex items-center gap-1.5">
              <button id="btn-paste-dt" type="button" class="px-2 py-1 text-[10px] bg-zinc-800 text-zinc-200 rounded-lg border border-zinc-700">📋 Dán</button>
              <span id="dt-status-dot" class="w-2.5 h-2.5 rounded-full bg-zinc-500"></span>
            </div>
          </div>
          <button id="btn-connect-dt" type="button" class="bg-amber-600 text-white text-xs font-semibold px-3.5 py-2 rounded-xl shadow-md whitespace-nowrap">Nạp DT</button>
        </div>
      </div>
    </header>

    <main class="flex-1 max-w-[1720px] w-full mx-auto p-3 sm:p-4 grid grid-cols-1 lg:grid-cols-12 gap-4">
      <section class="lg:col-span-5 flex flex-col gap-3.5">
        <div class="glass-panel rounded-2xl p-1.5">
          <div class="grid grid-cols-4 gap-1 bg-zinc-950/80 p-1 rounded-xl border border-white/5 text-xs">
            <button id="tab-t2i" data-mode="t2i" type="button" class="mode-tab py-1.5 rounded-lg font-semibold bg-indigo-600 text-white text-center shadow">T2I</button>
            <button id="tab-i2i" data-mode="i2i" type="button" class="mode-tab py-1.5 rounded-lg font-medium text-zinc-400 text-center">I2I</button>
            <button id="tab-depth" data-mode="depth" type="button" class="mode-tab py-1.5 rounded-lg font-medium text-zinc-400 text-center">Depth</button>
            <button id="tab-inpaint" data-mode="inpaint" type="button" class="mode-tab py-1.5 rounded-lg font-medium text-zinc-400 text-center">Inpaint</button>
          </div>
        </div>

        <div id="source-image-panel" class="hidden glass-panel rounded-2xl p-3.5 space-y-2.5 border-indigo-500/30">
          <div class="flex items-center justify-between">
            <span class="text-xs font-semibold text-indigo-300">Ảnh Nguồn</span>
            <button id="btn-pick-source-image" type="button" class="px-3 py-1 rounded-lg bg-indigo-600 text-white text-xs font-medium">🖼️ Chọn Ảnh iPhone</button>
          </div>
          <div id="denoise-box" class="pt-1 border-t border-white/10">
            <div class="flex justify-between mb-1 text-xs"><span>Denoise:</span><span id="denoise-val" class="text-indigo-400 font-mono font-bold">0.75</span></div>
            <input id="denoise-slider" type="range" min="0.1" max="1.0" step="0.05" value="0.75" class="w-full accent-indigo-500 h-1.5">
          </div>
          <div id="depth-settings-box" class="hidden pt-1 border-t border-white/10 space-y-2">
            <select id="select-controlnet" class="w-full bg-zinc-950 border border-zinc-700 rounded-xl px-2.5 py-1.5 text-zinc-200 font-mono"><option value="">(ControlNet Depth)</option></select>
            <input id="depth-strength-slider" type="range" min="0.1" max="1.5" step="0.05" value="0.80" class="w-full accent-cyan-500 h-1.5">
          </div>
        </div>

        <div class="glass-panel rounded-2xl p-3.5 space-y-3">
          <div class="flex items-center justify-between">
            <h2 class="text-xs font-semibold uppercase tracking-wider text-zinc-400">Model & LoRA</h2>
            <span id="arch-badge" class="text-[10px] font-mono px-2 py-0.5 rounded bg-emerald-950 text-emerald-300 border border-emerald-700/50">SDXL Metal</span>
          </div>
          <select id="select-checkpoint" class="w-full bg-zinc-950/90 border border-zinc-700 rounded-xl px-2.5 py-2 text-zinc-200 font-mono">
            <option value="">(Đang quét model trên iPhone...)</option>
          </select>
          <div class="bg-zinc-950/70 p-3 rounded-xl border border-white/5 space-y-2 text-xs">
            <div class="flex items-center justify-between">
              <label class="flex items-center gap-2 font-semibold text-zinc-200"><input id="check-enable-lora" type="checkbox" class="w-4 h-4 rounded"><span>Kích hoạt LoRA</span></label>
              <span id="lora-strength-val" class="text-indigo-400 font-mono font-bold">0.85</span>
            </div>
            <select id="select-lora" class="w-full bg-zinc-900 border border-zinc-700 rounded-xl px-2.5 py-1.5 text-zinc-200 font-mono"><option value="None">None</option></select>
            <input id="lora-strength-slider" type="range" min="0.1" max="1.5" step="0.05" value="0.85" class="w-full accent-indigo-500 h-1.5">
          </div>
        </div>

        <div class="glass-panel rounded-2xl p-3.5 space-y-2.5">
          <label class="font-semibold text-emerald-400 text-xs block">Positive Prompt</label>
          <textarea id="positive-prompt" rows="3" class="w-full bg-zinc-950/90 border border-zinc-700 rounded-xl p-2.5 text-zinc-100">masterpiece, best quality, ultra-detailed cinematic portrait of a handsome athletic man, natural skin texture, volumetric studio lighting, 8k raw photo</textarea>
          <div id="negative-prompt-container">
            <label class="font-medium text-rose-400 text-xs block mb-1">Negative Prompt</label>
            <textarea id="negative-prompt" rows="2" class="w-full bg-zinc-950/90 border border-zinc-700 rounded-xl p-2 text-zinc-100">blurry, low quality, worst quality, distorted anatomy, bad hands, mutated fingers, extra limbs, watermark</textarea>
          </div>
        </div>

        <div class="glass-panel rounded-2xl p-3.5 space-y-3">
          <div class="flex items-center justify-between text-xs">
            <h2 class="font-semibold uppercase tracking-wider text-zinc-400">Thông Số</h2>
            <div class="flex gap-1 text-[11px]">
              <button type="button" class="preset-dim px-2 py-0.5 rounded-lg bg-zinc-800" data-w="1024" data-h="1024">1024²</button>
              <button type="button" class="preset-dim px-2 py-0.5 rounded-lg bg-zinc-800" data-w="832" data-h="1216">Dọc</button>
              <button type="button" class="preset-dim px-2 py-0.5 rounded-lg bg-zinc-800" data-w="1216" data-h="832">Ngang</button>
            </div>
          </div>
          <div class="flex items-center gap-2">
            <input id="input-width" type="number" step="64" value="1024" class="w-full bg-zinc-950/90 border border-zinc-700 rounded-xl p-1.5 text-center font-mono">
            <button id="btn-swap-dim" type="button" class="px-3 py-2 bg-zinc-800 rounded-xl">⇄</button>
            <input id="input-height" type="number" step="64" value="1024" class="w-full bg-zinc-950/90 border border-zinc-700 rounded-xl p-1.5 text-center font-mono">
          </div>
          <div class="grid grid-cols-2 gap-3 text-xs">
            <div>
              <div class="flex justify-between mb-1"><span>Steps</span><span id="steps-val" class="font-mono text-indigo-400 font-bold">8</span></div>
              <input id="slider-steps" type="range" min="1" max="45" step="1" value="8" class="w-full accent-indigo-500">
            </div>
            <div>
              <div class="flex justify-between mb-1"><span>CFG</span><span id="cfg-val" class="font-mono text-indigo-400 font-bold">2.0</span></div>
              <input id="slider-cfg" type="range" min="1.0" max="15.0" step="0.5" value="2.0" class="w-full accent-indigo-500">
            </div>
          </div>
          <div class="text-xs flex items-center justify-between">
            <label class="flex items-center gap-2"><input id="check-random-seed" type="checkbox" checked class="w-4 h-4 rounded"><span>Random Seed</span></label>
            <input id="input-seed" type="number" class="w-36 bg-zinc-950/90 border border-zinc-700 rounded-xl p-1.5 text-center font-mono" value="428591726">
          </div>
        </div>

        <div class="flex items-center gap-2">
          <button id="btn-generate" type="button" class="flex-1 flex items-center justify-center gap-2 bg-gradient-to-r from-emerald-600 to-teal-600 text-white font-bold py-3.5 px-4 rounded-2xl shadow-lg text-sm">
            <span id="generate-btn-text">⚡ Tạo Ảnh Offline (A19 Pro)</span>
          </button>
          <button id="btn-interrupt" type="button" disabled class="px-4 py-3.5 rounded-2xl bg-zinc-850 text-zinc-300 border border-zinc-700 disabled:opacity-30 font-bold">■</button>
        </div>
      </section>

      <section class="lg:col-span-7 flex flex-col gap-3.5">
        <div class="glass-panel rounded-2xl p-3">
          <div class="flex justify-between text-xs mb-1.5">
            <span id="step-label" class="font-medium text-zinc-300">Sẵn sàng</span>
            <span id="progress-percentage" class="text-emerald-400 font-mono font-bold">0%</span>
          </div>
          <div class="w-full bg-zinc-950 rounded-full h-2 overflow-hidden">
            <div id="progress-fill" class="bg-gradient-to-r from-emerald-500 to-teal-400 h-full rounded-full transition-all" style="width: 0%"></div>
          </div>
        </div>

        <div class="glass-panel rounded-2xl overflow-hidden flex flex-col flex-1 min-h-[440px]">
          <div class="px-3.5 py-2.5 border-b border-white/10 bg-zinc-900/60 flex justify-between text-xs">
            <span class="font-semibold">Studio Canvas</span>
            <button id="btn-upload-canvas-img" type="button" class="text-indigo-400 font-medium">Nạp ảnh</button>
          </div>
          <div id="brush-toolbar" class="hidden flex-wrap items-center justify-between px-3 py-2 bg-zinc-950/90 border-b border-white/10 text-xs gap-2">
            <div class="flex bg-zinc-900 p-0.5 rounded-xl">
              <button id="btn-brush-mode" type="button" class="px-3 py-1 rounded-lg bg-rose-600 text-white">🖌️ Tô</button>
              <button id="btn-eraser-mode" type="button" class="px-3 py-1 rounded-lg text-zinc-400">🧹 Tẩy</button>
            </div>
            <input id="brush-size-slider" type="range" min="8" max="150" value="35" class="w-24 accent-rose-500">
            <button id="btn-clear-mask" type="button" class="px-2.5 py-1 rounded-xl bg-zinc-900 text-zinc-300 border border-zinc-700">Xóa Mask</button>
          </div>
          <div class="relative flex-1 flex items-center justify-center p-3 checkerboard-pattern min-h-[340px]">
            <div id="canvas-empty-state" class="text-center p-6 text-zinc-500 text-xs">Chưa có ảnh trên Canvas</div>
            <div id="canvas-generating-overlay" class="absolute inset-0 bg-zinc-950/80 backdrop-blur-sm flex flex-col items-center justify-center gap-2 z-20 hidden">
              <div class="w-10 h-10 rounded-full border-4 border-indigo-500/20 border-t-indigo-500 animate-spin"></div>
              <p id="overlay-status-text" class="text-xs font-semibold text-white">Đang sinh ảnh...</p>
            </div>
            <div id="canvas-wrapper" class="relative hidden max-w-full max-h-[480px] rounded-xl overflow-hidden border border-white/15">
              <canvas id="base-canvas" class="block max-w-full max-h-[480px]"></canvas>
              <canvas id="mask-canvas" class="absolute inset-0 w-full h-full cursor-crosshair z-10"></canvas>
            </div>
          </div>
          <div class="p-3 bg-zinc-900/80 border-t border-white/10 flex justify-between text-xs">
            <div class="flex gap-2">
              <button id="btn-download-image" type="button" disabled class="bg-indigo-600 text-white disabled:opacity-40 px-3 py-1.5 rounded-xl">💾 Lưu</button>
              <button id="btn-send-to-inpaint" type="button" disabled class="bg-rose-950/80 text-rose-200 disabled:opacity-40 px-3 py-1.5 rounded-xl">🖌️ Inpaint</button>
            </div>
            <span id="meta-info" class="text-[11px] text-zinc-400 font-mono">Seed: --</span>
          </div>
        </div>

        <div class="glass-panel rounded-2xl p-3">
          <div class="text-xs font-semibold text-zinc-300 mb-2">Lịch sử ảnh</div>
          <div id="gallery-tray" class="flex items-center gap-2 overflow-x-auto min-h-[56px]"></div>
        </div>
      </section>
    </main>

    <script>
      const state = {
        engine: 'local',
        serverUrl: localStorage.getItem('comfystudio_tunnel_url') || '',
        dtUrl: localStorage.getItem('comfystudio_dt_bridge_url') || '',
        clientId: 'client_' + Math.random().toString(36).substring(2, 10),
        ws: null, currentMode: 't2i', isGenerating: false,
        brushMode: 'brush', brushSize: 35, isPainting: false, lastPoint: null, hasMaskDrawn: false, baseImageObj: null,
        localModels: [], localLoras: [],
        cloudModels: { checkpoints: [], unets: [], clips: [], vaes: [], loras: [], controlnets: [] },
        dtModels: [], dtLoras: []
      };

      const el = {
        engineLocalBtn: document.getElementById('engine-local-btn'),
        engineCloudBtn: document.getElementById('engine-cloud-btn'),
        engineDtBtn: document.getElementById('engine-dt-btn'),
        headerEngineBadge: document.getElementById('header-engine-badge'),
        localHeaderBar: document.getElementById('local-header-bar'),
        cloudHeaderBar: document.getElementById('cloud-header-bar'),
        dtHeaderBar: document.getElementById('dt-header-bar'),
        serverUrlInput: document.getElementById('server-url-input'),
        dtUrlInput: document.getElementById('dt-url-input'),
        selectCheckpoint: document.getElementById('select-checkpoint'),
        archBadge: document.getElementById('arch-badge'),
        selectLora: document.getElementById('select-lora'),
        checkEnableLora: document.getElementById('check-enable-lora'),
        loraStrengthSlider: document.getElementById('lora-strength-slider'),
        loraStrengthVal: document.getElementById('lora-strength-val'),
        sourceImagePanel: document.getElementById('source-image-panel'),
        denoiseSlider: document.getElementById('denoise-slider'),
        denoiseVal: document.getElementById('denoise-val'),
        positivePrompt: document.getElementById('positive-prompt'),
        negativePrompt: document.getElementById('negative-prompt'),
        inputWidth: document.getElementById('input-width'),
        inputHeight: document.getElementById('input-height'),
        sliderSteps: document.getElementById('slider-steps'),
        stepsVal: document.getElementById('steps-val'),
        sliderCfg: document.getElementById('slider-cfg'),
        cfgVal: document.getElementById('cfg-val'),
        inputSeed: document.getElementById('input-seed'),
        checkRandomSeed: document.getElementById('check-random-seed'),
        btnGenerate: document.getElementById('btn-generate'),
        generateBtnText: document.getElementById('generate-btn-text'),
        btnInterrupt: document.getElementById('btn-interrupt'),
        stepLabel: document.getElementById('step-label'),
        progressPercentage: document.getElementById('progress-percentage'),
        progressFill: document.getElementById('progress-fill'),
        canvasEmptyState: document.getElementById('canvas-empty-state'),
        canvasGeneratingOverlay: document.getElementById('canvas-generating-overlay'),
        overlayStatusText: document.getElementById('overlay-status-text'),
        canvasWrapper: document.getElementById('canvas-wrapper'),
        baseCanvas: document.getElementById('base-canvas'),
        maskCanvas: document.getElementById('mask-canvas'),
        brushToolbar: document.getElementById('brush-toolbar'),
        btnDownloadImage: document.getElementById('btn-download-image'),
        btnSendToInpaint: document.getElementById('btn-send-to-inpaint'),
        galleryTray: document.getElementById('gallery-tray'),
        toastContainer: document.getElementById('toast-container')
      };

      function showToast(msg, type = 'info') {
        const t = document.createElement('div');
        t.className = `p-3 rounded-2xl border text-xs shadow-2xl backdrop-blur-xl ${type === 'error' ? 'bg-rose-950/90 border-rose-700 text-rose-100' : 'bg-emerald-950/90 border-emerald-700 text-emerald-100'}`;
        t.textContent = msg;
        el.toastContainer.appendChild(t);
        setTimeout(() => t.remove(), 3500);
      }

      function sanitizeUrl(raw) {
        if (!raw) return '';
        let u = raw.trim().replace(/\/+$/, '');
        if (!/^https?:\/\//i.test(u)) u = 'https://' + u;
        return u;
      }

      function switchEngine(target) {
        state.engine = target;
        const off = 'px-2 py-1 rounded-lg font-medium text-zinc-400';
        el.engineLocalBtn.className = off; el.engineCloudBtn.className = off; el.engineDtBtn.className = off;
        el.localHeaderBar.classList.add('hidden'); el.cloudHeaderBar.classList.add('hidden'); el.dtHeaderBar.classList.add('hidden');

        if (target === 'local') {
          el.engineLocalBtn.className = 'px-2 py-1 rounded-lg font-semibold bg-emerald-600 text-white shadow';
          el.headerEngineBadge.textContent = 'A19 Pro Metal';
          el.localHeaderBar.classList.remove('hidden');
          el.btnGenerate.className = 'flex-1 flex items-center justify-center gap-2 bg-gradient-to-r from-emerald-600 to-teal-600 text-white font-bold py-3.5 px-4 rounded-2xl text-sm';
          el.generateBtnText.textContent = '⚡ Tạo Ảnh Offline (A19 Pro)';
          populateDropdowns(state.localModels.map(m => ({label: m.name, val: m.path})), state.localLoras.map(l => ({label: l.name, val: l.path})));
        } else if (target === 'cloud') {
          el.engineCloudBtn.className = 'px-2 py-1 rounded-lg font-semibold bg-indigo-600 text-white shadow';
          el.headerEngineBadge.textContent = 'ComfyUI Cloud';
          el.cloudHeaderBar.classList.remove('hidden');
          el.btnGenerate.className = 'flex-1 flex items-center justify-center gap-2 bg-gradient-to-r from-indigo-600 to-violet-600 text-white font-bold py-3.5 px-4 rounded-2xl text-sm';
          el.generateBtnText.textContent = '☁️ Tạo Ảnh ComfyUI';
          const all = [...state.cloudModels.checkpoints, ...state.cloudModels.unets];
          populateDropdowns(all.map(m => ({label: m, val: m})), state.cloudModels.loras.map(l => ({label: l, val: l})));
        } else {
          el.engineDtBtn.className = 'px-2 py-1 rounded-lg font-semibold bg-amber-600 text-white shadow';
          el.headerEngineBadge.textContent = 'DrawThings Bridge';
          el.dtHeaderBar.classList.remove('hidden');
          el.btnGenerate.className = 'flex-1 flex items-center justify-center gap-2 bg-gradient-to-r from-amber-600 to-orange-600 text-white font-bold py-3.5 px-4 rounded-2xl text-sm';
          el.generateBtnText.textContent = '🔌 Tạo Ảnh Draw Things';
          const list = state.dtModels.length ? state.dtModels : ['qwen_image_2.1_q8p.ckpt'];
          populateDropdowns(list.map(m => ({label: m, val: m})), state.dtLoras.map(l => ({label: l, val: l})));
        }
      }

      function populateDropdowns(models, loras) {
        el.selectCheckpoint.innerHTML = models.length ? '' : '<option value="">(Trống)</option>';
        models.forEach(m => { const o = document.createElement('option'); o.value = m.val; o.textContent = m.label; el.selectCheckpoint.appendChild(o); });
        el.selectLora.innerHTML = '<option value="None">None</option>';
        loras.forEach(l => { const o = document.createElement('option'); o.value = l.val; o.textContent = l.label; el.selectLora.appendChild(o); });
      }

      // Draw Things HTTP Bridge
      async function connectDTBridge() {
        const url = sanitizeUrl(el.dtUrlInput.value);
        if (!url) return showToast('Nhập link Cloudflare Tunnel của DT Bridge!', 'error');
        state.dtUrl = url; localStorage.setItem('comfystudio_dt_bridge_url', url);
        try {
          const res = await fetch(`${url}/dt/echo`);
          const data = await res.json();
          if (!res.ok || !data.ok) throw new Error(data.detail || 'Lỗi Echo');
          state.dtModels = data.models || [];
          state.dtLoras = data.loras || [];
          document.getElementById('dt-status-dot').className = 'w-2.5 h-2.5 rounded-full bg-emerald-500';
          if (state.engine === 'dt') switchEngine('dt');
          showToast(`Đã kết nối Draw Things (${state.dtModels.length} model)!`, 'success');
        } catch (e) { showToast(e.message, 'error'); }
      }

      async function executeDTGeneration(seed) {
        const url = sanitizeUrl(state.dtUrl || el.dtUrlInput.value);
        if (!url) throw new Error('Chưa nhập link DT Bridge!');
        el.canvasGeneratingOverlay.classList.remove('hidden');
        el.overlayStatusText.textContent = 'Đang chạy Draw Things trên Colab GPU...';
        const res = await fetch(`${url}/dt/generate`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            model: el.selectCheckpoint.value,
            prompt: el.positivePrompt.value.trim(),
            negative_prompt: el.negativePrompt.value.trim(),
            width: parseInt(el.inputWidth.value) || 1024,
            height: parseInt(el.inputHeight.value) || 1024,
            steps: parseInt(el.sliderSteps.value) || 12,
            cfg: parseFloat(el.sliderCfg.value) || 3.5,
            seed,
            lora: el.checkEnableLora.checked ? el.selectLora.value : 'None',
            lora_strength: parseFloat(el.loraStrengthSlider.value) || 0.85,
            init_image: (state.currentMode !== 't2i') ? el.baseCanvas.toDataURL('image/png') : null,
            mask_image: (state.currentMode === 'inpaint') ? getMaskExportBase64() : null,
            denoise: parseFloat(el.denoiseSlider.value) || 0.75
          })
        });
        const data = await res.json();
        if (!res.ok) throw new Error(data.detail || 'Lỗi sinh ảnh DT');
        window.onLocalGenComplete(data.image);
      }

      // Local Callbacks
      window.receiveLocalModelsList = (d) => { state.localModels = d.models || []; state.localLoras = d.loras || []; if (state.engine === 'local') switchEngine('local'); };
      window.onLocalGenProgress = (s, t) => { const p = Math.round((s/Math.max(1,t))*100); el.progressFill.style.width = `${p}%`; el.progressPercentage.textContent = `${p}%`; el.stepLabel.textContent = `Step ${s}/${t}`; };
      window.onLocalGenComplete = (b64) => {
        el.canvasGeneratingOverlay.classList.add('hidden');
        el.progressFill.style.width = '100%'; el.progressPercentage.textContent = '100%'; el.stepLabel.textContent = 'Hoàn tất!';
        const im = new Image(); im.onload = () => syncCanvasWithImage(im); im.src = b64;
        const d = document.createElement('div'); d.className = 'shrink-0 w-14 h-14 rounded-xl overflow-hidden border border-white/15';
        d.innerHTML = `<img src="${b64}" class="w-full h-full object-cover">`; d.onclick = () => { const i = new Image(); i.onload = () => syncCanvasWithImage(i); i.src = b64; };
        el.galleryTray.prepend(d);
      };
      window.onLocalGenError = (err) => { el.canvasGeneratingOverlay.classList.add('hidden'); showToast(err, 'error'); };
      window.receiveNativeSourceImage = (b64) => { const im = new Image(); im.onload = () => syncCanvasWithImage(im); im.src = b64; };

      function syncCanvasWithImage(img) {
        state.baseImageObj = img;
        el.baseCanvas.width = img.naturalWidth || 1024; el.baseCanvas.height = img.naturalHeight || 1024;
        el.maskCanvas.width = el.baseCanvas.width; el.maskCanvas.height = el.baseCanvas.height;
        el.baseCanvas.getContext('2d').drawImage(img, 0, 0);
        el.maskCanvas.getContext('2d').clearRect(0, 0, el.maskCanvas.width, el.maskCanvas.height);
        state.hasMaskDrawn = false;
        el.canvasEmptyState.classList.add('hidden'); el.canvasWrapper.classList.remove('hidden');
        el.btnDownloadImage.disabled = false; el.btnSendToInpaint.disabled = false;
      }

      function getMaskExportBase64() {
        const c = document.createElement('canvas'); c.width = el.baseCanvas.width; c.height = el.baseCanvas.height;
        const ctx = c.getContext('2d'); ctx.fillStyle = '#000'; ctx.fillRect(0, 0, c.width, c.height);
        const m = el.maskCanvas.getContext('2d').getImageData(0, 0, c.width, c.height);
        const o = ctx.getImageData(0, 0, c.width, c.height);
        for (let i = 0; i < m.data.length; i += 4) if (m.data[i+3] > 10) { o.data[i]=o.data[i+1]=o.data[i+2]=o.data[i+3]=255; }
        ctx.putImageData(o, 0, 0); return c.toDataURL('image/png');
      }

      // Events
      el.engineLocalBtn.onclick = () => switchEngine('local');
      el.engineCloudBtn.onclick = () => switchEngine('cloud');
      el.engineDtBtn.onclick = () => switchEngine('dt');
      document.getElementById('btn-connect-dt').onclick = connectDTBridge;
      document.getElementById('btn-paste-dt').onclick = async () => { try { el.dtUrlInput.value = (await navigator.clipboard.readText()).trim(); } catch(_){} };
      document.getElementById('btn-scan-local').onclick = () => window.webkit?.messageHandlers?.scanLocalModelsHandler?.postMessage('scan');
      document.getElementById('btn-import-model').onclick = () => window.webkit?.messageHandlers?.importLocalModelHandler?.postMessage('import');
      document.getElementById('btn-pick-source-image').onclick = () => window.webkit?.messageHandlers?.nativeImagePickerHandler?.postMessage('open');
      document.getElementById('btn-upload-canvas-img').onclick = () => window.webkit?.messageHandlers?.nativeImagePickerHandler?.postMessage('open');
      el.sliderSteps.oninput = e => el.stepsVal.textContent = e.target.value;
      el.sliderCfg.oninput = e => el.cfgVal.textContent = parseFloat(e.target.value).toFixed(1);
      el.denoiseSlider.oninput = e => el.denoiseVal.textContent = parseFloat(e.target.value).toFixed(2);
      el.loraStrengthSlider.oninput = e => el.loraStrengthVal.textContent = parseFloat(e.target.value).toFixed(2);
      document.querySelectorAll('.preset-dim').forEach(b => b.onclick = () => { el.inputWidth.value = b.dataset.w; el.inputHeight.value = b.dataset.h; });
      document.getElementById('btn-swap-dim').onclick = () => { [el.inputWidth.value, el.inputHeight.value] = [el.inputHeight.value, el.inputWidth.value]; };
      document.querySelectorAll('.mode-tab').forEach(b => b.onclick = () => {
        state.currentMode = b.dataset.mode;
        document.querySelectorAll('.mode-tab').forEach(t => t.className = 'mode-tab py-1.5 rounded-lg font-medium text-zinc-400 text-center');
        b.className = 'mode-tab py-1.5 rounded-lg font-semibold bg-indigo-600 text-white text-center shadow';
        el.sourceImagePanel.classList.toggle('hidden', state.currentMode === 't2i');
        el.brushToolbar.classList.toggle('hidden', state.currentMode !== 'inpaint');
        if (state.currentMode === 'inpaint') el.brushToolbar.classList.add('flex');
      });
      el.btnDownloadImage.onclick = () => window.webkit?.messageHandlers?.saveImageHandler?.postMessage(el.baseCanvas.toDataURL('image/png'));
      el.btnSendToInpaint.onclick = () => document.getElementById('tab-inpaint').click();

      el.btnGenerate.onclick = async () => {
        let seed = parseInt(el.inputSeed.value);
        if (el.checkRandomSeed.checked || isNaN(seed)) { seed = Math.floor(Math.random() * 1000000000); el.inputSeed.value = seed; }
        document.getElementById('meta-info').textContent = `Seed: ${seed}`;
        if (state.engine === 'dt') {
          try { await executeDTGeneration(seed); } catch (e) { el.canvasGeneratingOverlay.classList.add('hidden'); showToast(e.message, 'error'); }
        } else if (state.engine === 'local') {
          if (!el.selectCheckpoint.value) return showToast('Chưa chọn model Local!', 'error');
          el.canvasGeneratingOverlay.classList.remove('hidden');
          window.webkit?.messageHandlers?.generateLocalHandler?.postMessage({
            modelPath: el.selectCheckpoint.value, loraPath: el.checkEnableLora.checked ? el.selectLora.value : 'None',
            loraStrength: parseFloat(el.loraStrengthSlider.value) || 0.85, prompt: el.positivePrompt.value.trim(),
            negativePrompt: el.negativePrompt.value.trim(), width: parseInt(el.inputWidth.value) || 1024,
            height: parseInt(el.inputHeight.value) || 1024, steps: parseInt(el.sliderSteps.value) || 8,
            cfg: parseFloat(el.sliderCfg.value) || 2.0, seed,
            initImage: (state.currentMode !== 't2i') ? el.baseCanvas.toDataURL('image/png') : null,
            maskImage: (state.currentMode === 'inpaint') ? getMaskExportBase64() : null,
            denoise: parseFloat(el.denoiseSlider.value) || 0.75
          });
        }
      };

      window.addEventListener('DOMContentLoaded', () => {
        el.dtUrlInput.value = state.dtUrl;
        setTimeout(() => window.webkit?.messageHandlers?.scanLocalModelsHandler?.postMessage('scan'), 300);
      });
    </script>
  </body>
</html>
"""#
