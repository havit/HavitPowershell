$sleepDurationSeconds = 15
$waitSingleAzureSqlDatabaseExportCompletionMinutes = 120

function Export-AzureSqlDatabases
{
    param($DbServerName,
        $DbServerResourceGroupName,
        $DbServerResourceIdForPrivateLink,
        $DbServerAdministratorUsername,
        [SecureString] $DbServerAdministratorPassword,
        $StorageAccountName,
        $StorageContainerName,
        $StorageKey,
        $StorageResourceIdForPrivateLink
    )

    #REMOVE PREVIOUS BLOBS

    Write-Host 'Retrieving storage account...'
    # using storage key - does not need "access to subscription"
    $storageCtx = New-AzStorageContext -StorageAccountName $StorageAccountName -StorageAccountKey $StorageKey

    Write-Host "Deleting blobs previously exported from $DbServerName..."
    # deleting only files with dbServerName prefix (upper case)
    Get-AzStorageBlob -Container $StorageContainerName -Context $storageCtx -Prefix $DbServerName.ToUpper() | Remove-AzStorageBlob

    #LIST (AND FILTER) DATABASES (from the current subscription)

    Write-Host "Listing databases..."
    $allDatabases = Get-AzSqlDatabase -ServerName $DbServerName.ToLower() -ResourceGroupName $DbServerResourceGroupName    
    $databases = $allDatabases `
        | Where-Object { $_.Edition -ne "System" } `
        | Where-Object { $_.Edition -ne "None" } `
        | Where-Object { $_.DatabaseName -notmatch '_\d{4}-\d{2}-\d{2}T\d{2}-\d{2}Z$' } `
        | Sort-Object -Property DatabaseName
    Write-Host "Found $($databases.Count) database(s) to export."

    #EXPORT DATABASES
    $exportFailed = $false
    
    foreach ($database in $databases)
    { 
        try
        {
            Export-SingleAzureSqlDatabase -database $database
        }
        catch
        {
            Write-Error "Caught exception: $($_.Exception.Message)" -ErrorAction Continue
            $exportFailed = $true
        }
    }
    
    if ($exportFailed -eq $true)
    {
        throw "Database export failed."
    }
}


function Export-SingleAzureSqlDatabase
{
    param (
        [Microsoft.Azure.Commands.Sql.Database.Model.AzureSqlDatabaseModel] $database,
        [int] $depth = 0
    )

    try
    {
        # spustíme export databáze
        # pokud se spuštění nepodaří (protože již běží, atp., je vrácena null hodnota)
        # pokud se spuštění nepodaří z jiného důvodu, je vyhozena výjimka
        $exportRequest = Start-SingleAzureSqlDatabaseExport -database $database
        
        # Schválíme private endpointy (bez ohledu na konkrétní databázi)
        # $exportRequest slouží k možnému čekání na založení infrastruktury je schválení
        # Pokud byl ale spuštěn export dříve, nemáme $exportRequest, ale metoda se s tím musí vypořádat (schvaluje bez čekání) - to může být užitečné, pokud byl export spuštěn dříve a stále čeká na endpointy        
        Accept-SingleSqlDatabaseExportPrivateLinkEndpoints -exportRequest $exportRequest

        # ELASTIC POOL - OVERLOAD PROTECTION
        # export databázi nemálo vytíží
        # tam, kde není elastic pool, s tím mnoho nenaděláme (můžeme povýšit), prostě musíme chvíli exportu přežít
        # tam, kde je elastic pool, můžeme *nezpůsobit* zátěž paralelní zálohou všech databází, čímž by měl zůstat výkový prostor pro běh aplikací        
        # čekat ale můžeme jen tehdy, pokud máme $exportRequest
        # čas od času se při čekání dozvíme, že export selhal, pak je vyhozena RetryException, což řešíme novým čekáním a znovuspuštěním exportu
        if ($exportRequest -and $database.ElasticPoolName) # not null, not empty
        {
            Wait-SingleAzureSqlDatabaseExportCompletion -exportRequest $exportRequest
        }
    }
    catch [RetryException]
    {
        # pokdu došlo k chybě, ze které se máme pokusit zotavit, počkáme chvilku a zkusíme export znovu (ale ne donekonečna)
        Write-Error $exception.Message -ErrorAction Continue
        Write-Host "Waiting 10 minutes..."
        Start-Sleep -Seconds 600 # 10 minutes
        if ($depth -lt 5) # max attempts per database
        {
            Export-SingleAzureSqlDatabase -database $database -depth ($depth + 1)
        }
        else
        {
            # pokud jsme se dostali za povolení množství znovuopakování, vyhodíme nakonec výjimku
            throw $_.Exception
        }
    }
}

