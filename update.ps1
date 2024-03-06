#################################################
# HelloID-Conn-Prov-Target-Eduarte-Student-update
#
# Version: 1.0.1
#################################################
# Initialize default values
$config = $configuration | ConvertFrom-Json
$p = $person | ConvertFrom-Json
$aRef = $AccountReference | ConvertFrom-Json

$success = $false
$auditLogs = [System.Collections.Generic.List[PSCustomObject]]::new()

# Enable TLS1.2
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

# Set debug logging
switch ($($config.IsDebug)) {
    $true { $VerbosePreference = 'Continue' }
    $false { $VerbosePreference = 'SilentlyContinue' }
}

#region functions
function Resolve-Eduarte-StudentError {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [object]
        $ErrorObject
    )
    process {
        $httpErrorObj = [PSCustomObject]@{
            ScriptLineNumber = $ErrorObject.InvocationInfo.ScriptLineNumber
            Line             = $ErrorObject.InvocationInfo.Line
            ErrorDetails     = $ErrorObject.Exception.Message
            FriendlyMessage  = $ErrorObject.Exception.Message
        }
        # Todo: The error message may need to be neatened for the friendlyerror message
        if ($ErrorObject.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') {
            $httpErrorObj.ErrorDetails = $ErrorObject.ErrorDetails.Message
            $httpErrorObj.FriendlyMessage = $ErrorObject.ErrorDetails.Message
        }
        elseif ($ErrorObject.Exception.GetType().FullName -eq 'System.Net.WebException' -and (-not [string]::IsNullOrEmpty($ErrorObject.Exception.Response))) {
            $streamReaderResponse = [System.IO.StreamReader]::new($ErrorObject.Exception.Response.GetResponseStream()).ReadToEnd()
            if ( $streamReaderResponse ) {
                $httpErrorObj.ErrorDetails = $streamReaderResponse
                $httpErrorObj.FriendlyMessage = $streamReaderResponse
            }
        }
        Write-Output $httpErrorObj
    }
}

function Add-XmlElement {
    [CmdletBinding()]
    param (
        [Parameter(
            Mandatory,
            ValueFromPipeline = $True,
            Position = 0)]
        [System.Xml.XmlElement]
        $XmlParentDocument,

        [Parameter(Mandatory)]
        [string]
        $ElementName,

        [Parameter(Mandatory)]
        [string]
        [AllowEmptyString()]
        $ElementValue
    )
    process {
        try {
            $child = $XmlParentDocument.OwnerDocument.CreateElement($ElementName)
            $null = $child.InnerText = "$ElementValue"
            $null = $XmlParentDocument.AppendChild($child)
        }
        catch {
            $PSCmdlet.ThrowTerminatingError($_)
        }
    }
}
#endregion

