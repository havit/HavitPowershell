function Confirm-HavitDeployment {
  param(
    [string] $Application,
    [string] $Environment = $null
  )

    if ($Environment)
    {
        $title = "Deployment: $Application, $Environment"
        $message = "Opravdu provedememe nasazení $Application do prostředí $($Environment)?"
    }
    else
    {
        $title = "Deployment: $Application"
        $message = "Opravdu provedememe nasazení $($Application)?"
    }

    $yes = New-Object System.Management.Automation.Host.ChoiceDescription "&Ano", "Ano, provedeme nasazení."
    $no = New-Object System.Management.Automation.Host.ChoiceDescription "&Ne", "Ne, nic nebudeme nasazovat."
    $options = [System.Management.Automation.Host.ChoiceDescription[]]($yes, $no)

    $result = $host.ui.PromptForChoice($title, $message, $options, 1) 

    return ($result -eq 0)
}

function Is-ParamFilePresentInWdpFile
{
    param(
        [string] $WdpFile
    )

    $tmpAssembly = [Reflection.Assembly]::LoadWithPartialName('System.IO.Compression.FileSystem') # když neprovedu toto zbytečné přiřazení, metoda vrací neočekávaný výsledek
    $wdpEntries = [IO.Compression.ZipFile]::OpenRead($WdpFile).Entries
    $paramfiles = $wdpEntries | ForEach-Object {$_.FullName.ToLower() } | Where-Object { ($_ -eq "parameters.xml") -or ($_ -eq "systeminfo.xml") }    
    $result = $paramfiles.Length -gt 0    
    return $result
}

function Find-HavitPackage {
    $wdpPackages = Get-ChildItem -Path $((get-location).Path + '\*.zip') -Exclude 'backup-*.zip'
    if (!$wdpPackages)
    {
        throw 'No WDP file (*.zip) found in the current folder.'            
    }
    if ($wdpPackages -is [system.array])
    {
        throw 'Multiple WDP files (*.zip) found in the current folder.'
    }     
    return $wdpPackages.FullName   
}

function Publish-HavitWebsitePackageInternal {
    param(
        [string] $WdpFile = $null,
        [string] $WebsiteName = $null,
        [string] $Url,
        [string] $Username,
        [string] $Password,
        [string] $DeploySetParametersFile = $null,
        [object[]] $CustomMsDeployArguments = $null
    )
     
    # try to find wdp file if not specified
    if (!$WdpFile)
    {
        $WdpFile = Find-HavitPackage
    }
    else
    {
        $WdpFile = (Get-Item $WdpFile).FullName # get full path
    }
	
    $auth = (Get-MsDeployAuthentiocationPart -Username $Username -Password $Password)

    # create arguments for msdeploy.exe
    $msDeployArguments = @()
    $msDeployArguments += '-verb:sync'
    $msDeployArguments += '-disableLink:AppPoolExtension'
    $msDeployArguments += '-disableLink:ContentExtension'
    $msDeployArguments += '-disableLink:CertificateExtension'
    $msDeployArguments += '-allowUntrusted'
    $msDeployArguments += '-useChecksum'    
    $msDeployArguments += '-verbose'    
    $msDeployArguments += '-source:package="{0}"' -f ([IO.Path]::GetFullPath($WdpFile))    
    
    $isParamFilePresentInWdpFile = Is-ParamFilePresentInWdpFile $WdpFile
    
    if ((-not $isParamFilePresentInWdpFile) -and $WebsiteName)
    {
        $msDeployArguments += '-dest:contentPath="{0}",computerName="{1}",includeAcls=False,{2}' -f $WebsiteName, $Url, $auth
    }
    else
    {
        $msDeployArguments += '-dest:auto,computerName="{0}",includeAcls=False,{1}' -f $Url, $auth
    }


    if ($WebsiteName -and $isParamFilePresentInWdpFile)
    {
        $msDeployArguments += '-setParam:name="IIS Web Application Name",value="{0}"' -f $WebsiteName
    }

    if ($DeploySetParametersFile)
    {
        $msDeployArguments += '-setParamFile:"{0}"' -f ((Get-Item $DeploySetParametersFile).FullName) # with full path
    }

    # pokud na serveru existuje soubor app_offline.htm, nechceme ho při nasazení smazat
    # umožníme tak z venku řídit práci se souborem app_offline    
    $msDeployArguments += '-skip:objectName=filePath,skipAction=Delete,absolutePath=\\app_offline\.htm$'

    if ($CustomMsDeployArguments)
    {
        $customMsDeployArgumentsArray = [regex]::Matches($CustomMsDeployArguments, "[\""].+?[\""]|[^ ]+") | Select-Object -ExpandProperty Value
        $msDeployArguments += $customMsDeployArgumentsArray
    }

    Write-Host Publishing application... -ForegroundColor Yellow
    Run-MsDeploy -msdeployargs $msDeployArguments
    Write-Host 
}