function Start-SingleAzureSqlDatabaseExport
{
    param (
        [Microsoft.Azure.Commands.Sql.Database.Model.AzureSqlDatabaseModel] $database,
        [int] $depth = 0
    )

    $storageUri = "https://$StorageAccountName.blob.core.windows.net/$StorageContainerName/" # musí končit limítkem
    $bacpacName = $DbServerName.ToUpper() + '-' + $database.DatabaseName + '.bacpac'
    $storageBlobUri = $StorageUri + $bacpacName

    $exportRequestParams = @{
        ResourceGroupName                   = $DbServerResourceGroupName
        ServerName                          = $DbServerName.ToLower()
        DatabaseName                        = $database.DatabaseName
        StorageKeyType                      = "StorageAccessKey"
        StorageKey                          = $StorageKey
        StorageUri                          = $storageBlobUri
        UseNetworkIsolation                 = $true
        AdministratorLogin                  = $DbServerAdministratorUsername
        AdministratorLoginPassword          = $DbServerAdministratorPassword
        StorageAccountResourceIdForPrivateLink = $StorageResourceIdForPrivateLink
        SqlServerResourceIdForPrivateLink   = $DbServerResourceIdForPrivateLink
    }

    # zastavení rekurze
    if ($depth -eq 3)
    {
        throw "Starting export $($database.DatabaseName) failed."
    }

    Write-Host "Starting export $($database.DatabaseName) database to $bacpacName..."

    try
    {
        # Spustíme export databáze a vrátíme objekt reprezentující tento export
        # ErrorAction: proměníme non-terminating errors na terminating (pro možnost zachycení catch)
        $exportRequest = New-AzSqlDatabaseExport @exportRequestParams -ErrorAction Stop
        Write-Host "Started export $($database.DatabaseName) database to $($exportRequest.StorageUri)."
        return $exportRequest
    }
    catch
    {
        Write-Warning $_.Exception.Message

        if ($_.Exception.Message.Contains('There is an import or export operation in progress on the database'))
        {
            Write-Host "Export $($database.DatabaseName) already started."
            # pokud již import běží, nebudeme další spouštět
            return $null
        }

        Write-Warning "Failed."
        Write-Host "Waiting 120 seconds..."
        Start-Sleep -Second 120

        # v rekurzi zkusíme spustit export znovu
        return Start-SingleAzureSqlDatabaseExport -database $database -depth ($depth + 1)
    }
}

