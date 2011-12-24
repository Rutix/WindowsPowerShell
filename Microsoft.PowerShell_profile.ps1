$scripts = "$(split-path $profile)\Scripts"
$modules = "$(split-path $profile)\Modules"
$docs    =  $(resolve-path "$Env:userprofile\documents")
$desktop =  $(resolve-path "$Env:userprofile\desktop")

Import-Module Pscx
Import-Module Get-PSOwner

. (Resolve-Path ~/Documents/WindowsPowershell/ssh-agent-utils.ps1)

