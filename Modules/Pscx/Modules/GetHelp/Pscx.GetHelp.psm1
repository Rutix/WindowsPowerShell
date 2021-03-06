#requires -Version 3

param([string[]]$PreCacheList)

if (!(Test-Path variable:\helpCache) -or $RefreshCache) {
    $SCRIPT:helpCache = @{}
}    

function Resolve-MemberOwnerType
{
    [CmdletBinding()]
    param
    (
        [system.management.automation.psmethod]$method
    )

    # TODO: support overloads, support interface definitions

    $PSCmdlet.WriteVerbose("Resolving $($method.name)'s owning Type.")
   
    # hackety-hack - this is prone to breaking in the future
    $targetType = [system.management.automation.psmethod].getfield("baseObject", "Instance,NonPublic").getvalue($method)
    
    # [system.runtimetype] is special-cased in powershell - you can't reference it?
    if (-not ($targetType.GetType().fullname -eq "System.RuntimeType"))
    {
        $targetType = $targetType.GetType()
    }

    if ($method.OverloadDefinitions -match "static")
    {
        $flags = "Static,Public"
    }
    else
    {
        $flags = "Instance,Public"
    }

    # FIXME: support overloads    
    $methodInfo = $targetType.GetMethods($flags) | ?{$_.Name -eq $method.Name}| select -first 1
    
    if (-not $methodInfo)
    {
        # this shouldn't happen.
        throw "Could not resolve owning type!"
    }
    
    $declaringType = $methodInfo.DeclaringType
    
    $PSCmdlet.WriteVerbose("Owning Type is $($targetType.fullname). Method declared on $($declaringType.fullname).")

    $declaringType
}

function Get-DocsLocation
{
    [CmdletBinding()]
    param
    (
        [type]$type,
        
        [switch]$Online,
        
        [switch]$Members,
        
        [switch]$Static
    )
    
    # get documentation filename, assembly location and assembly codebase
    $docFilename = [io.path]::changeextension([io.path]::getfilename($type.assembly.location), ".xml")
    $location = [io.path]::getdirectoryname($type.assembly.location)
    $codebase = (new-object uri $type.assembly.codebase).localpath
    
    $PSCmdlet.WriteVerbose("Documentation file is $docFilename")
    
    if (-not $Online.IsPresent)
    {
        # try localized location (typically newer than base framework dir)
        $frameworkDir = "${env:windir}\Microsoft.NET\framework\v2.0.50727"
        $lang = [system.globalization.cultureinfo]::CurrentUICulture.parent.name

        # I love looking at this. A Duff's Device for PowerShell.. well, maybe not.
        switch
            (
            "${frameworkdir}\${lang}\$docFilename",
            "${frameworkdir}\$docFilename",
            "$location\$docFilename",
            "$codebase\$docFilename"
            )
        {
            { test-path $_ } { $_; return; }
            
            default
            {
                # try next path
                continue;
            }        
        }       
    }

    # failed to find local docs, is it from MS?
    if ((Get-ObjectVendor $type) -like "*Microsoft*")
    {
        # drop locale - site will redirect to correct variation based on browser accept-lang
        $suffix = ""
        if ($Members.IsPresent)
        {
            $suffix = "_members"
        }
        
        new-object uri ("http://msdn.microsoft.com/library/{0}{1}.aspx" -f $type.fullname,$suffix)
        
        return
    }
    
    $PSCmdlet.WriteWarning("Sorry, I couldn't find any local documentation for ${type}.")
}

# Dig out something that might lead us to the vendor of this Object
function Get-ObjectVendor
{
    [CmdletBinding()]
    param
    (
        [type]$type,
        [switch]$CompanyOnly
    )

    $assembly = $type.assembly
    $attrib = $assembly.GetCustomAttributes([Reflection.AssemblyCompanyAttribute], $false) | select -first 1        
    
    if ($attrib.Company)
    {
        # try company
        $attrib.Company
        return
    }
    else
    {
        if ($CompanyOnly) { return }
        
        # try copyright
        $attrib = $assembly.GetCustomAttributes([Reflection.AssemblyCopyrightAttribute], $false) | select -first 1
        
        if ($attrib.Copyright)
        {
            $attrib.Copyright
            return
        }
    }
    $PSCmdlet.WriteVerbose("Assembly has no [AssemblyCompany] or [AssemblyCopyright] attributes.")
}

function Get-HelpSummary
{
        [CmdletBinding()]
        param
        (        
            [string]$file,
            [reflection.assembly]$assembly,
            [string]$selector
        )
        
        if ($helpCache.ContainsKey($assembly))
        {            
            $xml = $helpCache[$assembly]
            
            $PSCmdlet.WriteVerbose("Docs were found in the cache.")
        }
        else
        {
            # cache it
            Write-Progress -id 1 "Caching Help Documentation" $assembly.getname().name

            # cache this for future lookups. It's a giant pig. Oink.
            $xml = [xml](gc $file)
            
            $helpCache.Add($assembly, $xml)
            
            Write-Progress -id 1 "Caching Help Documentation" $assembly.getname().name -completed
        }

        $PSCmdlet.WriteVerbose("Selector is $selector")        

        # TODO: support overloads
        $summary = $xml.doc.members.SelectSingleNode("member[@name='$selector' or starts-with(@name,'$selector(')]").summary
        
        $summary
}

