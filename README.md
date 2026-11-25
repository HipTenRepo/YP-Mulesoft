# yp-integration

MuleSoft app that connects YourPolicy's Salesforce to Applied Epic. Built for Mission Control stories **PAN:10404** (feature PAN:10335, "One named connection Salesforce ↔ MuleSoft ↔ Applied Epic") and **PAN:29619** (list, preview and download Applied Epic files).

Source: https://github.com/HipTenRepo/YP-Mulesoft (private). Keep this README current when you change something.

## Status (2026-11-25)

| Piece | State |
|---|---|
| Mule → Salesforce (JWT bearer) | Works for YPHTDEV1 (local) and YPUAT (the Sandbox app) |
| Salesforce → Mule (Named Credential + Client ID Enforcement) | Credentials and policy in place, verified with curl. Salesforce-side callers (files component) being built |
| HTTPS listener | Self-signed cert per env, TLS 1.2/1.3 only |
| Applied Epic leg | OAuth client credentials against the Applied Epic sandbox (S1). Used by `/connection-test` and the files endpoints |
| Files (PAN:29619) | List, preview and download tested locally against S1. See "Applied Epic files" |
| Production | Not set up (config has TODO placeholders) |

## Architecture

One Mule app. No API-led layers (no separate system/process/experience apps). Layering lives inside the app:

- **Controller**: the APIkit flows generated from the RAML (`yp-integration-api.xml`).
- **Service**: business logic, as **sub-flows**.
- **Repository**: connector calls (Salesforce, later Applied Epic), as **sub-flows**.

Service and repository must be sub-flows so the global error handler runs once, at the controller.

```
Salesforce ──HTTPS, client_id/client_secret headers──▶ API Manager policy ──▶ yp-integration (CloudHub 2.0)
 (Named Credential YP_MuleSoft)                       (Client ID Enforcement)        │
                                                                                      ├──JWT bearer──▶ Salesforce REST API (as the integration user)
                                                                                      └──OAuth client credentials──▶ Applied Epic
Browser (preview frame / new tab) ──/download/{token}, no client credentials──────────────▶ yp-integration ──▶ Applied Epic file storage
```

**API spec**: RAML in Design Center, published to Exchange as `yp-integration-api` (current 1.1.3; group = Anypoint org id `fd64dbb6-4a14-442f-a8f2-0dfba976974e`). The app pulls it from Exchange. Change the spec in Design Center, publish a new version, bump it in `pom.xml` and re-scaffold; never hand-edit it under `src/main/resources/api`.

**Endpoints** (base `/api`):

| Endpoint | What it does |
|---|---|
| `GET /health` | `{status: "UP", application, environment, timestamp}` |
| `POST /connection-test` | Reads the integration user's own User record in Salesforce via JWT and reads one client from Applied Epic. Reports `CONNECTED` or `FAILED` for each leg |
| `POST /files/list` | One page of the folders and files of an Applied Epic client, opportunity or policy |
| `POST /files/link` | A short-lived link to preview or download one file, checked against the record. Writes the audit row |
| `GET /download/{token}` | Public. Streams the file to the browser. The token is its only lock |
| `/console` | APIkit console |

**Errors**: `error-handling.xml` (`global-error-handler`) plus the mapping in `src/main/resources/modules/errors.dwl`. APIKIT errors → 400/404/405/406/415/501, everything else → 500 `INTERNAL_ERROR`. The response body follows the spec's `Error` type and carries an `x-correlation-id` header. Full detail goes only to the log.

## Files

| File | Purpose |
|---|---|
| `src/main/mule/global.xml` | Properties, secure properties, TLS context, HTTPS listener, Salesforce JWT config, API autodiscovery |
| `src/main/mule/yp-integration-api.xml` | APIkit router + endpoint flows |
| `src/main/mule/epic-files.xml`, `modules/epicFiles.dwl` | Files service: list, link, audit and error rows, download |
| `src/main/mule/applied-client.xml` | Applied Epic repository: token (cached), request with one retry on 401 |
| `src/main/mule/salesforce-client.xml` | Salesforce repository: query and create through the JWT connection |
| `src/main/mule/error-handling.xml`, `modules/errors.dwl` | Global error handler |
| `src/main/resources/config/{env}.yaml` | Plain settings per environment |
| `src/main/resources/config/{env}-secure.yaml` | Secrets only, encrypted |
| `src/main/resources/keystores/` | Private keys. **Ignored by `.gitignore`, never commit.** Originals in `~/.yp-secrets/mulesoft/<env>/` |
| `mule-artifact.json` | Mule 4.12+, Java 17, `mule.key` marked as a secure property |

