# sing-box REALITY 安裝與管理工具

互動式 Linux Bash 腳本，用於部署及管理 **VLESS + TCP + REALITY + Vision** 節點。

> 目前版本：`1.0.0`。此版本是首個公開整理版，尚未在所有列出的發行版與架構上完成實機測試。請先在測試 VPS 使用，並自行檢查腳本內容。

## 功能

- 自動安裝 sing-box（使用 sing-box 官方安裝腳本）
- 自動生成 UUID、REALITY 金鑰及 Short ID
- 互動設定監聽端口、SNI、握手端口
- Google / Cloudflare DoH
- Apple、Microsoft 網域走 Direct；中國 IP / 網域依規則 Reject
- 生成 VLESS 分享連結並保存節點資訊
- 查看服務狀態、節點資訊、檢查配置、重啟及卸載

## 支援範圍

目標系統：Debian 12+、Ubuntu、Fedora / RHEL 系、Alpine、Arch / Manjaro。

需要 Bash、curl、jq、OpenSSL、iproute2，以及 systemd 或 OpenRC。不同發行版的套件來源、服務管理與 sing-box 套件支援可能不同；未列出的系統不保證相容。架構支援仍需依官方發行包確認。

## 安裝與執行

建立 Repository 後，可使用：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/turboYoung/sing-box-reality-install/main/install.sh)
```

或先下載、檢查腳本，再執行：

```bash
curl -fsSLO https://raw.githubusercontent.com/turboYoung/sing-box-reality-install/main/install.sh
less install.sh
chmod +x install.sh
sudo ./install.sh
```

必須以 root 執行。請勿在未閱讀腳本的情況下，直接將網路下載內容以 root 權限執行。

## 配置與資料位置

- 主配置：`/etc/sing-box/config.json`
- 舊配置備份：`/etc/sing-box/backup/`
- 節點資訊：`/root/sing-box-node.txt`（權限 600）
- sing-box 執行資料：`/var/lib/sing-box`

每次重新生成節點會建立新的 UUID、REALITY 金鑰及 Short ID；舊分享連結將不再對應新配置。

## 防火牆

腳本會嘗試為 UFW / firewalld 加入 TCP 監聽端口規則。仍須自行確認雲端服務商安全組或 VPS 控制台已放行該 TCP 端口。

## 卸載注意

選單中的卸載功能會停止服務並清理本工具管理的配置、節點資訊及可由系統套件管理器確認的 sing-box 套件。它不會刪除未知來源的執行檔，也不會刪除 APT/YUM 等第三方 repository 金鑰或來源檔。若 sing-box 是以其他方式安裝，請按原安裝方式自行移除。

## 安全提醒

- **不要**把 `/etc/sing-box/config.json`、`/root/sing-box-node.txt`、REALITY Private Key、UUID 或 VLESS 分享連結提交到 GitHub。
- 公開 Repository 中的腳本任何人都能查看、複製及修改。
- REALITY Private Key 必須保密；分享連結也應視為敏感資料。
- 本工具會修改系統套件、服務、防火牆及網路配置。使用前請備份 VPS。
- 本專案不保證規避任何網路政策或服務商限制；請遵守所在地法律及服務條款。

## 授權

本專案採用 MIT License，詳見 [LICENSE](LICENSE)。
