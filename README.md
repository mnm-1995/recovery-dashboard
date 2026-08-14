# 回復量ダッシュボード — セットアップ手順

**先にこれだけ読んでください（正直な前提）**
- Claude Code / Codex CLI(ChatGPT) は、実際に軽いプロンプトを送って制限メッセージが
  返るかを見る"ping方式"で自動判定します。公式のAPIで残量だけを問い合わせる方法は
  現時点でどちらも存在しません（Codex側は非対話でのレート情報取得が未サポートで
  あることをOpenAI公式リポジトリのissueで確認済みです）。
- Gemini はブラウザ版のみなので自動チェック非対応。`gemini-log.ps1`で手動記録します。
- 10分おきに自動チェックする設定です（チェック自体がごく僅かに利用量を消費します。
  頻度は`setup-task.ps1`内の`-Minutes 10`を変更すれば調整できます）。

---

## 今夜あなたがやること（この順番で）

### 1. 必要なCLIが使える状態か確認
```powershell
claude --version
codex --version
```
両方ともログイン済みであること（すでにお使いとのことなので恐らくOK）。

### 2. GitHubリポジトリを作る（ダッシュボードをURL化するため）
```powershell
cd recovery-dashboard
git init
git add .
git commit -m "init"
git branch -M main
git remote add origin https://github.com/<あなたのユーザー名>/recovery-dashboard.git
git push -u origin main
```
GitHub → Settings → Pages → Source を `main` / `/(root)` に設定。
数分後 `https://<ユーザー名>.github.io/recovery-dashboard/` が開けます。

### 3. iPhoneのホーム画面に追加
上記URLをiPhoneのSafariで開く → 共有ボタン →「ホーム画面に追加」。

### 4. Gmail通知の準備（Googleアカウント側の作業）
1. https://myaccount.google.com/apppasswords を開く（2段階認証が有効である必要あり）
2. アプリパスワードを1つ発行（16桁）
3. `email-config.example.json` を `email-config.json` にコピーして中身を書き換える:
```powershell
copy email-config.example.json email-config.json
notepad email-config.json
```
```json
{
  "gmailAddress": "自分のgmailアドレス",
  "appPassword": "発行された16桁（スペースは入れたままでOK）",
  "notifyTo": "通知を受け取りたいアドレス（自分宛でOK）"
}
```
※ `email-config.json` は `.gitignore` 済みなのでGitHubには上がりません（パスワードなので当然公開しない）。

### 5. 自動監視タスクを登録（これが最後の作業）
管理者権限のPowerShellで:
```powershell
cd recovery-dashboard
.\setup-task.ps1
```
これで10分おきに`watch-agent.ps1`が自動実行されるようになります。
**これ以降は完全放置でOKです。** 寝ている間もタスクスケジューラが動き続けます
（PCがスリープしていると動きません。電源設定で「スリープしない」にするか、
少なくともPCを起動したままにしてください）。

---

## 動作の中身

| サービス | 判定方法 | 頻度 |
|---|---|---|
| Claude | `claude -p` で軽いping送信 → 制限メッセージの有無で判定 | 自動・10分毎 |
| ChatGPT(Codex CLI) | `codex exec` で軽いping送信 → 制限メッセージの有無で判定 | 自動・10分毎 |
| Gemini | 手動 | `gemini-log.ps1 -Action depleted/recovered` を自分で実行 |

回復を検知すると:
1. `data.json`を更新してGitHubへpush（ダッシュボードに反映）
2. 通常のリセット目安時刻より15分以上早い回復は「イレギュラー」として記録
3. **回復のたびに毎回Gmailへ通知**（イレギュラーかどうかも本文に明記）

## 手動コマンド一覧
```powershell
# Geminiの記録（自動化不可のため唯一手動）
.\gemini-log.ps1 -Action depleted
.\gemini-log.ps1 -Action recovered

# 監視を1回だけ手動実行して動作確認したいとき
.\watch-agent.ps1
```

## うまく動かないとき
- `claude`/`codex`が「コマンドが見つかりません」→ PowerShellを再起動してPATHを再読込
- 制限メッセージを誤検知/検知漏れする → `watch-agent.ps1`内の
  `$claudeLimitPattern` / `$codexLimitPattern` の正規表現を、実際に出たメッセージ文言に
  合わせて調整してください（文言はプランや時期で変わることがあります）
- Gmailが届かない → `email-config.json`のアプリパスワードを再発行して差し替え
- タスクを止めたい → タスクスケジューラ(`taskschd.msc`)で
  `RecoveryDashboardWatcher`を無効化/削除
