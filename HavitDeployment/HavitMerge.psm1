﻿
#inspirace: https://gist.github.com/Badabum/a61e49019fb96bef4d5d9712e07b2af7

function Join-JsonValues
{
    param($BaseJson, $DiffJson)
        
    # Do BaseJson "přimerguje" hodnoty z DiffJson. Hodnoty přebývající v DiffJson oproti BaseJson, se do výsledu nedostanou.
    if ($null -ne $BaseJson -and $BaseJson.GetType().Name -eq "PSCustomObject" -and $DiffJson.GetType().Name -eq "PSCustomObject")
    {
        foreach ($Property in $BaseJson | Get-Member -type NoteProperty, Property)
        {
            # Pokud existuje objekt v Diff Jsonu, tak ho chceme nastavit, když je null
            if ($null -eq $DiffJson.$($Property.Name) -and $DiffJson.PSObject.Properties.name -match $Property.Name)
            {
                $BaseJson.$($Property.Name) = $null;
                continue;
            }

            if ($null -eq $DiffJson.$($Property.Name))
            {
                continue;
            }
            $BaseJson.$($Property.Name) = Join-JsonValues -BaseJson $BaseJson.$($Property.Name) $DiffJson.$($Property.Name)
        }
    }
    else
    {
        $BaseJson = $DiffJson;
    }
    return , $BaseJson # comma ensures NOT unwrapping single-item arrays (otherwise array is returned but the unwrapped single item is consumed)
}

function Add-PropertyRecurse($source, $toExtend)
{
    # Do source "přimerguje" hodnoty z extend, které v source ještě nejsou.    
    # Šito na míru pro použití v Merge-JsonObjects, tedy že před volání této metody je zavoláno Join-Objects, která nejprve source rozšíří o společné hodnoty.
    # Realizováno tak, že vlastně source (na který byly nejprve aplikovány společné hodnoty) dostane do extendu.
    if ($source.GetType().Name -eq "PSCustomObject")
    {
        foreach ($Property in $source | Get-Member -type NoteProperty, Property)
        {        
            if ($null -eq $toExtend.$($Property.Name))
            {
                $toExtend | Add-Member -MemberType NoteProperty -Value $source.$($Property.Name) -Name $Property.Name
            }
            else
            {
                $toExtend.$($Property.Name) = Add-PropertyRecurse $source.$($Property.Name) $toExtend.$($Property.Name)
            }
        }
    }
    return $toExtend
}

function Test-ForExcessiveProperty
{
    param($Prefix, $BaseJson, $DiffJson)

    # zkontroluje, zda BaseJson obsahuje všechny vlastnosti definované v DiffJson.
    # Přebývající vlastnosti vypisuje jako warning.
    # Vrací true, pokud je nalezena přebývající vlastnost ($hasError).

    $hasError = $false;

    if ($null -eq $DiffJson)
    {
        #end recursion
        return
    }

    if ($DiffJson.GetType().Name -eq "PSCustomObject")
    {
        foreach ($Property in $DiffJson | Get-Member -type NoteProperty, Property)
        {   
            # pokud hodnota je null a zároveň neexistuje v BaseJson, tak je to hodnota navíc
            # Musíme kontrolovat, zda hodnota v BaseJson existuje, protože $null může schválně být uměle nastavena
            if ($null -eq $BaseJson.$($Property.Name) -and (-Not($BaseJson.PSObject.Properties.name -match $Property.Name)))
            {
                Write-Warning ("Excesive value " + ($Prefix + $Property.Name))
                $hasError = $true
            }
            else
            {
                if (Test-ForExcessiveProperty -Prefix ($Prefix + $Property.Name + ".") -BaseJson $BaseJson.$($Property.Name) -DiffJson $DiffJson.$($Property.Name))
                {
                    $hasError = $true
                } 
            }
        }
    }
 
    return $hasError
}

function Merge-JsonObjects
{
    param(
        [Parameter(Mandatory = $true)]
        [PsCustomObject] $BaseJson, 

        [Parameter(Mandatory = $true)]
        [PsCustomObject] $DiffJson
    )

    $merged = Join-JsonValues -BaseJson $BaseJson -DiffJson $DiffJson       

    # nechceme, aby hodnoty přebývající v DiffJson a které neexistují v BaseJson se dostaly do BaseJson. Chceme je oznámit, jako chybu.
    #$extended = Add-PropertyRecurse $BaseJson $DiffJson
    #return $extended
    
    if (Test-ForExcessiveProperty -Prefix "" -BaseJson $BaseJson -DiffJson $DiffJson)
    {
        throw "Diff json contains excessive values, see warnings."
    }

    return $merged
}


