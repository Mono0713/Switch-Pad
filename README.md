# Switch Pad

把**你自己的** Switch 遊戲打包成 iPad App 並安裝的 Windows 程式。不用開終端機、不用 Mac：從遊戲庫挑遊戲，按「開始」，
它會自動解包、打包、簽章並裝到 iPad，還會自己更新。

打包用的殼和打包器來自 [Mono0713/ns2ios-shell](https://github.com/Mono0713/ns2ios-shell)（[nxnative](https://github.com/seedds/nxnative) 的 fork），
簽章用 [Impactor](https://github.com/khcrysalis/Impactor) 的 plumesign。

> English below.

## 下載

到 **[最新版本（Releases）](https://github.com/Mono0713/Switch-Pad/releases/latest)** 下載 `SwitchPad.zip`。

## 使用方式

1. 把 `SwitchPad.zip` 解壓到任何地方（例如桌面）。
2. 打開 `Switch Pad.cmd`。第一次打開會整理資料夾：程式檔、work、工具 都收進 `程式\`，最上層只剩 `Switch Pad.exe`、
   `遊戲\`、`合包\`，之後就開 `Switch Pad.exe`。
3. 第一次按上方的「安裝」：沒有 Python 會用 winget 裝 3.12，再裝套件、殼、打包器和 plumesign，並在桌面建捷徑。
4. prod.keys：會自己到 Ryujinx 和 yuzu 系模擬器的資料夾找；找不到就把檔案拖進視窗（複製一份到 `work\`，只留在這台電腦）。
5. 按「登入 Apple ID」一次。免費帳號簽的 App 7 天後過期（按「全部續期」重簽），同時最多 3 個。
6. 把 NSP / XCI 拖進視窗新增遊戲；更新檔或 DLC 拖到遊戲卡上就會加進那款，打包時自動用最新版本。
7. 勾選遊戲按「開始」。也可以把好幾款合成一包（「合包」分頁）。

### 需要

- Windows 10 / 11
- iPad 用 USB 接著並解鎖
- Apple 的裝置服務：從 Microsoft Store 安裝「Apple 裝置」（Apple Devices）或 iTunes
- 你自己 Switch 的 `prod.keys`，和從自己 Switch 匯出的遊戲（NSP 要含票證）

### 更新

Switch Pad 打開時會到 GitHub 問有沒有新版；有的話設定（齒輪）會變藍色，按「更新」就好。
程式本身從這個 repo 的 release 更新，殼和打包器從 ns2ios-shell 的 release 更新。

## 注意

- 本專案**不提供**任何遊戲、金鑰或韌體，也不會上傳你的遊戲檔或 prod.keys；所有東西都只留在你的電腦。
- 只用在你自己擁有的遊戲上。
- 能玩的遊戲取決於殼的支援清單；沒有設定檔的遊戲會自動做暫定設定檔（實驗性）。

## 檔案

| 檔案 | 用途 |
|---|---|
| `Switch Pad.exe` | 第一次打開時在本機編出來，啟動 `程式\nxn-app.ps1` |
| `Switch Pad.cmd` | 還沒有 `Switch Pad.exe` 時用它打開 |
| `nxn-app.ps1` | 主視窗：遊戲庫、佇列、進度、設定、檢查更新 |
| `nxn.ps1` | 單款遊戲：用 `scripts/nxn_pack.py` 打包，再用 plumesign 簽章安裝；也能單獨跑（`.\nxn.ps1 -?`） |
| `nxn-update.ps1` | 安裝和更新：Python、套件、殼、工具、打包器原始碼、plumesign、Switch Pad 自己 |
| `fix_empty_romfs.py` | 遊戲沒有 RomFS 時（ANIMAL WELL）放一個佔位檔 |
| `make_provisional.py` | 沒有上游設定檔的遊戲，在 Windows 上做暫定設定檔（實驗性） |
| `nxn_merge_drop.py` | 從合包移除一款遊戲 |
| `romfs_data.py` | 把遊戲資料直接傳進 iPad，不用整包重裝 |

程式在 [`app/`](app)。改動 `app/` 推到 `main` 後，[`release.yml`](.github/workflows/release.yml) 會自動把它壓成
`SwitchPad.zip` 發布成新的 release，大家的 Switch Pad 就會收到更新。

---

## English

Switch Pad is a Windows app that packs **your own** Switch games into iPad apps and installs them, with one window instead
of a terminal and no Mac: pick games from a library, press Start, and it extracts, packs, signs and installs each one.
The app's interface is in Traditional Chinese.

1. Download `SwitchPad.zip` from the [latest release](https://github.com/Mono0713/Switch-Pad/releases/latest) and unzip it.
2. Open `Switch Pad.cmd` (later `Switch Pad.exe`, created on first start) and press **安裝** (Install) once: it installs
   Python if needed, the packages, the shell and packer from [ns2ios-shell](https://github.com/Mono0713/ns2ios-shell), and
   plumesign from [Impactor](https://github.com/khcrysalis/Impactor).
3. Give it your `prod.keys` (found automatically in Ryujinx / yuzu-family folders, or drag it onto the window).
4. Press **登入 Apple ID** (Sign in) once. A free Apple ID works; its apps expire after 7 days (**全部續期** re-signs them).
5. Drag NSP / XCI files onto the window, tick games and press **開始** (Start).

Needs Windows 10/11, the iPad connected by USB and unlocked, and **Apple Devices** (Microsoft Store) or iTunes.
No games, keys or firmware are provided, and none of your files are ever uploaded. Only use it with games you own.

The app updates itself from this repository's releases; every push to `app/` on `main` publishes a new one.
