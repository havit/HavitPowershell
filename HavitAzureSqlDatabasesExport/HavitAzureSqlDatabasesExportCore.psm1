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
    $databases = $allDatabases | Where-Object { $_.Edition -ne "System" } | Where-Object { $_.Edition -ne "None" } | Sort-Object -Property DatabaseName

    #EXPORT DATABASES
    $exportFailed = $false
    
    foreach ($database in $databases)
    { 
        if ($database.DatabaseName -match '_d{4}-\d{2}-\d{2}T\d{2}-\d{2}Z$')
        {
            Write-Host "Skipping export $($database.DatabaseName) database."
        }
        
        try
        {
            Export-SingleAzureSqlDatabase -database $database
        }
        catch
        {
            Write-Error "Caught: $($_.Exception.Message)"
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
        $exportRequest = Start-SingleAzureSqlDatabaseExport -database $database
        # PRIVATE LINK ACCEPTANCE
        Accept-SingleSqlDatabaseExportPrivateLinkEndpoints -database $database

        # ELASTIC POOL - OVERLOAD PROTECTION
        # export databázi nemálo vytíží
        # tam, kde není elastic pool, s tím mnoho nenaděláme (můžeme povýšit), prostě musíme chvíli exportu přežít
        # tam, kde je elastic pool, můžeme *nezpůsobit* zátěž paralelní zálohou všech databází, čímž by měl zůstat výkový prostor pro běh aplikací        
        if ($database.ElasticPoolName) # not null, not empty
        {        
            Wait-SingleAzureSqlDatabaseExportCompletion -exportRequest $exportRequest
        }
    }
    catch [RetryException]
    {        
        Write-Error $exception.Message
        Write-Host "Waiting 10 minutes..."
        Start-Sleep -Seconds 600 # 10 minutes
        if ($depth -lt 5) # max attempts per database
        {
        }
        else
        {
            throw $_.Exception
        }
    }
}

function Start-SingleAzureSqlDatabaseExport
{
    param (
        [Microsoft.Azure.Commands.Sql.Database.Model.AzureSqlDatabaseModel] $database
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

    Write-Host "Starting export $($database.DatabaseName) database to $bacpacName..."

    $exportRequest = New-AzSqlDatabaseExport @exportRequestParams

    if (-not $exportRequest)
    {
        Write-Warning "Failed."
        Write-Host "Waiting 120 seconds..."
        Start-Sleep -Second 120

        Write-Host "Starting export $($database.DatabaseName) database to $bacpacName..."
        $exportRequest = New-AzSqlDatabaseExport @exportRequestParams
    }

    if ($exportRequest)
    {
        Write-Host "Started export $($database.DatabaseName) database to $($exportRequest.StorageUri)."
    }
    else
    {
        throw "Starting export $($database.DatabaseName) failed."
    }

    return $exportRequest
}

function Accept-SingleSqlDatabaseExportPrivateLinkEndpoints
{
    param (
        [Microsoft.Azure.Commands.Sql.ImportExport.Model.AzureSqlDatabaseImportExportBaseModel] $exportRequest
    )

    if ($dbServerResourceIdForPrivateLink)
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

        $counter = 1
        $sqlServerPrivateEndpointConnection = Get-AzPrivateEndpointConnection -PrivateLinkResourceId $DbServerResourceIdForPrivateLink | Where-Object { $_.Name.StartsWith('ImportExportPrivateLink_SQL') } | Where-Object {$_.PrivateLinkServiceConnectionState.Status -eq "Pending" }
        while (!$sqlServerPrivateEndpointConnection)
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
        while (!$storagePrivateEndpointConnection)
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