function Remove-JsonComments
{
    param (
        [Parameter(ValueFromPipeline)]
        [string] $jsonString
    )

    # replace the escaped double quote because the following regex does not support it
    # backslash is just a backslash
    # back quote is an escape character
    $jsonString = $jsonString.Replace("\`"", "!☢!☢!☢!")

    # remove comments (does not support escaped double quote)
    # source: https://stackoverflow.com/a/59264162
    $jsonString = $jsonString -replace '(?m)(?<=^([^"]|"[^"]*")*)//.*' -replace '(?ms)/\*.*?\*/' 
    
    $jsonString = $jsonString.Replace("!☢!☢!☢!", "\`"") # replace the escaped double quote back
    return $jsonString
}


<#
.SYNOPSIS
Merges a diff json file to a target json file.

.DESCRIPTION
Merges a diff json file to a target json file.
All properties in diff file must be present in the target json file. Otherwise exception is thrown.
Json comments are removed (comments are not compatible with Powershell 5.x).
Json formatting is ugly.

.PARAMETER DiffJsonPath
The diff which is merged into base json file.

.PARAMETER TargetJsonPath
Target json file into which the diff file is merged.

.INPUTS
None. This function does not take input from the pipeline.

.OUTPUTS
None.
#>
function Merge-JsonFileToJsonFile
{
    param (
        [Parameter(Mandatory = $true)]
        [String] $DiffJsonPath,

        [Parameter(Mandatory = $true)]
        [String] $TargetJsonPath
    )
    
    Merge-JsonFiles -BaseJsonPath $TargetJsonPath -DiffJsonPath $DiffJsonPath -TargetJsonPath $TargetJsonPath 
}

<#
.SYNOPSIS
Merges two json file to a target json file.

.DESCRIPTION
Merges two json file to a target json file.
All properties in diff file must be present in the base json file. Otherwise exception is thrown.
The target json file can be same with base file.
Json comments are removed (comments are not compatible with Powershell 5.x).
Json formatting is ugly.

.PARAMETER BaseJsonPath
Base json file into which the diff is merged.

.PARAMETER DiffJsonPath
The diff which is merged into base json file.

.PARAMETER TargetJsonPath
Target json file where the merged json is saved. Can be same with BaseJsonPath.

.INPUTS
None. This function does not take input from the pipeline.

.OUTPUTS
None.
#>
function Merge-JsonFiles
{
    param (

        [Parameter(Mandatory = $true)]
        [String] $BaseJsonPath,
        
        [Parameter(Mandatory = $true)]
        [String] $DiffJsonPath,

        [Parameter(Mandatory = $true)]
        [String] $TargetJsonPath
    )
    
    Write-Host "Reading and parsing $diffJsonPath..."
    $diffJson = Get-Content $diffJsonPath -Raw | Remove-JsonComments | ConvertFrom-Json
    Write-Host "Reading and parsing $baseJsonPath..."
    $baseJson = Get-Content $baseJsonPath -Raw | Remove-JsonComments | ConvertFrom-Json
            
    # sloučíme json dokumenty v paměti
    Write-Host "Merging..."
    $mergedJson = Merge-JsonObjects -BaseJson $baseJson -DiffJson $diffJson    

    # zapíšeme výsledek
    Write-Host "Saving merged json..."
    $mergedJson | ConvertTo-Json -Depth 20 | Out-File -FilePath $TargetJsonPath -Encoding utf8
}

<#
.SYNOPSIS
Merges a diff json file to a target json file in a zip archive (can be also a web deploy package).

.DESCRIPTION
Merges a diff json file to a target json file in a zip archive (can be also a web deploy package).
All properties in diff file must be present in the base json file. Otherwise exception is thrown.
The target json file can be same with base file.
Json comments are removed (comments are not compatible with Powershell 5.x).
Json formatting is ugly.

.PARAMETER DiffJsonPath
The diff which is merged into a base json file.

.PARAMETER TargetZipPath
The zip file which containing a base json into which a diff json file is merged.

.PARAMETER TargetJsonPath
Target json file in the zip path into which a diff file json is merged.
Can NOT contain path, must be just a file name.
Can be located at any folder in the archive. Be careful with webjob parametrization.

.INPUTS
None. This function does not take input from the pipeline.

.OUTPUTS
None.
#>
function Merge-JsonFileToJsonZipFile
{
    param (
        [Parameter(Mandatory = $true)]
        [String] $DiffJsonPath,

        [Parameter(Mandatory = $true)]
        [String] $TargetZipPath,

        [Parameter(Mandatory = $true)]
        [String] $ZipFile
    )
    
    Add-Type -assembly  System.IO.Compression
    Add-Type -assembly  System.IO.Compression.FileSystem

    $zip = [System.IO.Compression.ZipFile]::Open($TargetZipPath, [System.IO.Compression.ZipArchiveMode]::Update)
    
    $files = $zip.Entries.Where( { $_.name -ieq $ZipFile })
    $brotliFiles = $zip.Entries.Where( { $_.name -ieq ($ZipFile + '.br') }) # pokud je vedle souboru ještě komprimovaný soubor, potřebujeme jej aktualizovat (prozatím jej odstraníme)
    $gzipFiles = $zip.Entries.Where( { $_.name -ieq ($ZipFile + '.gz') }) # pokud je vedle souboru ještě komprimovaný soubor, potřebujeme jej aktualizovat (prozatím jej odstraníme)
   
    if (!$files)
    {
        throw "No $ZipFile file found in $TargetZipPath."
    }
    
    foreach ($file in $files)
    {
        Write-Host "Updating $($file.FullName) in $TargetZipPath"

        $streamReader = [System.IO.StreamReader]($file).Open()
        $jsonText = $streamReader.ReadToEnd()
        $streamReader.Close()
               
        #uložit do tempu
        $jsonTempFile = [System.IO.Path]::GetTempPath() + [System.IO.Path]::GetRandomFileName()
        $jsonText | Out-File -FilePath $jsonTempFile -Encoding utf8
        
        Merge-JsonFileToJsonFile -TargetJsonPath $jsonTempFile -DiffJsonPath $DiffJsonPath         

        $merged = Get-Content $jsonTempFile -Raw

        $fileStream = [System.IO.StreamWriter]($file).Open()
        $fileStream.BaseStream.SetLength(0)
        $fileStream.Write($merged)
        $fileStream.Flush()
        $fileStream.Close()
        
        $file.LastWriteTime = [DateTimeOffset]::Now
        
        #smazat z tempu
        Remove-Item $jsonTempFile
    }

    foreach ($brotliFile in $brotliFiles)
    {
        Write-Host "Deleting $($brotliFile.Name) from $TargetZipPath"
        $brotliFile.Delete()
    }

    foreach ($gzipFile in $gzipFiles)
    {
        Write-Host "Deleting $($gzipFile.Name) from $TargetZipPath"
        $gzipFile.Delete()
    }

    # Write the changes and close the zip file
    $zip.Dispose()   
}

<#
.SYNOPSIS
Finds all *.Environment.json and merges them into appropriate *.json file in ZIP/WDP file.

.DESCRIPTION
In target folder finds all ZIP/WDP files recursively.
For every zip files finds *.Environment.json file and merges it to appropriate *.json file (the same without Envinroment).

.PARAMETER TargetFolder
Target folder to scan for ZIP/WDP files recursively.

.PARAMETER Envinroment
Envinroment name to find configuration files.

.INPUTS
None. This function does not take input from the pipeline.

.OUTPUTS
None.
#>
Function Merge-ConfigurationJsonFilesToZipFileAutomatically
{
    param (
        [Parameter(Mandatory)]
        [string] $TargetFolder,
        
        [Parameter(Mandatory)]
        [string] $Environment
    )

    $zipFiles = Get-ChildItem -Path $TargetFolder -Filter *.zip -Recurse

    $configurationFilePattern = "*." + $Environment + ".json"
    $environmentPatternToReplace = "\." + $Environment + "\."

    foreach ($zip in $zipFiles)
    {
        Write-Debug ("Processing " + $zip.FullName)
        $configurationFiles = Get-ChildItem -Path $zip.Directory.FullName -Filter $configurationFilePattern
        foreach ($configurationFile in $configurationFiles)
        {
            $zipConfigurationFile = $configurationFile.Name -Replace $environmentPatternToReplace, "."
            Write-Debug ("Merging " + $configurationFile.FullName + " to " + $zipConfigurationFile)
            Merge-JsonFileToJsonZipFile -DiffJsonPath $configurationFile.FullName -TargetZipPath $zip.FullName -ZipFile $zipConfigurationFile
        }
    }
}