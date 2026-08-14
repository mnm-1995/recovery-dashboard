# ユーザー確認が必要な項目

Claude Codeが自律作業を行った結果、以下はユーザー自身の判断・作業が必要です。

## 1. codex CLI が未インストール（要対応）
この環境（`C:\Users\login`）には `codex` コマンドが見つかりませんでした
（`where codex` で未検出、npmグローバルにも `@openai/codex` 等のパッケージなし）。
そのため `watch-agent.ps1` の ChatGPT(Codex) 監視は毎回「コマンドが見つかりません」
扱いになり、**ChatGPTカードは自動更新されません**（Claude/Geminiは影響なし）。

- ChatGPT自動監視を使うには、Codex CLIをインストールしてログインしてください。
- インストール後、`codex exec "Reply with only the single word OK." --json --skip-git-repo-check --ephemeral`
  を一度手動実行し、`watch-agent.ps1` 内の `$codexLimitPattern` が実際の出力と
  一致するか確認してください（正常時・制限時両方）。今回は codex 自体が無いため
  この検証ができていません。

## 2. Claudeの「制限到達」文言は実地未検証（重要）
`claude -p` の**通常時**のJSON出力は実際に確認し、`$claudeLimitPattern` を
より頑健な形（"usage limit reached" の有無で判定し、reset目安の文言差異は
判定に影響しないよう分離）に修正済みです。

ただし、**実際に制限にかかった状態のメッセージは意図的に再現していません**。
理由: 検証のためには実際にClaudeの5時間利用枠を使い切る必要があり、
その間あなたがClaudeを使えなくなるため、影響が大きすぎると判断しました。

- 次に自然に利用制限へ到達したタイミングで、ダッシュボードのClaudeカードが
  正しく「DEPLETED」→ 回復時「RECOVERING→READY」に切り替わるか確認してください。
- もし検知に失敗している場合（10分待っても状態が変わらない）、
  `.\watch-agent.ps1` を手動実行してエラー出力を確認し、
  `$claudeLimitPattern` / `$claudeResetHintPattern`（watch-agent.ps1内）を
  実際に出たメッセージ文言に合わせて調整してください。

## 3. GitHubリポジトリを「公開」で作成しました
`gh` コマンドが使えたため自動でリポジトリを作成しましたが、GitHub Pagesは
無料プランでは**公開リポジトリでないと使えない**ため、
`https://github.com/mnm-1995/recovery-dashboard` は**公開リポジトリ**です。

- 公開される内容: index.html/data.json等。data.jsonにはClaude/ChatGPT/Geminiの
  利用制限到達・回復の**時刻**が記録されます。氏名・メールアドレス・APIキー等は含まれません。
- URL: https://mnm-1995.github.io/recovery-dashboard/ （200 OK 確認済み・iPhoneホーム画面に追加可）
- もし非公開にしたい場合は、GitHub Pro等の有料プランへのアップグレードが必要です
  （プライベートリポジトリでのPages機能は無料プランでは提供されていません）。
  非公開のまま使いたい場合は、Cloudflare Pages等の別サービスへの切り替えを検討してください。

## 4. email-config.json はすでに設定済みでした
あなたが既に `email-config.json` を用意していたため、中身は一切表示・変更せず
テストメールを1通送信しました（`Send-RecoveryGmail` の戻り値: 成功）。
届いているか受信箱をご確認ください。届いていない場合は、Gmailのアプリパスワードを
再発行して差し替えてください（README参照）。

## 5. タスクスケジューラの繰り返し期間は10年
`[TimeSpan]::MaxValue` を指定するとタスク登録自体が失敗するバグがあったため、
実質無期限とみなせる「10年間、10分おき」に設定を修正しました。
2036年頃に一度 `.\setup-task.ps1` を再実行する必要がありますが、実用上は
「放置でOK」という当初の設計意図の通りです。

## 6. Claude実数値表示は「キャッシュがまだ一度も作られていない」状態のまま完了（要確認）
`~/.claude/rate_limit_cache.json` は、対話セッションでClaude Codeのstatus lineが
実際に一度描画されないと作られません。今回のような非対話実行のセッションでは
最後まで作られなかったため、`watch-agent.ps1` は今回はping方式にフォールバックし
（`lastSource:"ping"`）、data.jsonのClaudeカードはまだ実数値になっていません。

- statusline方式のロジック自体（実数値の反映・100%到達検知・回復検知・古いキャッシュの
  棄却）は複製した隔離テストで4パターンとも正しく動作することを確認済みです。ただし
  実際の `rate_limit_cache.json` を経由した本番フル実行での確認はできていません。
- 通常のターミナルでClaude Codeを1回でも対話的に使えば、status line hookが実行され
  キャッシュファイルが自動生成されます。その後は次回のタスクスケジューラ実行
  （最大10分後）で自動的に実数値表示に切り替わるはずです。
- もし10分待ってもClaudeカードの「自動監視(実数値)」表示に切り替わらない場合は、
  `Get-Content ~/.claude/rate_limit_cache.json` でキャッシュの中身を確認し、
  `.\watch-agent.ps1` を手動実行してエラーが出ないか確認してください。
