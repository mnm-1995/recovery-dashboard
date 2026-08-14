# セットアップ完了状況

Claude Codeが自律的に検証・修正・デプロイした結果のまとめです。
（実施日: 2026-08-14）

## 追記（同日）: Claudeの回復量表示を実数値ベースに切り替え

`~/.claude/statusline_dashboard.py`（ユーザーが手動設定済み）が書き出す
`~/.claude/rate_limit_cache.json` から、Claudeの実際の利用率(5時間枠/週間枠)を
読み取って表示するように変更しました。

- `watch-agent.ps1`: `~/.claude/rate_limit_cache.json` が存在し `updatedAt` が
  24時間以内なら、そこから `usedPercentage`/`resetsAt`(5時間枠)、
  `weeklyUsedPercentage`/`weeklyResetsAt`(週間枠) を読み取り `lastSource:"statusline"`
  としてdata.jsonに反映。キャッシュが無い/古い場合のみ既存のping方式にフォールバックし
  `lastSource:"ping"` とする。usedPercentageが95%以上から20ポイント以上急落した
  遷移を「回復」とみなし、既存のGmail通知・イレギュラー判定の仕組みをそのまま流用。
- `data.json`: claudeサービスのスキーマを拡張（`mode:"auto-precise"` /
  `usedPercentage` / `resetsAt` / `weeklyUsedPercentage` / `weeklyResetsAt` /
  `lastSource`）。ChatGPT/Geminiのスキーマは変更なし。
- `index.html`: Claudeカードのみ、リング表示を `100 - usedPercentage` に、
  サブテキストにリセットまでの残り時間、週間制限のミニバー(使用率%とリセット曜日時刻)を
  追加。`usedPercentage` が未設定(null)の場合は従来どおりイベントログベースの表示に
  自動フォールバックするため、ChatGPT/Geminiの表示・挙動は変更していません。

**動作確認について**: この作業を行ったセッションでは
`~/.claude/rate_limit_cache.json` がまだ一度も生成されていなかった（対話セッションで
status lineが描画されないと作られないため）。そのため:
- `watch-agent.ps1` を実際に1回フル実行し、ping方式へのフォールバック
  （`lastSource:"ping"`, `mode:"auto-precise"`）がdata.jsonに正しく反映され、
  git push まで完走することを確認済み。
- statusline方式（実数値の読み取り・47%等の反映・100%到達時のdepletedイベント・
  100%→5%急落時のrecoveredイベント・24時間超キャッシュの棄却）は、
  `Get-ClaudeRateLimitCache` / `Update-ClaudePrecise` のロジックを複製した
  隔離テストスクリプトで4パターンとも意図通り動作することを確認済み（本番の
  git操作は行っていない）。実際のキャッシュファイルを使った本番フル実行での
  確認は未実施。次に通常のClaude Codeセッションで status line が一度描画されれば
  キャッシュが自然に作られるので、その後の次回タスクスケジューラ実行（最大10分後）で
  自動的に実数値表示へ切り替わるはずです。
- index.htmlは、上記の実数値データを模したdata.jsonでPlaywrightによりモバイル幅/
  デスクトップ幅の両方をスクリーンショット確認し、JSエラー無し・レイアウト崩れ無しを確認済み。

## 自動化できたこと

| # | 項目 | 結果 |
|---|---|---|
| 1 | `claude -p` の実出力確認・正規表現検証 | ✅ 実施。通常時JSONを確認し、`watch-agent.ps1`の判定ロジックを修正（下記「見つかった不具合」参照） |
| 2 | `watch-agent.ps1` の動作確認 | ✅ 手動実行・タスクスケジューラ経由実行の両方で正常完走を確認。data.jsonは想定通り変化なし |
| 3 | GitHubリポジトリ作成・Pages有効化 | ✅ `gh`コマンドで自動作成・push・Pages有効化。`https://mnm-1995.github.io/recovery-dashboard/` で200を確認済み |
| 4 | Gmail送信テスト | ✅ 既存の`email-config.json`を使いテストメール送信成功（中身は不可視のまま） |
| 5 | タスクスケジューラ登録 | ✅ 登録・`Get-ScheduledTask`で確認。手動トリガーでも正常終了(LastTaskResult: 0) |
| 6 | index.htmlのブラウザ確認 | ✅ Playwrightでモバイル幅(iPhone想定)・デスクトップ幅、空データ・データありの両パターンをスクリーンショット確認。JSエラーなし、レイアウト崩れなし |

## 見つかって修正した不具合

- **`watch-agent.ps1`**: 制限判定の正規表現が `"resets at ..."` という文言を
  必須としていたが、実際のClaude Code CLIの表示文言は `"resets <time>"` や
  `"resets in <duration>"` など "at" を伴わない形式もあることをバイナリ解析で確認。
  判定（depleted検知）とreset時刻抽出を分離し、文言の揺れに強い作りに修正。
  また、`is_error:true`だが制限メッセージではない場合（認証切れ等）に誤って
  "ready"と判定してしまうバグも修正（→ "unknown"を返すように）。
- **`setup-task.ps1`**: `-RepetitionDuration ([TimeSpan]::MaxValue)` がタスク
  スケジューラのXMLスキーマ上限を超えてエラーになり、**実際にはタスクが
  登録されないのに「登録しました」と表示される**という重大なバグを発見・修正。
  10年間の反復期間に変更し、失敗時はエラーで停止するように修正。
- `README.md`が参照している `email-config.example.json` が存在しなかったため新規作成。

## 自動化できなかったこと・要確認事項

`NEEDS_USER.md` に詳細を記載しました。要点のみ:

1. **codex CLIが未インストール** — ChatGPTの自動監視は現状動作しません。インストール後、実出力に合わせて`$codexLimitPattern`の再確認が必要です。
2. **Claudeの「制限到達」時の実メッセージは意図的に未検証** — 実際に5時間枠を使い切る必要があり影響が大きいため、あえて行いませんでした。次に自然に制限へ達したときに動作確認をお願いします。
3. **GitHubリポジトリは公開設定** — 無料プランでPagesを使うための制約です。data.jsonには利用制限の時刻のみが載り、個人情報・APIキーは含まれません。

## 最後にユーザーが確認すべきこと

- [ ] `https://mnm-1995.github.io/recovery-dashboard/` をiPhoneのSafariで開き、「ホーム画面に追加」する
- [ ] テストメールが届いているか受信箱を確認する
- [ ] PCをスリープさせない設定にする（タスクスケジューラはPCが起きている間のみ動作）
- [ ] （余裕があれば）Codex CLIを導入し、ChatGPT監視も有効化する
- [ ] 次にClaude/ChatGPTの利用制限に実際に達したとき、ダッシュボードが正しく反応するか一度確認する