function Accept-SingleSqlDatabaseExportPrivateLinkEndpoints
{
    param (
        [Microsoft.Azure.Commands.Sql.ImportExport.Model.AzureSqlDatabaseImportExportBaseModel] $exportRequest
    )

    if ($dbServerResourceIdForPrivateLink)
    {
        # počkáme na založení infrastruktury
        if ($exportRequest)
        {
            $counter = 1
            $exportRequestStatus = Get-AzSqlDatabaseImportExportStatus $exportRequest.OperationStatusLink                
            while ($exportRequestStatus.PrivateEndpointRequestStatus.Count -eq 0)
            {
                if ($counter -ge 12)
                {
                    throw "Private link information not retrieved."
                }
                $counter += 1
                Write-Host "Waiting for private link connection info..."
                Start-Sleep -Seconds 15
                $exportRequestStatus = Get-AzSqlDatabaseImportExportStatus $exportRequest.OperationStatusLink
            }
        }

        $counter = 1
        $sqlServerPrivateEndpointConnection = Get-AzPrivateEndpointConnection -PrivateLinkResourceId $DbServerResourceIdForPrivateLink | Where-Object { $_.Name.StartsWith('ImportExportPrivateLink_SQL') } | Where-Object {$_.PrivateLinkServiceConnectionState.Status -eq "Pending" }
        while ((-not $sqlServerPrivateEndpointConnection) -and $exportRequest) #$exportRequest: opakujeme jen, pokud jsme právě spustili export databáze (dřívější exporty neopakujeme)        {
        {
            if ($counter -ge 12)
            {
                throw "Azure SQL Server private link not available."
            }
            $counter += 1
            Write-Host "Waiting for Azure SQL Server private link connection info..."
            Start-Sleep -Seconds 15
            $sqlServerPrivateEndpointConnection = Get-AzPrivateEndpointConnection -PrivateLinkResourceId $DbServerResourceIdForPrivateLink | Where-Object { $_.Name.StartsWith('ImportExportPrivateLink_SQL') } | Where-Object {$_.PrivateLinkServiceConnectionState.Status -eq "Pending" }
        }

        $counter = 1
        $storagePrivateEndpointConnection = Get-AzPrivateEndpointConnection -PrivateLinkResourceId $StorageResourceIdForPrivateLink | Where-Object {$_.PrivateLinkServiceConnectionState.Status -eq "Pending" }
        while ((-not $storagePrivateEndpointConnection) -and $exportRequest)
        {
            if ($counter -ge 12)
            {
                throw "Azure Storage private link not available."
            }
            $counter += 1
            Write-Host "Waiting for Storage private link connection info..."
            Start-Sleep -Seconds 15
            $storagePrivateEndpointConnection = Get-AzPrivateEndpointConnection -PrivateLinkResourceId $StorageResourceIdForPrivateLink | Where-Object {$_.PrivateLinkServiceConnectionState.Status -eq "Pending" }
        }

        if ($sqlServerPrivateEndpointConnection)
        {
            Write-Host "Accepting SQL Server private link..."
            Approve-AzPrivateEndpointConnection -ResourceId $sqlServerPrivateEndpointConnection.Id
        }

        if ($storagePrivateEndpointConnection)
        {
            Write-Host "Accepting Storage private link..."
            Approve-AzPrivateEndpointConnection -ResourceId $storagePrivateEndpointConnection.Id
        }
    }    
}

function Wait-SingleAzureSqlDatabaseExportCompletion
{
    param (
        [Microsoft.Azure.Commands.Sql.ImportExport.Model.AzureSqlDatabaseImportExportBaseModel] $exportRequest
    )

    # kolikrát nejvýše můžeme zkoušet dokončení (s odstupem $sleepDurationSeconds sekund)
    $iterations = $waitSingleAzureSqlDatabaseExportCompletionMinutes * 60 / $sleepDurationSeconds

    $counter = 0
    do
    {        
        if ($counter -ge $iterations)
        {
            Write-Warning "Timeout reached during database $($exportRequest.DatabaseName) export."
            break
        }

        $counter += 1

        Start-Sleep -Second $sleepDurationSeconds
        $exportRequestStatus = Get-AzSqlDatabaseImportExportStatus -OperationStatusLink $exportRequest.OperationStatusLink
        
        if ($exportRequestStatus.ErrorMessage)
        {
            throw [RetryException]::new($exportStatus.ErrorMessage)
        }
        Write-Host "  $($counter): Database $($database.DatabaseName) export status is $($exportRequestStatus.Status) ($($exportRequestStatus.StatusMessage))."                        
    } while ($exportRequestStatus.Status -eq "InProgress")
}

class RetryException : System.Exception
{
    RetryException($Message) : base($Message)
    {
    }
}