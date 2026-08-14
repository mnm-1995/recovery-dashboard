# タスク: 回復量ダッシュボードを完成させ、実際に動く状態にする

あなたはこのフォルダ（recovery-dashboard）内で、Claude Codeとして自律的に作業する。
以下がすべて実際に動くまで作業をやめないこと。一部が失敗しても他の部分を進め、
最後にまとめて報告すること。ユーザーの追加入力が必要な項目だけ `NEEDS_USER.md`
に書き出し、それ以外は自分の判断で進めてよい。

## 前提
このフォルダには既に叩き台がある:
- index.html / data.json / manifest.json / icon.png … iPhoneホーム画面用ダッシュボード
- watch-agent.ps1 … Claude Code / Codex CLI の利用制限をpingで自動検知するスクリプト
- gemini-log.ps1 … Gemini(ブラウザ版のみ)用の手動ログ記録
- send-gmail.ps1 … 回復時にGmail通知するための関数
- setup-task.ps1 … Windowsタスクスケジューラに10分おき自動実行を登録
- email-config.example.json … Gmail App Password設定のひな形
- README.md … 元々の設計意図

## やってほしいこと（優先順位順）

1. **実際に `claude -p` と `codex exec` を軽いプロンプトで叩いて、出力を確認する。**
   watch-agent.ps1内の `$claudeLimitPattern` / `$codexLimitPattern` の正規表現が
   実際のメッセージ文言と一致するか検証し、ズレていれば実物に合わせて修正すること。
   （可能なら意図的に制限にかかっている状態・かかっていない状態の両方の出力を確認する）

2. **watch-agent.ps1 を実際に1回実行し、data.jsonが正しく更新されること、
   エラーなく完走することを確認する。** バグがあれば直す。

3. **GitHubリポジトリを作成しGitHub Pagesを有効化する。**
   - `gh` コマンド（GitHub CLI）が使えるならそれで作成・push・Pages設定まで自動化する
   - 使えない場合は具体的な手順を `NEEDS_USER.md` に書き、ユーザーに実行してもらう
     （リポジトリ作成やPages有効化はブラウザ操作が必要な場合があるため）
   - Pagesが有効化されたら実際にURLにアクセスして200が返ることを確認する

4. **Gmail送信を実際にテストする。**
   `email-config.json` が無ければ、ユーザーがApp Passwordを設定する必要がある旨を
   `NEEDS_USER.md` に明記する（パスワードなのであなたが代わりに用意することはできない）。
   ある場合は send-gmail.ps1 を使ってテストメールを1通送り、届くか確認する。

5. **setup-task.ps1 を実行し、タスクスケジューラへの登録が実際に成功したことを
   `Get-ScheduledTask` 等で確認する。**

6. **index.htmlをブラウザ（可能ならスクリーンショット確認）で見て、
   レイアウト崩れやJSエラーが無いか確認し、あれば直す。**

7. すべて完了したら、`STATUS.md` に「何が自動化できたか / できなかったか /
   ユーザーが最後に確認すべきこと」を簡潔にまとめる。

## 制約
- email-config.json の中身（パスワード）を絶対にログ出力・コミットしないこと
  （.gitignore済みだが、念のため出力にも含めない）
- git commit/pushしてよいのはこのリポジトリのみ
- 詰まった場合は最大3回まで別アプローチを試し、それでもダメならNEEDS_USER.mdに
  状況を書いて次のタスクに進む（そこで完全に停止しない）
