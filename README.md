# sing-box REALITY 安裝與管理工具

互動式 Linux Bash 腳本，用於部署及管理 **VLESS + TCP + REALITY + Vision** 節點。

## 功能

- 自動安裝 sing-box（使用 sing-box 官方安裝腳本）
- 生成 VLESS 分享連結並保存節點資訊
- 查看服務狀態、節點資訊、檢查配置、重啟及卸載

## 安裝與執行

建立 Repository 後，可使用：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/turboYeoung/sing-box-reality-install/main/install.sh)
```

或先下載、檢查腳本，再執行：

```bash
curl -fsSLO https://raw.githubusercontent.com/turboYeoung/sing-box-reality-install/main/install.sh
less install.sh
chmod +x install.sh
sudo ./install.sh
```
## 授權

本專案採用 MIT License，詳見 [LICENSE](LICENSE)。
