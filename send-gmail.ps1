<#
  Gmail通知用の関数ライブラリ。watch-agent.ps1 から dot-source して使う。
  認証情報は email-config.json（gitignore対象・非公開）から読み込む。
  Claudeがパスワードを直接扱うことはなく、ユーザー自身がApp Passwordを
  email-config.json に保存する運用（README.md参照）。
#>

function Send-RecoveryGmail {
  param(
    [Parameter(Mandatory=$true)][string]$Subject,
    [Parameter(Mandatory=$true)][string]$Body
  )

  $configPath = Join-Path $PSScriptRoot "email-config.json"
  if (-not (Test-Path $configPath)) {
    Write-Host "email-config.json が見つからないため、Gmail通知はスキップしました。" -ForegroundColor Yellow
    return $false
  }

  $cfg = Get-Content $configPath -Raw | ConvertFrom-Json

  try {
    $securePwd = ConvertTo-SecureString $cfg.appPassword -AsPlainText -Force
    $cred = New-Object System.Management.Automation.PSCredential ($cfg.gmailAddress, $securePwd)

    Send-MailMessage `
      -From $cfg.gmailAddress `
      -To $cfg.notifyTo `
      -Subject $Subject `
      -Body $Body `
      -SmtpServer "smtp.gmail.com" `
      -Port 587 `
      -UseSsl `
      -Credential $cred `
      -Encoding UTF8

    Write-Host "Gmail通知を送信しました: $Subject" -ForegroundColor Green
    return $true
  }
  catch {
    Write-Host "Gmail送信に失敗しました: $_" -ForegroundColor Red
    return $false
  }
}