function Publish-HavitWebsiteFileInternal {
    param(
        [string] $Url,
        [string] $Username,
        [string] $Password,
        [string] $WebsiteName,
        [string] $SourceFile,
        [string] $TargetFile
    )

    $auth = (Get-MsDeployAuthentiocationPart -Username $Username -Password $Password)
    
    # create arguments for msdeploy.exe
    $msDeployArguments =  @()
    $msDeployArguments += '-verb:sync'
    $msDeployArguments += '-enableRule:DoNotDeleteRule'
    $msDeployArguments += '-allowUntrusted'
    $msDeployArguments += '-useChecksum'    
    $msDeployArguments += '-source:contentPath="{0}"' -f ([IO.Path]::GetFullPath($SourceFile))    
    $msDeployArguments += '-dest:contentPath="{0}/{1}",computerName="{2}",includeAcls=False,{3}' -f $WebsiteName, $TargetFile, $Url, $auth

    Write-Host Uploading application offline file... -ForegroundColor Yellow
    Run-MsDeploy -msdeployargs $msDeployArguments
    Write-Host
}

function Get-MsDeployAuthentiocationPart {
    param (
        [string] $Username,
        [String] $Password
    )

    if ($Username)
    {
        return 'username="{0}",password="{1}",authType=basic' -f $Username, $Password
    }
    return "authType=ntlm"
}

function Run-MsDeploy {
    param (
        [Object[]] $MsDeployArgs,
        [bool] $WaitForFiddlerShutDown = $true,
        [bool] $WaitOnError = $true
    )

    if ($WaitForFiddlerShutDown)
    {
        Wait-FiddlerShutDown
    }

    $msdeployCommandLine = 'C:\Program Files (x86)\IIS\Microsoft Web Deploy V3\msdeploy.exe'
    $msdeployCommandLineArgs = [System.String]::Join(" ", $MsDeployArgs)

    if ($env:ShowMsDeployCommandLine -eq $true)
    {

        Write-Host $msdeployCommandLine
        Write-Host $msdeployCommandLineArgs
    }

    # pokus o lepší zobrazení výstupu v češtině
    $originalOutputEncoding = [Console]::OutputEncoding
    try
    {
        [Console]::OutputEncoding = New-Object -typename System.Text.UTF8Encoding
    }
    catch
    {
        # catching: Exception setting OutputEncoding: Neplatný popisovač.
        # NOOP
    }

    $result = $null
    if ($env:ShowMsDeploy -eq $true)
    {
        &$msdeployCommandLine $MsDeployArgs 2>&1 | Tee-Object -Variable "result"
    }
    else
    {	
        $result = &$msdeployCommandLine $MsDeployArgs 2>&1
    }

    try
    {
        [Console]::OutputEncoding = $originalOutputEncoding
    }
    catch
    {
        # catching: Exception setting OutputEncoding: Neplatný popisovač.
        # NOOP
    }
    
    if ($result)
    {
        $infos = $result | ?{$_.gettype().Name -ne "ErrorRecord"}   
        $errors = $result | ?{$_.gettype().Name -eq "ErrorRecord"}

        if ($env:ShowMsDeploy -ne $true) #jen, pokud nebylo zobrazeno z Tee-Object
        {
            if ($errors)
            {
                $errors
            }
            elseif ($infos)
            {
                $infos[-1] # poslední řádek, ale jen, když nedošlo k chybě
            }
        }

        if ($errors -and ($WaitOnError -eq $true))
        {
            Write-Host Press enter to continue...
            Read-Host            
        }

        if ($errors)
        {
            throw $errors
        }
    }
}

function Is-FiddlerRunning()
{
    $fiddler = Get-Process | Where-Object {$_.ProcessName -eq 'fiddler'}
    return ($fiddler)
}

