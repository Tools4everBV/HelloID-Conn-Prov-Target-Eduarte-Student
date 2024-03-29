#################################################
# HelloID-Conn-Prov-Target-Eduarte-Student-Create
#
# Version: 1.0.0
#################################################
# Initialize default values
$config = $configuration | ConvertFrom-Json
$p = $person | ConvertFrom-Json
$success = $false
$auditLogs = [System.Collections.Generic.List[PSCustomObject]]::new()

# Account mapping
$account = [PSCustomObject]@{
    ExternalId   = $p.ExternalId
    UserName     = $p.UserName
    EmailAddress = $p.Contact.Business.Email

    # Todo Generate password function
    Password     = "Password!"
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

# Begin
try {
    # Verify if [account.ExternalId] has a value
    if ([string]::IsNullOrEmpty($($account.ExternalId))) {
        throw 'Mandatory attribute [account.ExternalId] is empty. Please make sure it is correctly mapped'
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

    # Todo: Check if correlation condition works as expected
    if ($null -eq $responseStudent) {
        $action = 'Create-Correlate'
    }
    elseif ($config.updatePersonOnCorrelate -eq $true) {
        $action = 'Update-Correlate'
    }
    else {
        $action = 'Correlate'
    }

    # Add a warning message showing what will happen during enforcement
    if ($dryRun -eq $true) {
        Write-Warning "[DryRun] $action Eduarte-Student account for: [$($p.DisplayName)], will be executed during enforcement"
    }

    # Process
    if (-not($dryRun -eq $true)) {
        switch ($action) {
            'Create-Correlate' {
                [xml]$createStudent = '<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns:api="http://api.algemeen.webservices.eduarte.topicus.nl/">
                    <soapenv:Header/>
                    <soapenv:Body>
                    <api:createDeelnemerGebruiker>
                        <apiSleutel>X</apiSleutel>
                    </api:createDeelnemerGebruiker>
                    </soapenv:Body>
                </soapenv:Envelope>'

                $createStudent.envelope.body.createDeelnemerGebruiker.apiSleutel = "$($config.ApiKey)"
                
                $updateElement = $createStudent.envelope.body.createDeelnemerGebruiker
                $updateElement | Add-XmlElement -ElementName 'deelnemerNummer' -ElementValue "$($account.ExternalId)"
                $updateElement | Add-XmlElement -ElementName 'gebruikersnaam' -ElementValue "$($account.UserName)"
                $updateElement | Add-XmlElement -ElementName 'wachtwoord' -ElementValue "$($account.Password)"

                # Todo Email is an optional field, check if property needs to be set and what happends when $account.EmailAddress is empty
                $updateElement | Add-XmlElement -ElementName 'emailadres' -ElementValue "$($account.EmailAddress)"

                $splatCreateStudent = @{
                    Method      = 'Post'
                    Uri         = "$($config.BaseUrl.TrimEnd('/'))/services/api/algemeen/gebruikers"
                    ContentType = "text/xml" 
                    Body        = $createStudent.InnerXml
                }

                # Todo: Check possible the response!
                $null = Invoke-RestMethod @splatCreateStudent -Verbose:$false 

                $accountReference = $account.ExternalId
                $auditLogs.Add([PSCustomObject]@{
                        Message = "Create account was successful. AccountReference is: [$accountReference]"
                        IsError = $false
                    })
            }

            'Update-Correlate' {
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

                # Todo: Check if the email adres can be found in the [contactgegevens]
                $mailProperty = $responseStudent.contactgegevens.contactgegeven | Where-Object { $_.soort.naam -eq 'mail' }
                if ((-not [string]::IsNullOrEmpty($account.EmailAddress)) -and ($mailProperty.contactgegeven -ne $account.EmailAddress)) {
                    $updateElement.contactgegeven.contactgegeven = "$($account.EmailAddress)"
                    $updateRequired = $true
                }

                # Todo: Check deelnemerNummer location
                $accountReference = $responseStudent.deelnemerNummer

                if ($updateRequired) {
                    $splatSetStudent = @{
                        Method      = 'Post'
                        Uri         = "$($config.BaseUrl.TrimEnd('/'))/services/api/algemeen/deelnemers"
                        ContentType = "text/xml" 
                        Body        = $setStudent.InnerXml
                    }

                    # Todo: Check possible the response!
                    $null = Invoke-RestMethod @splatSetStudent -Verbose:$false


                    $auditLogs.Add([PSCustomObject]@{
                            Message = "Update account was successful. AccountReference is: [$accountReference]"
                            IsError = $false
                        })
                }
                else {
                    $auditLogs.Add([PSCustomObject]@{
                            Message = "No Update account required. AccountReference is: [$accountReference]"
                            IsError = $false
                        })
                }
                break
            }
            'correlate' {
                Write-Verbose 'Correlating Eduarte student'
                $accountReference = $responseStudent.deelnemerNummer
                break
            }

            
        }
        $success = $true
        $auditLogs.Add([PSCustomObject]@{
                Message = "$action account was successful. AccountReference is: [$($accountReference)]"
                IsError = $false
            })
    }
}
catch {
    $success = $false
    $ex = $PSItem
    if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
        $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
        $errorObj = Resolve-Eduarte-StudentError -ErrorObject $ex
        $auditMessage = "Could not $action Eduarte-Student account. Error: $($errorObj.FriendlyMessage)"
        Write-Verbose "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
    }
    else {
        $auditMessage = "Could not $action Eduarte-Student account. Error: $($ex.Exception.Message)"
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
        Success          = $success
        AccountReference = $accountReference
        Auditlogs        = $auditLogs
        Account          = $account
    }
    Write-Output $result | ConvertTo-Json -Depth 10
}