## Environments

Anypoint has two environments, Sandbox and Production. **Sandbox runs one app, `yp-mulesoft-uat`, shared by YPHTDEV1 and YPUAT**: both orgs' Named Credentials point at it. Its own Salesforce connection (JWT, audit rows) goes to YPUAT. The `dev` config is kept for a separate dev app but nothing is deployed with it. local, dev and uat all use the same Applied Epic sandbox (S1) credentials.

| `mule.env` | Anypoint env | CloudHub app | Salesforce org | Integration username |
|---|---|---|---|---|
| `local` | (your machine) | none | YPHTDEV1 | `yourpolicy_mulesoft_integration@hipten.com.htdev1` |
| `dev` | Sandbox | none (not deployed) | YPHTDEV1 | same as local |
| `uat` | Sandbox | `yp-mulesoft-uat` (https://yp-mulesoft-uat-pp2cnf.5sc6y6-3.usa-e2.cloudhub.io), called by YPHTDEV1 and YPUAT | YPUAT | `yourpolicy_mulesoft_integration@hipten.com.uat` |
| `prod` | Production | TODO | YPProd | TODO |

**How config works**: `mule.env` (default `local`) picks `config/${mule.env}.yaml` and `config/${mule.env}-secure.yaml`. Secure values are AES / CBC / random IV, with **one `mule.key` per environment**. `mule.key` is never in the project: locally it's an environment variable, on CloudHub a protected property. Encrypt a new value with:

```
java -cp ~/AnypointStudio/tools/secure-properties-tool.jar com.mulesoft.tools.SecurePropertiesTool \
  string encrypt AES CBC "<that env's mule.key>" "<value>" --use-random-iv
```

## Authentication

### Mule → Salesforce: OAuth 2.0 JWT bearer

- **External Client App** `YP_MuleSoft_Integration` in each org. Scopes `Api` + `RefreshToken`: JWT never issues a refresh token, but Salesforce refuses the flow without that scope. It is pre-authorized for permission set `YP_MuleSoft_Integration_User` (AdminApprovedPreAuthorized). All other OAuth flows are off.
- **Certificate**: each org has its own key pair, generated locally with `keytool`. The public cert goes into `ExtlClntAppGlobalOauthSettings.certificate` at deploy time, so there's no UI upload. The Salesforce repo copy carries no cert or consumer key. The private key lives in `keystores/yp_private_{env}.jks` (alias `yp_mulesoft_integration`); its password is in `{env}-secure.yaml`.
- **Consumer key**: plain in `{env}.yaml` (a public identifier, not a secret). Read it back by retrieving `ExtlClntAppGlobalOauthSettings` into a scratch folder, never into git.
- **Integration user** "MuleSoft Integration User":
  - Salesforce Integration license; profile Minimum Access - API Only Integrations.
  - Permission Set Group `YP_MuleSoft_Integration` = `YP_MuleSoft_Integration_User` (empty) + `YP_Bypass_Automation`.
  - No object access yet. It comes with the field mapping, and needs the *Salesforce API Integration* permission set license first.
- **Test from the terminal**: `~/.yp-secrets/mulesoft/jwt-test.sh <keystore> <alias> <consumerKey> <username> <audience>`.
- **Errors that mislead**:
  - `user hasn't approved this consumer` means the username in the JWT matches no user.
  - `refresh_token scope is required` means the `RefreshToken` scope is missing.

### Salesforce → Mule

- **Salesforce side**: Named Credential `YP_MuleSoft` (URL: the Sandbox app + `/api` in both sandboxes) and External Credential `YP_MuleSoft`. The External Credential is Custom type, principal `YP_MuleSoft_Principal`, and sends headers `client_id` / `client_secret`. Those values were entered in the Salesforce UI.
- **Mule side**: API Manager instance **21216714** (Sandbox; prod gets its own) enforces Client ID Enforcement on those headers, on every path except `/download/*` (the policy's resource rule is `^(?!(/api)?/download/).*`). The browser opens `/download` links without credentials, so without that exclusion every preview and download answers 401. Exchange client app: "Salesforce UAT". The app registers through autodiscovery (`api.id` in each env yaml).
- **CloudHub 2.0 doesn't inject platform credentials.** The deployment needs `anypoint.platform.client_id` / `anypoint.platform.client_secret` (the Sandbox environment's credentials) as properties, or every call is blocked. Local runs disable the gatekeeper instead.

### HTTPS

- Self-signed PKCS12 per env: `keystores/yp-https-{env}.p12`, alias `yp-https`, valid 730 days, TLS 1.2/1.3 only.
- On CloudHub, **Last-Mile Security must be on**, otherwise you get 502s.
- **IP restriction (AC3) is open.** CloudHub 2.0 shared space has no static egress IPs, so the External Client App's IP policy is currently "Bypass".

## Applied Epic files

Stories PAN:29554 (feature), 29615 (Apex), 29617 (component), 29619 (this API).

- **List**: one Applied Epic page per call (`files.pageSize`, 50). `nextPageToken` is Applied's offset of the next page, blank on the last. Folders come on page 1 (Applied's folder list is agency-wide). Inactive files are left out. Each file has `available` (Applied status OK), `tooLarge` and `canPreview` (available, PDF or image, not too large). A record Applied doesn't know answers `NOT_FOUND`.
- **Link**: reads the file from Applied and checks it is on the given record (`REFUSED` otherwise). `NOT_AVAILABLE` when the file is inactive, not OK, or Applied sends no download URL (most files in the S1 sandbox, any size). Preview only for `files.previewTypes`. The link is `https://<host Salesforce called>/api/download/<token>` (from `X-Forwarded-Host` on CloudHub, `Host` locally): 64 random hex characters, stored in the Object Store `Epic_Files_Link_Store` for `files.linkTtlMinutes`. A download link works once; a preview link can be reopened until it expires.
- **Download**: gets a fresh signed URL from Applied and streams the file without buffering. Content type from an allow list, `inline` for previews (framed only by `files.frameAncestors`, images sandboxed), `attachment` for downloads (never framed), `nosniff`, `no-store`, `no-referrer`. Expired or used link: 404. Applied or storage failure: 502 and an Error row.
- **Log__c rows**: one Info / Resolved row per link handed out (PREVIEWED or DOWNLOADED), one Error / New row per failed download. Never the file name, description or contents (files are treated as protected health information). Written in the background; a rejected row is logged as a WARN.

