#################################################
# HelloID-Conn-Prov-Target-Eduarte-Student-Disable
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
    $getStudent.Envelope.Body.getDeelnemer.deelnemernummer = $aref

    $splatGetStudent = @{
        Uri             = "$($config.BaseUrl.TrimEnd('/'))/services/api/algemeen/deelnemers" 
        Method          = 'POST'
        Body            = $getStudent.InnerXml
        ContentType     = 'text/xml; charset=utf-8'
        UseBasicParsing = $true
    }
    $rawResponse = Invoke-RestMethod @splatGetStudent -Verbose:$true

    $responseStudent = ([xml]$rawResponse).Envelope.body.getDeelnemerResponse.deelnemer

    $userFound = $responseStudent.gebruikersNaam

    Write-Verbose "Verifying if a Eduarte student account for [$($p.DisplayName)] exists"
    if (-NOT [string]::isNullOrEmpty($userFound)) {
        $action = 'Found'
        $dryRunMessage = "Disable Eduarte student account for: [$($p.DisplayName)] will be executed during enforcement"
    }
    elseif ($null -eq $responseStudent) {
        $action = 'NotFound'
        $dryRunMessage = "Eduarte student account for: [$($p.DisplayName)] not found. Possibly already deleted. Skipping action"
    }

    # Add an auditMessage showing what will happen during enforcement
    if ($dryRun -eq $true) {
        Write-Warning "[Dryrun] $dryRunMessage"
    }

        switch ($action) {
            'Found' {
                Write-Verbose "Disabling Eduarte-Student account with accountReference: [$aRef]"

                # Disable Student XML call
                [xml]$disableStudent = '<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns:api="http://api.algemeen.webservices.eduarte.topicus.nl/">
                    <soapenv:Header/>
                    <soapenv:Body>
                    <api:deactiveerGebruiker>
                        <apiSleutel>?</apiSleutel>
                        <gebruikernaam>?</gebruikernaam>
                    </api:deactiveerGebruiker>
                    </soapenv:Body>
                </soapenv:Envelope>' 

                $disableStudent.envelope.body.deactiveerGebruiker.apiSleutel = "$($config.ApiKey)"
                $disableStudent.envelope.body.deactiveerGebruiker.gebruikernaam = $responseStudent.gebruikersNaam
               

                $splatDisableStudent = @{
                    Uri         = "$($config.BaseUrl.TrimEnd('/'))/services/api/algemeen/gebruikers" 
                    Method      = 'Post'
                    ContentType = "text/xml" 
                    Body        = $disableStudent.InnerXml
                }

                 if (-not($dryRun -eq $true)) {
                    $responseStudent = Invoke-RestMethod @splatDisableStudent -Verbose:$false
                }

                $success = $true
                $auditLogs.Add([PSCustomObject]@{
                        Message = 'Disable account was successful'
                        IsError = $false
                    })
            }
            'NotFound' {
                $success = $true
                $auditLogs.Add([PSCustomObject]@{
                        Message = "Eduarte-Student account for: [$($p.DisplayName)] not found. Possibly already deleted. Skipping action"
                        IsError = $false
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
        $auditMessage = "Could not Disable Eduarte-Student account. Error: $($errorObj.FriendlyMessage)"
        Write-Verbose "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
    }
    else {
        $auditMessage = "Could not Disable Eduarte-Student account. Error: $($ex.Exception.Message)"
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
        Auditlogs = $auditLogs
    }
    Write-Output $result | ConvertTo-Json -Depth 10
}