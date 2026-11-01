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

### 遊戲庫（iPad 上只放一個 App）

下方選「遊戲庫」：勾哪些遊戲，iPad 上的「遊戲庫」App 裡就有哪些，取消勾選再按「開始」就拿掉。只有一款時會直接開遊戲，
兩款以上先選遊戲。bundle ID 固定，加減遊戲都是更新同一個 App，存檔留著；遊戲資料放在 App 的 Documents，只傳新加的那款。

- 每款遊戲第一次會用多遊戲殼打包成遊戲包（`<名稱>-multi-<殼版本>.ipa`，留在遊戲資料夾），之後加減遊戲只重新合成、重簽小 App。
  「只打包」會把勾的遊戲包全部重做；加了更新檔或 DLC 的遊戲會自動重做。
- 要有多遊戲殼（`work\multigame`）。圖示固定是 `LibraryIcon.png`。
- 遊戲可以是 NSP、XCI、NSZ 或 XCZ；NSZ / XCZ 打包前會先自動解壓（原檔收進 `NSZ原檔\`）。

### 存檔、金鑰和空間

- **iPad 存檔備份**：每次安裝前會先把 iPad 上這款的存檔備份到 `遊戲\<遊戲>\存檔備份\`（合包在 `合包\存檔備份\<合包名稱>\`），
  一樣的存檔不重複存，最多留 30 份。遊戲卡右鍵也可以「備份 iPad 存檔」「還原存檔…」；還原前會先把 iPad 上現在的存檔另外備份一份。
- **金鑰預檢**：打包前先檢查 prod.keys 打不打得開這款（只讀檔案開頭幾 KB），太舊會馬上說缺哪一代、要從哪個系統版本匯出，不用等解包失敗。
- **清理空間**：設定 →「清理空間…」列出可以重做的暫存檔（安裝用的小 App、打包暫存、30 天前的記錄）和大小，確認後丟資源回收筒。
- **複製診斷資訊**：設定 →「複製診斷資訊」把版本、工具狀態和最近記錄的結尾複製起來，回報問題時貼上（不含金鑰內容、Apple ID 或遊戲檔）。

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
| `saves_data.py` | 備份和還原 iPad 上的存檔（經 App 的 Documents） |
| `keys_check.py` | 打包前檢查 prod.keys 打不打得開這款（移植自 NX2Apple） |
| `nxn_merge.py` | 把遊戲包合成遊戲庫（ns2ios-shell 的同一支，加了 `--icon`） |
| `LibraryIcon.png` | 遊戲庫 App 的圖示 |
| `NOTICE.txt` | 第三方程式碼與授權 |

程式在 [`app/`](app)，測試在 [`tests/`](tests)（`python tests/test_keys_check.py`、`python tests/test_saves_data.py`）。改動 `app/` 推到 `main` 後，[`release.yml`](.github/workflows/release.yml) 會自動把它壓成
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

Before each install it backs up the game's iPad saves to the PC (right-click a game to back up or restore them), checks
`prod.keys` against the game before packing, and Settings can free the space of rebuildable temporary files and copy a
diagnostics summary for bug reports.

The app updates itself from this repository's releases; every push to `app/` on `main` publishes a new one.