| `files.*` setting | Meaning |
|---|---|
| `frameAncestors` | Lightning domains allowed to frame a preview. The Sandbox app lists YPUAT and YPHTDEV1. Update after a sandbox refresh that changes a domain |
| `linkTtlMinutes` | Link lifetime (5) |
| `pageSize`, `folderPageSize` | Applied page sizes for files (50) and folders (100) |
| `previewMaxBytes` | Preview size limit; `0` = none. 5 MB is proposed and waits for Your Policy's sign-off |
| `previewTypes` | Extensions that can be previewed: `pdf,png,jpg,jpeg,gif` |
| `storageTimeoutMs` | Timeout for the file storage request (60 s) |

**Postman** (`postman/`): `yp-integration.postman_collection.json` covers every files case in order (supported files, download-only types, files without a download link, access checks, list and paging) plus health and the connection test. Environments: `local`, `sandbox-htdev1` and `sandbox-uat` (same Sandbox app, different Salesforce record Ids for the audit row). Fill in `client_id` / `client_secret` (the "Salesforce UAT" client app; ask Stefan) in Postman, never in the files. Locally any value works. The Applied Epic test Ids are collection variables; `docs/applied-epic-files.md` in the YP-Salesforce repo explains them.

## What Salesforce does differently for the integration user