function Wait-FiddlerShutDown()
{
    $retryInterval = 3
    if (Is-FiddlerRunning)
    {
        Write-Host "MsDeploy fails when Fiddler runs. Shut down Fiddler!" -ForegroundColor Yellow
        Start-Sleep -s $retryInterval
        while (Is-FiddlerRunning)
        {
            Write-Host "Waiting for Fiddler shutdown." -ForegroundColor Yellow
            Start-Sleep -s $retryInterval
        }
        Write-Host "Fiddler already shutdown."
    }
}

<#
.SYNOPSIS
Deploys web application using MSDeploy.

.DESCRIPTION
Deploys web application using MSDeploy.
Run msdeploy with *.SetParameters.xml file and parameters (package, url, username, password).
Never deletes any app_offline.htm file.

.PARAMETER Url
Short or comlete url to MSDeploy server, ie. "stage.havit.local" or "https://myapplication.scm.azurewebsites.net:443/MSDeploy.axd".

.PARAMETER Username
Username to MSDeploy server.

.PARAMETER Password
Password to MSDeploy server.

.PARAMETER WebsiteName
IIS WebSite name. Optional.

.PARAMETER WdpFile
Web Depoyment Package file. If not specified it tries to find *.zip file in the current folder.

.PARAMETER $DeploySetParametersFile
Name of *.SetParameters.xml files to be used.

.PARAMETER $CustomMsDeployArguments
Custom MsDeploy Arguments (to be added to msdeploy commend line).

.INPUTS
None. This function does not take input from the pipeline.

.OUTPUTS
None.

.EXAMPLE
Publish-HavitWebsitePackage
-Url https://myapplication.scm.azurewebsites.net/MSDeploy.axd
-Username MyUsername
-Password MyPassword
-DeploySetParametersFile MyApplication.SetParameters.xml

#>
function Publish-HavitWebsitePackage {
    param(
        [string] $Url,
        [string] $Username,
        [string] $Password,
        [string] $WebsiteName = $null,
        [string] $WdpFile = $null,
        [string] $DeploySetParametersFile = $null,
        [object[]] $CustomMsDeployArguments = $null
    )
	Publish-HavitWebsitePackageInternal -Url $Url -Username $Username -Password $Password -WebsiteName $WebsiteName -WdpFile $WdpFile -DeploySetParametersFile $DeploySetParametersFile -CustomMsDeployArguments $CustomMsDeployArguments
}


<#
.SYNOPSIS
Publishs (uploads) "application offline file" (app_offline.htm) to server.

.DESCRIPTION
Run msdeploy with -sync command and DoNotDeleteRule.

.PARAMETER Url
Short or comlete url to MSDeploy server, ie. "stage.havit.local" or "https://myapplication.scm.azurewebsites.net:443/MSDeploy.axd".

.PARAMETER Username
Username to MSDeploy server.

.PARAMETER Password
Password to MSDeploy server.

.PARAMETER WebsiteName
IIS WebSite name.

.PARAMETER $AppOfflineFile
Name of app_offline.htm file to upload. Optional, default value app_offline.htm.

.INPUTS
None. This function does not take input from the pipeline.

.OUTPUTS
None.

.EXAMPLE
Publish-HavitWebsiteAppOfflineFile
-Url https://myapplication.scm.azurewebsites.net/MSDeploy.axd
-Username MyUsername
-Password MyPassword

#>
function Publish-HavitWebsiteAppOfflineFile {
    param(
        [string] $Url,
        [string] $Username,
        [string] $Password,
        [string] $WebsiteName,
        [string] $AppOfflineFile = "app_offline.htm"
    )
    
    Publish-HavitWebsiteFileInternal -Url $Url -Username $Username -Password $Password -WebsiteName $WebsiteName -SourceFile $AppOfflineFile -TargetFile "app_offline.htm"
}

<#
.SYNOPSIS
Removes (deletes) "application offline file" (app_offline.htm) from server.

.DESCRIPTION
Run msdeploy with -delete command.

.PARAMETER Url
Short or comlete url to MSDeploy server, ie. "stage.havit.local" or "https://myapplication.scm.azurewebsites.net:443/MSDeploy.axd".

.PARAMETER Username
Username to MSDeploy server.

.PARAMETER Password
Password to MSDeploy server.

.PARAMETER WebsiteName
IIS WebSite name.

.INPUTS
None. This function does not take input from the pipeline.

.OUTPUTS
None.

.EXAMPLE
Publish-HavitWebsiteAppOfflineFile
-Url https://myapplication.scm.azurewebsites.net/MSDeploy.axd
-Username MyUsername
-Password MyPassword

