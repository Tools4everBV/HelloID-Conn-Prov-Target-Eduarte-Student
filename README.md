# HelloID-Conn-Prov-Target-Eduarte-Student

> [!IMPORTANT]
> This connector has been upgraded to a HelloID PowerShell v2 connector and refactored to meet the latest standards.
Please note that it was updated without a working test environment, so we recommend validating it during implementation.

> [!IMPORTANT]
> This repository contains the connector and configuration code only. The implementer is responsible to acquire the connection details such as username, password, certificate, etc. You might even need to sign a contract or agreement with the supplier before implementing this connector. Please contact the client's application manager to coordinate the connector requirements.

<p align="center">
  <img src="https://www.eduarte.nl/wp-content/uploads/2018/06/eduarte-logo.png">
  </p>


## Table of contents

- [HelloID-Conn-Prov-Target-Eduarte-Student](#helloid-conn-prov-target-eduarte-student)
  - [Table of contents](#table-of-contents)
  - [Introduction](#introduction)
  - [Supported features](#supported-features)
  - [Getting started](#getting-started)
    - [HelloID Icon URL](#helloid-icon-url)
    - [Connection settings](#connection-settings)
    - [Correlation configuration](#correlation-configuration)
    - [Field mapping](#field-mapping)
    - [Account Reference](#account-reference)
  - [Remarks](#remarks)
    - [Contactgegeven](#contactgegeven)
    - [Extra properties](#extra-properties)
    - [Update](#update)
    - [ToDo](#todo)
  - [Development resources](#development-resources)
    - [API endpoints](#api-endpoints)
  - [Getting help](#getting-help)
  - [HelloID docs](#helloid-docs)

## Introduction
_HelloID-Conn-Prov-Target-Eduarte-Student_ is a _target_ connector. Eduarte-Student provides a set of REST API's that allow you to programmatically interact with its data. This connector only correlates HelloID persons with Student accounts and updates the Email Address.

## Supported features

The following features are available:

| Feature                                   | Supported | Actions                         | Remarks             |
| ----------------------------------------- | --------- | ------------------------------- | ------------------- |
| **Account Lifecycle**                     | ✅         | Create, Update, Enable, Disable | No Delete available |
| **Permissions**                           | ❌         |                                 |                     |
| **Resources**                             | ❌         | -                               |                     |
| **Entitlement Import: Accounts**          | ❌         | -                               |                     |
| **Entitlement Import: Permissions**       | ❌         | -                               |                     |
| **Governance Reconciliation Resolutions** | ❌         | -                               |                     |

## Getting started

### HelloID Icon URL
URL of the icon used for the HelloID Provisioning target system.
```
https://raw.githubusercontent.com/Tools4everBV/HelloID-Conn-Prov-Target-Eduarte-Student/refs/heads/main/Icon.png
```

### Connection settings

The following settings are required to connect to the API.

| Setting | Description                      | Mandatory |
| ------- | -------------------------------- | --------- |
| ApiKey  | The ApiKey to connect to the API | Yes       |
| BaseUrl | The URL to the API               | Yes       |

### Correlation configuration

The correlation configuration is used to specify which properties will be used to match an existing account within _Eduarte-Student_ to a person in _HelloID_.

| Setting                   | Value                             |
| ------------------------- | --------------------------------- |
| Enable correlation        | `True`                            |
| Person correlation field  | `PersonContext.Person.ExternalId` |
| Account correlation field | `deelnemerNummer`                 |

> [!TIP]
> _For more information on correlation, please refer to our correlation [documentation](https://docs.helloid.com/en/provisioning/target-systems/powershell-v2-target-systems/correlation.html) pages_.

### Field mapping

The field mapping can be imported by using the _fieldMapping.json_ file.

### Account Reference

The account reference is populated with the property `deelnemerNummer` property from _Eduarte-Student_

## Remarks

### Contactgegeven
- **configuration**: Contactgegeven in configuration is the code/name pair that identifies which Eduarte-Student contact field holds the email value. The connector uses ContactGegevenCode to find the existing contactgegeven entry and then compares/updates that exact contact detail.

### Extra properties
- **create & update**: When adding extra properties to the fieldmapping for the create and or update, make sure they are compatible in the script.ps1 files.

### Update
- **only emailAddress**: The update only updates the emailAddress, the connector requires changes if this is not sufficient.

### ToDo
- **comments**: The scripts contains several To-do comments. Please look into these statements during implementation.

- **email**: The property email does not exist as a fixed property on the student object. I have made an assumption about where to find it. During implementation, it still needs to be verified. It is used to check whether an update needs to take place or not.

- **username**: There is no Username Property present in de Deelnemers WSDL, We must look into this. The UMRA (Paid service) Does contain a Username property. This can be verified with a working test environment.

## Development resources

### API endpoints

The following endpoints are used by the connector

| Endpoint                          | HTTP Method | Description       |
| --------------------------------- | ----------- | ----------------- |
| /services/api/algemeen/deelnemers | POST        | Get               |
| /services/api/algemeen/gebruikers | POST        | Create and Update |

## Getting help

> [!TIP]
> _For more information on how to configure a HelloID PowerShell connector, please refer to our [documentation](https://docs.helloid.com/en/provisioning/target-systems/powershell-v2-target-systems.html) pages_.

## HelloID docs

The official HelloID documentation can be found at: https://docs.helloid.com/