The integration user holds the custom permission `Bypass_Automation`, so it skips most Opportunity automation: 27 flows check it in their entry condition, and Erie / Ramsey check it at the start of each path. The 8 flows that keep data correct still run for it.

Not covered:
- The `OpportunityTrigger` Apex check isn't built.
- The managed-package triggers (DOZISF, tdc_tsw, webm) can't be bypassed.

Things the field mapping has to handle:
- **Campaign**: send `Campaign__c` on new Personal Lines / Commercial Lines / ARO / Winback opportunities. The default-campaign flow no longer fills it for this user, and a validation rule requires it.
- **Winback Enrolled Date**: not stamped for this user, so Winback follow-ups won't queue.
- **Lead conversion**: the user can't convert leads (the Integration license can't hold Edit Task).
- **Contacts**: creating them needs BenefitsGuide object access (the `bgxx` ContactTrigger checks it).

## After cloning

The `{env}-secure.yaml` files are in the repo, already encrypted, so you don't edit them. Three things are deliberately not in git; get them from Stefan through a secure channel:

1. **Anypoint access**: a login to the YourPolicy Anypoint org in Studio. The API spec is downloaded from Exchange when the project builds.
2. **Keystores**: copy `yp_private_{env}.jks` and `yp-https-{env}.p12` into `src/main/resources/keystores/`. Originals are in `~/.yp-secrets/mulesoft/<env>/` on Stefan's machine.
3. **`mule.key`** for each environment you want to run. It decrypts that environment's secure file.

Then in Studio: File > Import > Anypoint Studio > Anypoint Studio project from File System, and set the Run Configuration as below.

## Run locally

- **Studio**: Run Configuration > Environment: `mule.env=local`, `mule.key=<local key>`. VM argument: `-Danypoint.platform.gatekeeper=disabled`.
- **Autodiscovery**: comment out `api-gateway:autodiscovery` in `global.xml` for a local run, and uncomment it before you commit or deploy.
- **Terminal**: `~/AnypointStudio/tools/yp-run.sh start [env]` | `stop` | `log`. It reads `MULE_KEY_<ENV>` from the environment.
- **Check**: `curl -k https://localhost:8081/api/health`

## Deploy

1. Autodiscovery uncommented, then `mvn clean package -DskipTests`.
2. Upload `target/*-mule-application.jar` as a new version of the app in Runtime Manager (runtime 4.12.x), from Studio or through the Anypoint connected app "YP CLI" (Exchange + Runtime Manager APIs).
3. The app's properties stay as they are: `mule.env=<env>`, plus protected `mule.key`, `anypoint.platform.client_id` and `anypoint.platform.client_secret`. Last-Mile Security on.
4. After a deploy that touches files: a preview link still opens at 4 minutes and gives 404 after about 6; a download link gives 404 on the second open.

## Where the secrets live

All under `~/.yp-secrets/mulesoft/`, never in this folder or any repo:

| Item | What it holds |
|---|---|
| `mule-keys.env` | `mule.key` per env |
| `<env>/` | Keystore backups and certificates |
| `yp-integration-credentials.md` | Connection values per environment (consumer keys, API Manager client app, URLs) |
| `jwt-test.sh` | JWT login test script |

## Open items

- Applied Epic production credentials (after the AC6 designation).
- Files: Applied Epic sends no download URL for most S1 files (asked Applied); preview size limit sign-off; 20 s Applied timeout from PAN:29619 not set yet (30 s today).
- Audit and error rows for YPHTDEV1 calls land in YPUAT, and YPUAT needs Log__c and PAN:29621 (YP_Log_Writer) before they are accepted.
- IP restriction (AC3).
- Prod: integration user, key pair + certificate, External Client App, CloudHub app, API Manager instance.
- Object/field permissions + API Integration PSL for the integration user, once the field mapping is agreed.

Salesforce-side detail and deploy history: `deploy/stories/PAN-10404.md` and `docs/project/fs5-build-plan.md` in the YourPolicy Salesforce repo.
