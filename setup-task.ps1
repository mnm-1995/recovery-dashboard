<#
.SYNOPSIS
  watch-agent.ps1 をWindowsタスクスケジューラに登録し、以後10分おきに
  自動実行させる（=これ以降は完全放置でOK）。最初の1回だけ実行してください。

.使い方
  管理者権限のPowerShellで:
  .\setup-task.ps1
#>

$taskName = "RecoveryDashboardWatcher"
$scriptPath = Join-Path $PSScriptRoot "watch-agent.ps1"
$pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
if (-not $pwsh) { $pwsh = (Get-Command powershell).Source }

$action = New-ScheduledTaskAction -Execute $pwsh `
  -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""

$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) `
  -RepetitionInterval (New-TimeSpan -Minutes 10) `
  -RepetitionDuration ([TimeSpan]::MaxValue)

$settings = New-ScheduledTaskSettingsSet `
  -MultipleInstances IgnoreNew `
  -StartWhenAvailable `
  -DontStopOnIdleEnd

Register-ScheduledTask -TaskName $taskName `
  -Action $action -Trigger $trigger -Settings $settings `
  -Description "回復量ダッシュボード: Claude/Codexの利用制限を10分おきに自動チェック" `
  -Force

Write-Host "タスク '$taskName' を登録しました。10分おきに自動実行されます。" -ForegroundColor Green
Write-Host "確認/停止する場合: タスクスケジューラ（taskschd.msc）から '$taskName' を探してください。" -ForegroundColor Cyan