try {
    if ([string]::IsNullOrEmpty($($aRef))) {
        throw 'The account reference could not be found'
    }

    # Account mapping
    $account = [PSCustomObject]@{
        ExternalId   = $p.ExternalId
        UserName     = $p.Accounts.ActiveDirectory.samaccountname
        Contactgegeven = @{
            Contactgegeven = $p.Accounts.ActiveDirectory.mail
            soort = $config.ContactgegevenSoort
            naam = $config.contactgegevenNaam
        }
    }    

    # Get Student XML call
    [xml]$getStudent = '<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns:api="http://api.algemeen.webservices.eduarte.topicus.nl/">
        <soapenv:Header/>
        <soapenv:Body>
        <api:getDeelnemer>
            <!--Optional:-->
            <apiSleutel>?</apiSleutel>
            <deelnemernummer>?</deelnemernummer>
        </api:getDeelnemer>
        </soapenv:Body>
    </soapenv:Envelope>
    '

    $getStudent.Envelope.Body.getDeelnemer.apiSleutel = $config.apiKey
    $getStudent.Envelope.Body.getDeelnemer.deelnemernummer = $account.ExternalId

    $splatGetStudent = @{
        Uri             = "$($config.BaseUrl.TrimEnd('/'))/services/api/algemeen/deelnemers" 
        Method          = 'POST'
        Body            = $getStudent.InnerXml
        ContentType     = 'text/xml; charset=utf-8'
        UseBasicParsing = $true
    }
    $rawResponse = Invoke-RestMethod @splatGetStudent -Verbose:$true

    $responseStudent = ([xml]$rawResponse).Envelope.body.getDeelnemerResponse.deelnemer

    # Verify if the account must be updated
    # Todo change update check to your needs
    # Todo: Check if the email adres can be found in the [contactgegevens]
    $propertiesChanged = $false
    $currentMailProperty = ($responseStudent.contactgegevens.contactgegeven | where-object { $_.soort.code -eq $account.Contactgegeven.soort }).contactgegeven
    Write-Verbose -Verbose "$($currentMailProperty)"
    if (($responseStudent.gebruikersNaam -ne $account.username) -or ($currentMailProperty -ne $account.Contactgegeven.contactgegeven) -or ((-not [string]::IsNullOrEmpty($account.Contactgegeven.contactgegeven)) -and ($currentMailProperty -ne $account.Contactgegeven.contactgegeven))) {
        $propertiesChanged = $true
    }

    if ($propertiesChanged) {
        $action = 'Update'
        $dryRunMessage = "Update Eduarte-Student account for: [$($p.DisplayName)] will be executed during enforcement"
    }
    elseif ((-not ($propertiesChanged) -And ($responseStudent))) {
        $action = 'NoChanges'
        $dryRunMessage = "No changes will be made to the account during enforcement"
    }
    elseif ($null -eq $responseStudent) {
        $action = 'NotFound'
        $dryRunMessage = "Eduarte-Student account for: [$($p.DisplayName)] not found. Possibly deleted"
    }

    # Add an auditMessage showing what will happen during enforcement
    if ($dryRun -eq $true) {
        write-warning "[DRYRUN] $dryRunMessage"

    }
    switch ($action) {
        'Update' {
            [xml]$setStudent = '<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns:api="http://api.algemeen.webservices.eduarte.topicus.nl/">
                    <soapenv:Header/>
                    <soapenv:Body>
                    <api:updateContactgegevens>
                        <apiSleutel>?</apiSleutel>
                        <deelnemerNummer>?</deelnemerNummer>
                        <contactgegeven>
                            <contactgegeven>?</contactgegeven>
                            <soort>
                                <code>?</code>
                                <naam>?</naam>
                            </soort>
                            <geheim>false</geheim>
                        </contactgegeven>
                    </api:updateContactgegevens>
                    </soapenv:Body>
                </soapenv:Envelope>'



            $currentMailProperty = ($responseStudent.contactgegevens.contactgegeven | where-object { $_.soort.code -eq $account.contactgegeven.soort }).contactgegeven

            $setStudent.envelope.body.updateContactgegevens.apiSleutel = "$($config.ApiKey)"
            $setStudent.envelope.body.updateContactgegevens.deelnemernummer = "$($account.ExternalId)"
            $setStudent.envelope.body.updateContactgegevens.contactgegeven.contactgegeven = $account.Contactgegeven.Contactgegeven
            $setStudent.envelope.body.updateContactgegevens.contactgegeven.soort.code = $account.contactgegeven.soort
            $setStudent.envelope.body.updateContactgegevens.contactgegeven.soort.naam = $account.contactgegeven.naam

            # Todo: Check deelnemernummer location
            $accountReference = $responseStudent.deelnemernummer
            
            $splatSetStudent = @{
                Method      = 'Post'
                Uri         = "$($config.BaseUrl.TrimEnd('/'))/services/api/algemeen/deelnemers"
                ContentType = "text/xml" 
                Body        = $setStudent.InnerXml
            }

            # Todo: Check possible the response!
            if (-not($dryRun -eq $true)) {
                $response = Invoke-RestMethod @splatSetStudent -Verbose:$false
                        
                $responsemessage = $response.Envelope.body.updateContactgegevensResponse.updateContactgegevensResponse
                Write-Verbose -Verbose "response $($responsemessage.status) - $($responsemessage.melding)"
            }

            $success = $true
            $auditLogs.Add([PSCustomObject]@{
                    Message = "Update account was successful."
                    IsError = $false
                })
            break
        }'NoChanges' {
            Write-Verbose "No changes to Eduarte-Student account with accountReference: [$($aRef)]"
            $success = $true
            $auditLogs.Add([PSCustomObject]@{
                    Message = "No changes will be made to the Eduarte-Student account with accountReference: [$($aRef)]"
                    IsError = $false
                })
            break
        }'NotFound' {
            $success = $false
            $auditLogs.Add([PSCustomObject]@{
                    Message = "Eduarte-Student account for: [$($p.DisplayName)] not found. Possibly deleted"
                    IsError = $true
                })
            break
        }
    }
    
}
catch {
    $success = $false
    $ex = $PSItem
    if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
        $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
        $errorObj = Resolve-Eduarte-StudentError -ErrorObject $ex
        $auditMessage = "Could not Update Eduarte-Student account. Error: $($errorObj.FriendlyMessage)"
        Write-Verbose "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
    }
    else {
        $auditMessage = "Could not Update Eduarte-Student account. Error: $($ex.Exception.Message)"
        Write-Verbose "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
    }
    $auditLogs.Add([PSCustomObject]@{
            Message = $auditMessage
            IsError = $true
        })
    # End
}
finally {
    $result = [PSCustomObject]@{
        Success   = $success
        Account   = $account
        Auditlogs = $auditLogs
    }
    Write-Output $result | ConvertTo-Json -Depth 10
}