function Show-Help
{
@"    
    
   
SYNTAX

$((get-help get-objecthelp).split([char]13) | % { "$_" })
"@
}

function Get-ObjectHelp
{    
    [CmdletBinding()]
    param
    (
        [Parameter(ValueFromPipeline=$true, Mandatory=$true)]
        [ValidateNotNull()]
        $Object,

        [Parameter()]
        [switch]$Online,
        
        [Parameter()]
        [switch]$Member,
        
        [Parameter()]
        [switch]$Static
    )
    
    process 
    {
        if ($Object -is [string])
        {
            $PSCmdlet.WriteVerbose("A string was passed - reparsing as expression.")
            
            # they probably meant to pass the string inside '(' and ').'
            try
            {
                # e.g. "[int]::gettype" was passed without being wrapped
                # in new evaluative parentheses.
                $Object = invoke-expression $Object
            }
            catch
            {
                if ($_.fullyqualifiederrorid -eq "TypeNotFound,Microsoft.PowerShell.Commands.InvokeExpressionCommand")
                {
                    $PSCmdlet.WriteWarning("I don't recognize the Type in ${InputObject}. Are you sure you've typed it correctly?")
                }
                else
                {            
                    $PSCmdlet.WriteWarning("A string was passed and was parsed as an expression, and failed. " +
                        "If you really meant to find help on strings, pass [string] instead.")
                }
                $PSCmdlet.WriteVerbose($_)
                
                return
            }
        }

        $type = $Object.GetType()    
        $PSCmdlet.WriteVerbose("InputObject Type is $($type.Fullname)")
        
        $selector = $null
        
        # won't work with $type; case statements don't match with type literals?
        switch ($type.FullName)
        {
            "System.RuntimeType"
            {
                $PSCmdlet.WriteVerbose("[runtimetype]")
            
                $type = $Object
                $selector = "T:$($type.FullName)"
                
                break;
            }

            "System.Management.Automation.PSMethod"
            {
                $PSCmdlet.WriteVerbose("[psmethod]")
                
                $type = Resolve-MemberOwnerType $Object
                
                # TODO: support overloaded methods
                $selector = "M:$($type.FullName).$($Object.Name)"            
                
                break;
            }

            default
            {
                $PSCmdlet.WriteVerbose("[object]")
                $selector = "T:$($type.FullName)"            
            }
        }
        
        # do we have an assembly help xml somewhere?
        $docs = Get-DocsLocation $type -Online:$Online.IsPresent -Members:$Member.IsPresent -Static:$Static.IsPresent

        if ($docs)
        {
            $PSCmdlet.WriteVerbose("Found $docs")
            
            if ($docs -is [uri])
            {
                # Could not find local xml, but object is from Microsoft. Offer to view MSDN.
                $title = "Microsoft Developer Network"
                $message = "No local help for $($type.fullname).`n`nDo you want to visit this object's documentation page on MSDN?"
                $options = [System.Management.Automation.Host.ChoiceDescription[]]("&Yes", "&No")

                $result = $host.ui.PromptForChoice($title, $message, $options, 0)
                
                if ($result -eq 0) {
                    [diagnostics.process]::Start("iexplore.exe", $docs) > $null
                }
                return
            }
                    
            # get summary, if possible
            $summary = Get-HelpSummary $docs $type.assembly $selector
                    
            if ($summary)
            {
                [string]::empty
                
                # TODO: parse out <see ...> tags and create a PromptForChoice list to lookup referenced type(s).
                if ($summary.selectnodes) {
                    $see = $summary.selectnodes("see")
                }
                
                if (($Object -eq 42) -and (!$PSCmdlet.Force)) {
                
                    "What do you get if you multiply six by nine?"
                    [string]::empty
                    "That's it. That's all there is."
                
                } else {
                
                    $text = & {
                        if ($summary.innerxml) {
                            $summary.innerxml.trim()
                        }
                        else
                        {
                            $summary.trim()
                        }
                    }
                    
                    # strip <see ... /> tags
                    $text -replace [regex]'<see.*?"?:(.*?)"\s/>', '$1'
                }

                if ((Test-Path Variable:\see) -and $see) {
                    #Show-References 
                    # TODO: list of <see cref="foo" /> types
                }
                
                [string]::empty                
            }
            else
            {
                Write-Host "While some local documentation was found, it was incomplete. Sorry!"            
            }
        }
        else 
        {
            Write-Host "Sorry, I couldn't find any local documentation for ${type}."
            
            $vendor = Get-ObjectVendor $type -CompanyOnly
            
            if ($vendor)
            {
                # needed for urlencode
                add-type -a system.web

                write-host "However, it looks like the vendor of this Object is '${vendor}.'"
                
                $title = "Bing Search"
                $message = "Do you want to search for this object's documentation?"
                $options = [System.Management.Automation.Host.ChoiceDescription[]]("&Yes", "&No")

                $result = $host.ui.PromptForChoice($title, $message, $options, 0)
                
                if ($result -eq 0) {
                    # encode our question
                    $q = [system.web.httputility]::urlencode(("`"{0}`" {1}" -f $vendor, $type))
                    
                    # fire up the browser
                    [diagnostics.process]::Start("http://www.bing.com/results.aspx?q=$q")
                }
            }
        }
    }    
}

# cache common assembly help
function Preload-Documentation
{       
    if ($SCRIPT:helpCache.Keys.Count -eq 0) {
        # mscorlib
        $file = Get-DocsLocation ([int])
        Get-HelpSummary $file ([int].assembly) "T:System.Int32" > $null
        
        # system
        $file = Get-DocsLocation ([regex])    
        Get-HelpSummary $file ([regex].assembly) "T:System.Regex" > $null
    }
}

<#
.ForwardHelpTargetName Get-Help
.ForwardHelpCategory Cmdlet
#>
function Get-Help {
    # our proxy command generated from [proxycommand]::create((gcm get-help))
    [CmdletBinding(DefaultParameterSetName='AllUsersView', HelpUri='http://go.microsoft.com/fwlink/?LinkID=113316')]
    param(
        [Parameter(Position=0, ValueFromPipelineByPropertyName=$true)]
        [System.String]
        ${Name},

        [System.String]
        ${Path},

        [System.String[]]
        ${Category},

        [System.String[]]
        ${Component},

        [System.String[]]
        ${Functionality},

        [System.String[]]
        ${Role},

        [Parameter(ParameterSetName='DetailedView', Mandatory=$true)]
        [Switch]
        ${Detailed},

        [Parameter(ParameterSetName='AllUsersView')]
        [Switch]
        ${Full},

        [Parameter(ParameterSetName='Examples', Mandatory=$true)]
        [Switch]
        ${Examples},

        [Parameter(ParameterSetName='Parameters', Mandatory=$true)]
        [System.String]
        ${Parameter},
        
        [Parameter(ParameterSetName='ObjectHelp', ValueFromPipeline = $true, Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        ${Object},

        [Parameter(ParameterSetName='ObjectHelp')]
        [Switch]
        ${Member},
        
        [Parameter(ParameterSetName='ObjectHelp')]
        [Switch]
        ${Static},        

        [Parameter(ParameterSetName='ObjectHelp')]
        [Parameter(ParameterSetName='Online', Mandatory=$true)]
        [switch]
        ${Online},

        [Parameter(ParameterSetName='ShowWindow', Mandatory=$true)]
        [switch]
        ${ShowWindow}
    )

    begin
    {
        try 
        {
            if ($PSCmdlet.ParameterSetName -eq "ObjectHelp") 
            {                                
                Preload-Documentation
                
                $wrappedCmd = $ExecutionContext.InvokeCommand.GetCommand('Get-ObjectHelp', [System.Management.Automation.CommandTypes]::Function)
                $scriptCmd = { & $wrappedCmd @PSBoundParameters }
                $steppablePipeline = $scriptCmd.GetSteppablePipeline($myInvocation.CommandOrigin)                
            
            } 
            else 
            {
				# Working around a bug in PowerShell (try man -?) where it passes in the wrong category info for aliases.
                if ($Name)
                {
                    $isAlias = (Microsoft.PowerShell.Core\Get-Command $Name -ErrorAction 'SilentlyContinue').CommandType -eq 'Alias'
				    if ($isAlias)
				    {
				        $PSBoundParameters['Category'] = 'Alias'
				    }
                }

                $outBuffer = $null
                if ($PSBoundParameters.TryGetValue('OutBuffer', [ref]$outBuffer) -and $outBuffer -gt 1024)
                {
                    $PSBoundParameters['OutBuffer'] = 1024
                }

                $wrappedCmd = $ExecutionContext.InvokeCommand.GetCommand('Microsoft.PowerShell.Core\Get-Help', [System.Management.Automation.CommandTypes]::Cmdlet)
                $scriptCmd = { & $wrappedCmd @PSBoundParameters }
                $steppablePipeline = $scriptCmd.GetSteppablePipeline($myInvocation.CommandOrigin)   
            }
            $steppablePipeline.Begin($PSCmdlet)
        } 
        catch {
            throw
        }
    }

    process
    {
        try {        
            $steppablePipeline.Process($_)
        } catch {
            throw
        }
    }

    end
    {
        try {
            $steppablePipeline.End()
        } catch {
            throw
        }
    }
}

Export-ModuleMember Get-Help

<#
    NAME
    
        ObjectHelp Extensions Module 0.3 for PowerShell 2.0
     
    SYNOPSIS
    
         Get-Help -Object allows you to display usage and summary help for .NET Types and Members.
         
    DETAILED DESCRIPTION
    
        Get-Help -Object allows you to display usage and summary help for .NET Types and Members.
    
        If local documentation is not found and the object vendor is Microsoft, you will be directed
        to MSDN online to the correct page. If the vendor is not Microsoft and vendor information
        exists on the owning assembly, you will be prompted to search for information using Bing.
     
    TODO
     
         * localize strings into PSD1 file
         * Implement caching in hashtables. XMLDocuments are fat pigs.
         * Support getting property/field help
         * PowerTab integration?
         * Test with Strict Parser
             
    EXAMPLES

        # get help on a type
        PS> get-help -obj [int]

        # get help against live instances
        PS> $obj = new-object system.xml.xmldocument
        PS> get-help -obj `$obj

        or even:
        
        PS> get-help -obj 42
        
        # get help against methods
        PS> get-help -obj `$obj.Load

        # explictly try msdn
        PS> get-help -obj [regex] -online

        # go to msdn for regex's members
        PS> get-help -obj [regex] -online -member
        
        # pipe support
        PS> 1,[int],[string]::format | get-help -verbose
    
    CREDITS
    
        Author: Oisin Grehan (MVP)
        Blog  : http://www.nivot.org/
    
        Have fun!    
#>

# SIG # Begin signature block
# MIIfUwYJKoZIhvcNAQcCoIIfRDCCH0ACAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQUDwSBnl9eTZ2cRHyGEsG2C2M2
# HvygghqFMIIGajCCBVKgAwIBAgIQA5/t7ct5W43tMgyJGfA2iTANBgkqhkiG9w0B
# AQUFADBiMQswCQYDVQQGEwJVUzEVMBMGA1UEChMMRGlnaUNlcnQgSW5jMRkwFwYD
# VQQLExB3d3cuZGlnaWNlcnQuY29tMSEwHwYDVQQDExhEaWdpQ2VydCBBc3N1cmVk
# IElEIENBLTEwHhcNMTMwNTIxMDAwMDAwWhcNMTQwNjA0MDAwMDAwWjBHMQswCQYD
# VQQGEwJVUzERMA8GA1UEChMIRGlnaUNlcnQxJTAjBgNVBAMTHERpZ2lDZXJ0IFRp
# bWVzdGFtcCBSZXNwb25kZXIwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIB
# AQC6aUqBTW+lFBaqis1nvku/xmmPWBzgeegenVgmmNpc1Hyj+dsrjBI2w/z5ZAax
# u8KomAoXDeGV60C065ZtmL+mj3nPvIqSe22cGAZR2KUYUzIBJxlh6IRB38bw6Mr+
# d61f2J57jGBvhVxGvWvnD4DO5wPDfDHPt2VVxvvgmQjkc1r7l9rQTL60tsYPfyaS
# qbj8OO605DqkSNBM6qlGJ1vPkhGTnBan/tKtHyLFHqzBce+8StsBCUTfmBwtZ7qo
# igMzyVG19wJNCaRN/oBexddFw30IqgEzzDPYTzAW5P8iMi7rfjvw+R4y65Ul0vL+
# bVSEutXl1NHdG6+9WXuUhTABAgMBAAGjggM1MIIDMTAOBgNVHQ8BAf8EBAMCB4Aw
# DAYDVR0TAQH/BAIwADAWBgNVHSUBAf8EDDAKBggrBgEFBQcDCDCCAb8GA1UdIASC
# AbYwggGyMIIBoQYJYIZIAYb9bAcBMIIBkjAoBggrBgEFBQcCARYcaHR0cHM6Ly93
# d3cuZGlnaWNlcnQuY29tL0NQUzCCAWQGCCsGAQUFBwICMIIBVh6CAVIAQQBuAHkA
# IAB1AHMAZQAgAG8AZgAgAHQAaABpAHMAIABDAGUAcgB0AGkAZgBpAGMAYQB0AGUA
# IABjAG8AbgBzAHQAaQB0AHUAdABlAHMAIABhAGMAYwBlAHAAdABhAG4AYwBlACAA
# bwBmACAAdABoAGUAIABEAGkAZwBpAEMAZQByAHQAIABDAFAALwBDAFAAUwAgAGEA
# bgBkACAAdABoAGUAIABSAGUAbAB5AGkAbgBnACAAUABhAHIAdAB5ACAAQQBnAHIA
# ZQBlAG0AZQBuAHQAIAB3AGgAaQBjAGgAIABsAGkAbQBpAHQAIABsAGkAYQBiAGkA
# bABpAHQAeQAgAGEAbgBkACAAYQByAGUAIABpAG4AYwBvAHIAcABvAHIAYQB0AGUA
# ZAAgAGgAZQByAGUAaQBuACAAYgB5ACAAcgBlAGYAZQByAGUAbgBjAGUALjALBglg
# hkgBhv1sAxUwHwYDVR0jBBgwFoAUFQASKxOYspkH7R7for5XDStnAs0wHQYDVR0O
# BBYEFGMvyd95knu1I8q74aTuM37j4p36MH0GA1UdHwR2MHQwOKA2oDSGMmh0dHA6
# Ly9jcmwzLmRpZ2ljZXJ0LmNvbS9EaWdpQ2VydEFzc3VyZWRJRENBLTEuY3JsMDig
# NqA0hjJodHRwOi8vY3JsNC5kaWdpY2VydC5jb20vRGlnaUNlcnRBc3N1cmVkSURD
# QS0xLmNybDB3BggrBgEFBQcBAQRrMGkwJAYIKwYBBQUHMAGGGGh0dHA6Ly9vY3Nw
# LmRpZ2ljZXJ0LmNvbTBBBggrBgEFBQcwAoY1aHR0cDovL2NhY2VydHMuZGlnaWNl
# cnQuY29tL0RpZ2lDZXJ0QXNzdXJlZElEQ0EtMS5jcnQwDQYJKoZIhvcNAQEFBQAD
# ggEBAKt0vUAATHYVJVc90xwD/31FyEUSZucoZWDY3zuz+g3BrDOP9IG5YfGd+5hV
# 195HQ7qAPfFIzD9nMFYfzvTQTIS9h6SexeEPqAZd0C9uXtwZ6PCH6uBOrz1sII5z
# b37WhxjghtOa/J7qjHLpQQ+4cbU4LPgpstUcop0b7F8quNw3IOHLu/DQbGyls8uf
# SvZU4yY0PS64wSsct/bDPf7RLR5Q9JTI+P3uc9tJtRv09f+lkME5FBvY7XEbapj7
# +kCaRKkpDlVeeLi3pIPDcAHwZkDlrnk04StNA6Et5ttUYhjt1QmLoqrWDMhPGr6Z
# JXhpmYnUWYne34jw02dedKWdpkQwggabMIIFg6ADAgECAhAK3lreshTkdg4UkQS9
# ucecMA0GCSqGSIb3DQEBBQUAMG8xCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdp
# Q2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xLjAsBgNVBAMTJURp
# Z2lDZXJ0IEFzc3VyZWQgSUQgQ29kZSBTaWduaW5nIENBLTEwHhcNMTMwOTEwMDAw
# MDAwWhcNMTYwOTE0MTIwMDAwWjBnMQswCQYDVQQGEwJVUzELMAkGA1UECBMCQ08x
# FTATBgNVBAcTDEZvcnQgQ29sbGluczEZMBcGA1UEChMQNkw2IFNvZnR3YXJlIExM
# QzEZMBcGA1UEAxMQNkw2IFNvZnR3YXJlIExMQzCCASIwDQYJKoZIhvcNAQEBBQAD
# ggEPADCCAQoCggEBAI/YYNDd/Aw4AcjlGyyL+qjbxgXi1x6uw7Qmsjst/Z1yx0ES
# BQb29HmGeka3achcbRPgmBTt3Jn6427FDhvKOXhk7dPJ2mFxfv3NACa+Knvq/sz9
# xClrULvhpyOba8lOgXm5A9zWWBmUgYISVYz0jiS+/jl8x3yEEzplkTYrDsaiFiA0
# 9HSpKCqvdnhBjIL6MGJeS13rFXjlY5KlfwPJAV5txn4WM8/6cjGRDa550Cg7dygd
# SyDv7oDH7+AFqKakiE6Z+4yuBGhWQEBFnL9MZvlp3hkGK6Wlqy0Dfg3qkgqggcGx
# MS+CpdbfXF+pdCbSpuYu4FrCuDb+ae1TbyTiTBECAwEAAaOCAzkwggM1MB8GA1Ud
# IwQYMBaAFHtozimqwBe+SXrh5T/Wp/dFjzUyMB0GA1UdDgQWBBTpFzY/nfuGUb9f
# L83BlRNclRNsizAOBgNVHQ8BAf8EBAMCB4AwEwYDVR0lBAwwCgYIKwYBBQUHAwMw
# cwYDVR0fBGwwajAzoDGgL4YtaHR0cDovL2NybDMuZGlnaWNlcnQuY29tL2Fzc3Vy
# ZWQtY3MtMjAxMWEuY3JsMDOgMaAvhi1odHRwOi8vY3JsNC5kaWdpY2VydC5jb20v
# YXNzdXJlZC1jcy0yMDExYS5jcmwwggHEBgNVHSAEggG7MIIBtzCCAbMGCWCGSAGG
# /WwDATCCAaQwOgYIKwYBBQUHAgEWLmh0dHA6Ly93d3cuZGlnaWNlcnQuY29tL3Nz
# bC1jcHMtcmVwb3NpdG9yeS5odG0wggFkBggrBgEFBQcCAjCCAVYeggFSAEEAbgB5
# ACAAdQBzAGUAIABvAGYAIAB0AGgAaQBzACAAQwBlAHIAdABpAGYAaQBjAGEAdABl
# ACAAYwBvAG4AcwB0AGkAdAB1AHQAZQBzACAAYQBjAGMAZQBwAHQAYQBuAGMAZQAg
# AG8AZgAgAHQAaABlACAARABpAGcAaQBDAGUAcgB0ACAAQwBQAC8AQwBQAFMAIABh
# AG4AZAAgAHQAaABlACAAUgBlAGwAeQBpAG4AZwAgAFAAYQByAHQAeQAgAEEAZwBy
# AGUAZQBtAGUAbgB0ACAAdwBoAGkAYwBoACAAbABpAG0AaQB0ACAAbABpAGEAYgBp
# AGwAaQB0AHkAIABhAG4AZAAgAGEAcgBlACAAaQBuAGMAbwByAHAAbwByAGEAdABl
# AGQAIABoAGUAcgBlAGkAbgAgAGIAeQAgAHIAZQBmAGUAcgBlAG4AYwBlAC4wgYIG
# CCsGAQUFBwEBBHYwdDAkBggrBgEFBQcwAYYYaHR0cDovL29jc3AuZGlnaWNlcnQu
# Y29tMEwGCCsGAQUFBzAChkBodHRwOi8vY2FjZXJ0cy5kaWdpY2VydC5jb20vRGln
# aUNlcnRBc3N1cmVkSURDb2RlU2lnbmluZ0NBLTEuY3J0MAwGA1UdEwEB/wQCMAAw
# DQYJKoZIhvcNAQEFBQADggEBAANu3/2PhW9plSTLJBR7SZBv4XqKxMzAJOw9GzNB
# uj4ihsyn/cRt1HV/ey7J9vM2mKZ5dZhU6rpb/cRnnKzEHDSSYnaogUDWbnBAw43P
# 6q6T9xKktrCpWhZRqbCRquix/VZN4dphqkdwpS//b/YnKnHi2da3MB1GqzQw6PQd
# mCWGHm+/CZWWI6GWZxdnRrDSkpMbkPYwdupQMVFFqQWWl/vJddLSM6bim0GD/XlU
# sz8hvYdOnOUT9g8+I3SegouqnrAOqu9Yj046iM29/6tkwyOCOKKeVl+uulpXnJRi
# nRkpczbl0OMMmIakVF1OTG/A/g2PPd6Xp4NDAWIKnsCdh64wggajMIIFi6ADAgEC
# AhAPqEkGFdcAoL4hdv3F7G29MA0GCSqGSIb3DQEBBQUAMGUxCzAJBgNVBAYTAlVT
# MRUwEwYDVQQKEwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5j
# b20xJDAiBgNVBAMTG0RpZ2lDZXJ0IEFzc3VyZWQgSUQgUm9vdCBDQTAeFw0xMTAy
# MTExMjAwMDBaFw0yNjAyMTAxMjAwMDBaMG8xCzAJBgNVBAYTAlVTMRUwEwYDVQQK
# EwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xLjAsBgNV
# BAMTJURpZ2lDZXJ0IEFzc3VyZWQgSUQgQ29kZSBTaWduaW5nIENBLTEwggEiMA0G
# CSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQCcfPmgjwrKiUtTmjzsGSJ/DMv3SETQ
# PyJumk/6zt/G0ySR/6hSk+dy+PFGhpTFqxf0eH/Ler6QJhx8Uy/lg+e7agUozKAX
# EUsYIPO3vfLcy7iGQEUfT/k5mNM7629ppFwBLrFm6aa43Abero1i/kQngqkDw/7m
# JguTSXHlOG1O/oBcZ3e11W9mZJRru4hJaNjR9H4hwebFHsnglrgJlflLnq7MMb1q
# WkKnxAVHfWAr2aFdvftWk+8b/HL53z4y/d0qLDJG2l5jvNC4y0wQNfxQX6xDRHz+
# hERQtIwqPXQM9HqLckvgVrUTtmPpP05JI+cGFvAlqwH4KEHmx9RkO12rAgMBAAGj
# ggNDMIIDPzAOBgNVHQ8BAf8EBAMCAYYwEwYDVR0lBAwwCgYIKwYBBQUHAwMwggHD
# BgNVHSAEggG6MIIBtjCCAbIGCGCGSAGG/WwDMIIBpDA6BggrBgEFBQcCARYuaHR0
# cDovL3d3dy5kaWdpY2VydC5jb20vc3NsLWNwcy1yZXBvc2l0b3J5Lmh0bTCCAWQG
# CCsGAQUFBwICMIIBVh6CAVIAQQBuAHkAIAB1AHMAZQAgAG8AZgAgAHQAaABpAHMA
# IABDAGUAcgB0AGkAZgBpAGMAYQB0AGUAIABjAG8AbgBzAHQAaQB0AHUAdABlAHMA
# IABhAGMAYwBlAHAAdABhAG4AYwBlACAAbwBmACAAdABoAGUAIABEAGkAZwBpAEMA
# ZQByAHQAIABDAFAALwBDAFAAUwAgAGEAbgBkACAAdABoAGUAIABSAGUAbAB5AGkA
# bgBnACAAUABhAHIAdAB5ACAAQQBnAHIAZQBlAG0AZQBuAHQAIAB3AGgAaQBjAGgA
# IABsAGkAbQBpAHQAIABsAGkAYQBiAGkAbABpAHQAeQAgAGEAbgBkACAAYQByAGUA
# IABpAG4AYwBvAHIAcABvAHIAYQB0AGUAZAAgAGgAZQByAGUAaQBuACAAYgB5ACAA
# cgBlAGYAZQByAGUAbgBjAGUALjASBgNVHRMBAf8ECDAGAQH/AgEAMHkGCCsGAQUF
# BwEBBG0wazAkBggrBgEFBQcwAYYYaHR0cDovL29jc3AuZGlnaWNlcnQuY29tMEMG
# CCsGAQUFBzAChjdodHRwOi8vY2FjZXJ0cy5kaWdpY2VydC5jb20vRGlnaUNlcnRB
# c3N1cmVkSURSb290Q0EuY3J0MIGBBgNVHR8EejB4MDqgOKA2hjRodHRwOi8vY3Js
# My5kaWdpY2VydC5jb20vRGlnaUNlcnRBc3N1cmVkSURSb290Q0EuY3JsMDqgOKA2
# hjRodHRwOi8vY3JsNC5kaWdpY2VydC5jb20vRGlnaUNlcnRBc3N1cmVkSURSb290
# Q0EuY3JsMB0GA1UdDgQWBBR7aM4pqsAXvkl64eU/1qf3RY81MjAfBgNVHSMEGDAW
# gBRF66Kv9JLLgjEtUYunpyGd823IDzANBgkqhkiG9w0BAQUFAAOCAQEAe3IdZP+I
# yDrBt+nnqcSHu9uUkteQWTP6K4feqFuAJT8Tj5uDG3xDxOaM3zk+wxXssNo7ISV7
# JMFyXbhHkYETRvqcP2pRON60Jcvwq9/FKAFUeRBGJNE4DyahYZBNur0o5j/xxKqb
# 9to1U0/J8j3TbNwj7aqgTWcJ8zqAPTz7NkyQ53ak3fI6v1Y1L6JMZejg1NrRx8iR
# ai0jTzc7GZQY1NWcEDzVsRwZ/4/Ia5ue+K6cmZZ40c2cURVbQiZyWo0KSiOSQOiG
# 3iLCkzrUm2im3yl/Brk8Dr2fxIacgkdCcTKGCZlyCXlLnXFp9UH/fzl3ZPGEjb6L
# HrJ9aKOlkLEM/zCCBs0wggW1oAMCAQICEAb9+QOWA63qAArrPye7uhswDQYJKoZI
# hvcNAQEFBQAwZTELMAkGA1UEBhMCVVMxFTATBgNVBAoTDERpZ2lDZXJ0IEluYzEZ
# MBcGA1UECxMQd3d3LmRpZ2ljZXJ0LmNvbTEkMCIGA1UEAxMbRGlnaUNlcnQgQXNz
# dXJlZCBJRCBSb290IENBMB4XDTA2MTExMDAwMDAwMFoXDTIxMTExMDAwMDAwMFow
# YjELMAkGA1UEBhMCVVMxFTATBgNVBAoTDERpZ2lDZXJ0IEluYzEZMBcGA1UECxMQ
# d3d3LmRpZ2ljZXJ0LmNvbTEhMB8GA1UEAxMYRGlnaUNlcnQgQXNzdXJlZCBJRCBD
# QS0xMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA6IItmfnKwkKVpYBz
# QHDSnlZUXKnE0kEGj8kz/E1FkVyBn+0snPgWWd+etSQVwpi5tHdJ3InECtqvy15r
# 7a2wcTHrzzpADEZNk+yLejYIA6sMNP4YSYL+x8cxSIB8HqIPkg5QycaH6zY/2DDD
# /6b3+6LNb3Mj/qxWBZDwMiEWicZwiPkFl32jx0PdAug7Pe2xQaPtP77blUjE7h6z
# 8rwMK5nQxl0SQoHhg26Ccz8mSxSQrllmCsSNvtLOBq6thG9IhJtPQLnxTPKvmPv2
# zkBdXPao8S+v7Iki8msYZbHBc63X8djPHgp0XEK4aH631XcKJ1Z8D2KkPzIUYJX9
# BwSiCQIDAQABo4IDejCCA3YwDgYDVR0PAQH/BAQDAgGGMDsGA1UdJQQ0MDIGCCsG
# AQUFBwMBBggrBgEFBQcDAgYIKwYBBQUHAwMGCCsGAQUFBwMEBggrBgEFBQcDCDCC
# AdIGA1UdIASCAckwggHFMIIBtAYKYIZIAYb9bAABBDCCAaQwOgYIKwYBBQUHAgEW
# Lmh0dHA6Ly93d3cuZGlnaWNlcnQuY29tL3NzbC1jcHMtcmVwb3NpdG9yeS5odG0w
# ggFkBggrBgEFBQcCAjCCAVYeggFSAEEAbgB5ACAAdQBzAGUAIABvAGYAIAB0AGgA
# aQBzACAAQwBlAHIAdABpAGYAaQBjAGEAdABlACAAYwBvAG4AcwB0AGkAdAB1AHQA
# ZQBzACAAYQBjAGMAZQBwAHQAYQBuAGMAZQAgAG8AZgAgAHQAaABlACAARABpAGcA
# aQBDAGUAcgB0ACAAQwBQAC8AQwBQAFMAIABhAG4AZAAgAHQAaABlACAAUgBlAGwA
# eQBpAG4AZwAgAFAAYQByAHQAeQAgAEEAZwByAGUAZQBtAGUAbgB0ACAAdwBoAGkA
# YwBoACAAbABpAG0AaQB0ACAAbABpAGEAYgBpAGwAaQB0AHkAIABhAG4AZAAgAGEA
# cgBlACAAaQBuAGMAbwByAHAAbwByAGEAdABlAGQAIABoAGUAcgBlAGkAbgAgAGIA
# eQAgAHIAZQBmAGUAcgBlAG4AYwBlAC4wCwYJYIZIAYb9bAMVMBIGA1UdEwEB/wQI
# MAYBAf8CAQAweQYIKwYBBQUHAQEEbTBrMCQGCCsGAQUFBzABhhhodHRwOi8vb2Nz
# cC5kaWdpY2VydC5jb20wQwYIKwYBBQUHMAKGN2h0dHA6Ly9jYWNlcnRzLmRpZ2lj
# ZXJ0LmNvbS9EaWdpQ2VydEFzc3VyZWRJRFJvb3RDQS5jcnQwgYEGA1UdHwR6MHgw
# OqA4oDaGNGh0dHA6Ly9jcmwzLmRpZ2ljZXJ0LmNvbS9EaWdpQ2VydEFzc3VyZWRJ
# RFJvb3RDQS5jcmwwOqA4oDaGNGh0dHA6Ly9jcmw0LmRpZ2ljZXJ0LmNvbS9EaWdp
# Q2VydEFzc3VyZWRJRFJvb3RDQS5jcmwwHQYDVR0OBBYEFBUAEisTmLKZB+0e36K+
# Vw0rZwLNMB8GA1UdIwQYMBaAFEXroq/0ksuCMS1Ri6enIZ3zbcgPMA0GCSqGSIb3
# DQEBBQUAA4IBAQBGUD7Jtygkpzgdtlspr1LPUukxR6tWXHvVDQtBs+/sdR90OPKy
# XGGinJXDUOSCuSPRujqGcq04eKx1XRcXNHJHhZRW0eu7NoR3zCSl8wQZVann4+er
# Ys37iy2QwsDStZS9Xk+xBdIOPRqpFFumhjFiqKgz5Js5p8T1zh14dpQlc+Qqq8+c
# dkvtX8JLFuRLcEwAiR78xXm8TBJX/l/hHrwCXaj++wc4Tw3GXZG5D2dFzdaD7eeS
# DY2xaYxP+1ngIw/Sqq4AfO6cQg7PkdcntxbuD8O9fAqg7iwIVYUiuOsYGk38KiGt
# STGDR5V3cdyxG0tLHBCcdxTBnU8vWpUIKRAmMYIEODCCBDQCAQEwgYMwbzELMAkG
# A1UEBhMCVVMxFTATBgNVBAoTDERpZ2lDZXJ0IEluYzEZMBcGA1UECxMQd3d3LmRp
# Z2ljZXJ0LmNvbTEuMCwGA1UEAxMlRGlnaUNlcnQgQXNzdXJlZCBJRCBDb2RlIFNp
# Z25pbmcgQ0EtMQIQCt5a3rIU5HYOFJEEvbnHnDAJBgUrDgMCGgUAoHgwGAYKKwYB
# BAGCNwIBDDEKMAigAoAAoQKAADAZBgkqhkiG9w0BCQMxDAYKKwYBBAGCNwIBBDAc
# BgorBgEEAYI3AgELMQ4wDAYKKwYBBAGCNwIBFTAjBgkqhkiG9w0BCQQxFgQUvpM/
# mXplJB0qnDYJQK4GlD4dQ+kwDQYJKoZIhvcNAQEBBQAEggEAgerHIm5MhDFgCJEV
# iRB5sCzmOkUSD392G/xzbq89IZWhm9d+KWCGhBw4mZKuSOu/O2f/ycjWwsatwARH
# 8jngB/5lhY21i0xI1Pno43cDnHBbAcFl9k2vhL07wsr3N4Nv9y58/UekQXMaZi9h
# zXJfvgVUenQExqGCHSY0jEl4yAwUPjaT4bhL+oDSiVBitp1OVqYk2CltKdsC+qgg
# 5BrsbcpAyJKCGDtjbWOvNRTBur3jg0Yl8EqpZ2nk3ZN1mLA2hR5cKHC7MdyirdM9
# x3kMfKRjPL9WX29HsYSTE4xlxQe+Wy5av13pVMWsS9RTntWQSUCvHknkd/2HJhN0
# J2VSXqGCAg8wggILBgkqhkiG9w0BCQYxggH8MIIB+AIBATB2MGIxCzAJBgNVBAYT
# AlVTMRUwEwYDVQQKEwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2Vy
# dC5jb20xITAfBgNVBAMTGERpZ2lDZXJ0IEFzc3VyZWQgSUQgQ0EtMQIQA5/t7ct5
# W43tMgyJGfA2iTAJBgUrDgMCGgUAoF0wGAYJKoZIhvcNAQkDMQsGCSqGSIb3DQEH
# ATAcBgkqhkiG9w0BCQUxDxcNMTMxMDE3MTQyNzM4WjAjBgkqhkiG9w0BCQQxFgQU
# p97fIu+a853AWl1UCas+78EAnnIwDQYJKoZIhvcNAQEBBQAEggEAW6RJYyKq5POL
# cQK9yJfKZ8+O9RholX/eLkMHLvjrTIS+roHPDP65Pr+6gD6max5m3YuV11+BnVk8
# 5cVnZmWlNvHLExKG1C85Flh5vw6TqbzZLr8DLvRp7wH5PmzbhR18xvrDV/RFibf6
# 3dhag2vLPT946X+V3VbMfobw/el7GTmNAPPl/vknMEI9C5zrlOEPmCK9TKpVyfq9
# UBlw6GtitRb/98YoETNFKjw6wVGQfe8/kQbHdTkpVNP+WL9nIvkdpRO6vh1RQUst
# hMq9TI0B49WKwG0nLIZj9zyKyRJkZLadffexyAjjAMKEk8vsd1dHPrF1iTLQAymN
# /nr37F7VZg==
# SIG # End signature block
