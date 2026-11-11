# Eject

macOS 選單列小工具：列出所有外接磁碟，即時顯示哪些程式正在占用，並能一鍵結束占用程式後安全退出。

## 功能

- **選單列面板**：每顆外接碟一張卡片，顯示容量、格式、連接方式，以及綠色（可安全退出）／橘色（使用中）狀態燈。
- **找出占用者**：用 `libproc` 列舉每個程序開啟的檔案、工作目錄與執行檔，以裝置編號比對，不會誤判名稱相近的宗卷。
- **聰明分組**：VS Code、Chrome 這類 App 的 helper 程序歸到同一個 App；命令列程序會標出在哪個 App（Terminal、VS Code…）裡執行。
- **辨識 dev server**：Vite、Next.js、Nuxt、Astro、Webpack、Jest、tsc --watch、Django、Uvicorn、Claude Code 等，並從 `package.json` 讀出專案名稱。
- **git 保護**：偵測到 `.git/index.lock` 時先警告，避免 git 操作途中拔碟。
- **退出失敗視窗**：被擋住時跳出浮動視窗，可逐一或一次結束占用者後自動退出；看不到占用者（例如 Spotlight 等 root 程序）時提供強制退出。
- **結束程序的方式**：GUI App 走正常「結束」（會詢問是否儲存），沒回應才提供強制結束；命令列程序送 `SIGTERM`、3 秒後 `SIGKILL`；互動式 shell 送 `SIGHUP`（等同關閉終端機分頁）。
- 整顆實體裝置一起退出（APFS 合成磁碟會追到實體碟），登入時自動啟動。

## 編譯與安裝

需要 Xcode（Swift 6）與 macOS 14 以上。

```bash
./scripts/build-app.sh
```

會編譯 release 版、產生圖示、組成 `Eject.app`、ad-hoc 簽署，並安裝到 `~/Applications` 後啟動。
**不要從外接碟直接執行 App**，否則 App 本身就會擋住那顆碟的退出。

只想打包不安裝：`./scripts/build-app.sh --no-install`（產物在 `build/Eject.app`）。

## 除錯指令

```bash
swift build && .build/debug/Eject --scan            # 在終端機印出所有外接碟與占用者
.build/debug/Eject --preview                        # 把選單列面板放進一般視窗
.build/debug/Eject --snapshot <資料夾> [--dark]      # 輸出介面截圖後結束
```

## 限制

- 無法上架 App Store（沙盒禁止讀取其他程序資訊），自己編譯使用即可。
- 沒有 root 權限時看不到系統程序（Spotlight、Time Machine 等）開啟的檔案；遇到這種情況介面會說明並提供強制退出。

## 專案結構

```
Sources/Eject/
├── EjectApp.swift            # 進入點、MenuBarExtra
├── Core/
│   ├── Models.swift          # 宗卷、占用程序、分組資料結構
│   ├── DiskMonitor.swift     # DiskArbitration 監聽掛載、IOKit 找實體裝置
│   ├── ProcessScanner.swift  # libproc 掃描、App 分組、dev server／git lock 辨識
│   ├── ProcessTerminator.swift
│   ├── Ejector.swift         # DADiskUnmount / DADiskEject
│   ├── AppModel.swift        # 狀態與流程
│   └── DebugCLI.swift
└── Views/                    # 面板、卡片、占用者列、失敗視窗、共用元件
```