#>
function Remove-HavitWebsiteAppOfflineFile {
    param(
        [string] $Url,
        [string] $Username,
        [string] $Password,
        [string] $WebsiteName
    )

    
    $auth = (Get-MsDeployAuthentiocationPart -Username $Username -Password $Password)
    
    # create arguments for msdeploy.exe
    $msDeployArguments = @()
    $msDeployArguments += '-verb:delete'
    $msDeployArguments += '-allowUntrusted'
    $msDeployArguments += '-dest:contentPath="{0}/app_offline.htm",computerName="{1}",includeAcls=False,{2}' -f $WebsiteName, $Url, $auth
    
    Write-Host Removing application offline file... -ForegroundColor Yellow
    Run-MsDeploy -msdeployargs $msDeployArguments
    Write-Host 
}

function Publish-HavitWebsitePackageWithAppOfflineFile {
    param (
        [string] $Url,
        [string] $Username,
        [string] $Password,
        [string] $WebsiteName,
        [string] $AppOfflineFile = "app_offline.htm",
        [string] $WdpFile = $null,
        [string] $DeploySetParametersFile,
        [object[]] $CustomMsDeployArguments = $null,
        [bool] $NoWait = $false
    )

    Publish-HavitWebsiteAppOfflineFile -Url $Url -Username $Username -Password $Password -WebsiteName $WebsiteName -AppOfflineFile $AppOfflineFile
    Publish-HavitWebsitePackage -Url $Url -Username $Username -Password $Password -WebsiteName $WebsiteName -WdpFile $WdpFile -DeploySetParametersFile $DeploySetParametersFile -CustomMsDeployArguments $CustomMsDeployArguments

    if ($NoWait -eq $false)
    {
        Write-Host Application is in offline mode. -ForegroundColor Yellow
        Write-Host Press enter to continue - application will be set online... -ForegroundColor Yellow
        Read-Host
    }

    Remove-HavitWebsiteAppOfflineFile -Url $Url -Username $Username -Password $Password -WebsiteName $WebsiteName
}


function Backup-HavitWebsiteToPackage {
    param (
        [string] $Url,
        [string] $Username,
        [string] $Password,
        [string] $WebsiteName,
        [string] $BackupLocation,
        [string] $BackupFilenameSegment,
        [object[]] $CustomMsDeployArguments = $null

    )    

    $auth = (Get-MsDeployAuthentiocationPart -Username $Username -Password $Password)
    
    if (!$BackupFilenameSegment)
    {
        $BackupFilenameSegment = $WebsiteName
    }
    $backupPackageFile = "backup-{0}-{1}.zip" -f $BackupFilenameSegment, [System.DateTime]::Now.ToString("yyyy-MM-dd-HH-mm-ss")  

    if (!$BackupLocation)
    {
        $BackupLocation = (Get-Location).ProviderPath        
    }
    $backupPackageFullPath = [System.IO.Path]::Combine($BackupLocation, $backupPackageFile)

    # create arguments for msdeploy.exe
    $msDeployArguments =  @()
    $msDeployArguments += '-verb:sync'
    $msDeployArguments += '-disableLink:AppPoolExtension'
    $msDeployArguments += '-disableLink:ContentExtension'
    $msDeployArguments += '-disableLink:CertificateExtension'
    $msDeployArguments += '-allowUntrusted'    
    $msDeployArguments += '-source:iisApp="{0}",computerName="{1}",{2}' -f $WebsiteName, $Url, $auth    
    $msDeployArguments += '-dest:package="{0}"' -f $backupPackageFullPath
    if ($CustomMsDeployArguments)
    {        
        $msDeployArguments += $CustomMsDeployArguments
    }

    Write-Host Backing up website to package... -ForegroundColor Yellow
    Run-MsDeploy -msdeployargs $msDeployArguments
    Write-Host 
}

Export-ModuleMember -Function Confirm-HavitDeployment
Export-ModuleMember -Function Find-HavitPackage
Export-ModuleMember -Function Backup-HavitWebsiteToPackage
Export-ModuleMember -Function Publish-HavitWebsitePackage
Export-ModuleMember -Function Publish-HavitWebsiteAppOfflineFile
Export-ModuleMember -Function Remove-HavitWebsiteAppOfflineFile
Export-ModuleMember -Function Publish-HavitWebsitePackageWithAppOfflineFile
