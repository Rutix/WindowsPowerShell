$scripts = "$(split-path $profile)\Scripts"
$modules = "$(split-path $profile)\Modules"
$docs    =  $(resolve-path "$Env:userprofile\documents")
$desktop =  $(resolve-path "$Env:userprofile\desktop")

Import-Module Pscx
Import-Module Get-PSOwner
Import-Module PsGet
Import-Module PsUrl

# Load posh-git example profile
. $(resolve-path "$modules\posh-git\rutix-profile.ps1")

