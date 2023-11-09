#################################################
# HelloID-Conn-Prov-Target-Eduarte-Student-update
#
# Version: 1.0.0
#################################################
# Initialize default values
$config = $configuration | ConvertFrom-Json
$p = $person | ConvertFrom-Json
$aRef = $AccountReference | ConvertFrom-Json
$success = $false
$auditLogs = [System.Collections.Generic.List[PSCustomObject]]::new()

$account = [PSCustomObject]@{
    ExternalId   = $p.ExternalId
    UserName     = $p.UserName
    EmailAddress = $p.Contact.Business.Email
}

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

    # Get Student XML call
    [xml]$getStudent = '<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns:api="http://api.algemeen.webservices.eduarte.topicus.nl/">
            <soapenv:Header/>
            <soapenv:Body>
            <api:getDeelnemer/>
            </soapenv:Body>
    </soapenv:Envelope>'
    $getDeelnemerElement = $getStudent.envelope.body.ChildNodes | Where-Object { $_.LocalName -eq 'getDeelnemer' }
    $getDeelnemerElement | Add-XmlElement -ElementName 'apiSleutel' -ElementValue "$($config.ApiKey)"
    $getDeelnemerElement | Add-XmlElement -ElementName 'deelnemernummer' -ElementValue "$($account.ExternalId)"

    $splatGetStudent = @{
        Uri         = "$($config.BaseUrl.TrimEnd('/'))/services/api/algemeen/deelnemers" 
        Method      = 'Post'
        ContentType = "text/xml" 
        Body        = $getStudent.InnerXml
    }
    $responseStudent = Invoke-RestMethod @splatGetStudent -Verbose:$false

    # Verify if the account must be updated
    # Todo change update check to your needs
    # Todo: Check if the email adres can be found in the [contactgegevens]
    $propertiesChanged = $false
    $mailProperty = $responseStudent.contactgegevens.contactgegeven | Where-Object { $_.soort.naam -eq 'mail' }
    
    if (($responseStudent.username -ne $account.username) -or ($responseStudent.EmailAddress -ne $account.EmailAddress) -or ((-not [string]::IsNullOrEmpty($account.EmailAddress)) -and ($mailProperty.contactgegeven -ne $account.EmailAddress))) {
        $propertiesChanged = $true
    }

    if ($propertiesChanged) {
        $action = 'Update'
        $dryRunMessage = 'Update Eduarte-Student account for: [$($p.DisplayName)] will be executed during enforcement'
    } elseif ((-not ($propertiesChanged) -And ($responseStudent))) {
        $action = 'NoChanges'
        $dryRunMessage = 'No changes will be made to the account during enforcement'
    } elseif ($null -eq $responseStudent) {
        $action = 'NotFound'
        $dryRunMessage = "Eduarte-Student account for: [$($p.DisplayName)] not found. Possibly deleted"
    }

    # Add an auditMessage showing what will happen during enforcement
    if ($dryRun -eq $true) {
        $auditLogs.Add([PSCustomObject]@{
                Message = $dryRunMessage
            })
    }

    if (-not($dryRun -eq $true)) {
        switch ($action) {
            'Update' {
                [xml]$setStudent = '<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns:api="http://api.algemeen.webservices.eduarte.topicus.nl/">
                    <soapenv:Header/>
                    <soapenv:Body>
                    <api:updateContactgegevens>
                        <contactgegeven>
                            <contactgegeven>xxx</contactgegeven>
                            <soort>
                                <code>X</code>
                                <naam>X</naam>
                            </soort>
                            <geheim>false</geheim>
                        </contactgegeven>
                    </api:updateContactgegevens>
                    </soapenv:Body>
                </soapenv:Envelope>'

                $updateElement = $setStudent.envelope.body.updateContactgegevens
                $updateElement | Add-XmlElement -ElementName 'apiSleutel' -ElementValue "$($config.ApiKey)"
                $updateElement | Add-XmlElement -ElementName 'deelnemerNummer' -ElementValue "$($account.ExternalId)"

                $updateElement.contactgegeven.contactgegeven = "$($account.EmailAddress)"

                # Todo fill these properties with the correct value or remove them.
                $updateElement.contactgegeven.contactgegeven.soort.code = ""
                $updateElement.contactgegeven.contactgegeven.soort.naam = ""

                # Todo: Check deelnemerNummer location
                    $splatSetStudent = @{
                        Method      = 'Post'
                        Uri         = "$($config.BaseUrl.TrimEnd('/'))/services/api/algemeen/deelnemers"
                        ContentType = "text/xml" 
                        Body        = $setStudent.InnerXml
                    }

                    # Todo: Check possible the response!
                    $null = Invoke-RestMethod @splatSetStudent -Verbose:$false

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