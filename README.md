# yp-integration

MuleSoft app that connects YourPolicy's Salesforce to Applied Epic. Built for Mission Control story **PAN:10404** (feature PAN:10335, "One named connection Salesforce ↔ MuleSoft ↔ Applied Epic").

Source: https://github.com/HipTenRepo/YP-Mulesoft (private). Keep this README current when you change something.

## Status (2026-10-30)

| Piece | State |
|---|---|
| Mule → Salesforce (JWT bearer) | Works in dev (YPHTDEV1) and uat (YPUAT) |
| Salesforce → Mule (Named Credential + Client ID Enforcement) | Credentials and policy in place, verified with curl. No Salesforce-side caller yet |
| HTTPS listener | Self-signed cert per env, TLS 1.2/1.3 only |
| Applied Epic leg | Not built. Blocked until Applied Epic issues the Third-Party Consultant designation (PAN:10404 AC6) |
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
                                                                                      └──(not built)──▶ Applied Epic
```

**API spec**: RAML in Design Center, published to Exchange as `yp-integration-api` 1.0.0 (group = Anypoint org id `fd64dbb6-4a14-442f-a8f2-0dfba976974e`). The app pulls it from Exchange. Change the spec in Design Center and republish; never hand-edit it under `src/main/resources/api`.

**Endpoints** (base `/api`):

| Endpoint | What it does |
|---|---|
| `GET /health` | `{status: "UP", application, environment, timestamp}` |
| `POST /connection-test` | Reads the integration user's own User record in Salesforce via JWT. Returns `CONNECTED` + username; Applied Epic shows `NOT_CONFIGURED` |
| `/console` | APIkit console |

**Errors**: `error-handling.xml` (`global-error-handler`) plus the mapping in `src/main/resources/modules/errors.dwl`. APIKIT errors → 400/404/405/406/415/501, everything else → 500 `INTERNAL_ERROR`. The response body follows the spec's `Error` type and carries an `x-correlation-id` header. Full detail goes only to the log.

## Files

| File | Purpose |
|---|---|
| `src/main/mule/global.xml` | Properties, secure properties, TLS context, HTTPS listener, Salesforce JWT config, API autodiscovery |
| `src/main/mule/yp-integration-api.xml` | APIkit router + endpoint flows |
| `src/main/mule/error-handling.xml`, `modules/errors.dwl` | Global error handler |
| `src/main/resources/config/{env}.yaml` | Plain settings per environment |
| `src/main/resources/config/{env}-secure.yaml` | Secrets only, encrypted |
| `src/main/resources/keystores/` | Private keys. **Ignored by `.gitignore`, never commit.** Originals in `~/.yp-secrets/mulesoft/<env>/` |
| `mule-artifact.json` | Mule 4.12+, Java 17, `mule.key` marked as a secure property |

## Environments

Anypoint has two environments, Sandbox and Production. dev and uat are two apps in Sandbox running the same jar.

| `mule.env` | Anypoint env | CloudHub app | Salesforce org | Integration username |
|---|---|---|---|---|
| `local` | (your machine) | none | YPHTDEV1 | `yourpolicy_mulesoft_integration@hipten.com.htdev1` |
| `dev` | Sandbox | `yp-mulesoft-dev` (https://yp-mulesoft-dev-pp2cnf.5sc6y6-1.usa-e2.cloudhub.io) | YPHTDEV1 | same as local |
| `uat` | Sandbox | `yp-mulesoft-uat` (https://yp-mulesoft-uat-pp2cnf.5sc6y6-3.usa-e2.cloudhub.io) | YPUAT | `yourpolicy_mulesoft_integration@hipten.com.uat` |
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

- **Salesforce side**: Named Credential `YP_MuleSoft` (URL per org: dev app or uat app + `/api`) and External Credential `YP_MuleSoft`. The External Credential is Custom type, principal `YP_MuleSoft_Principal`, and sends headers `client_id` / `client_secret`. Those values were entered in the Salesforce UI.
- **Mule side**: API Manager instance **21216714** (Sandbox, shared by the dev and uat apps; prod gets its own) enforces Client ID Enforcement on those headers. Exchange client app: "Salesforce UAT". The app registers through autodiscovery (`api.id` in each env yaml).
- **CloudHub 2.0 doesn't inject platform credentials.** The deployment needs `anypoint.platform.client_id` / `anypoint.platform.client_secret` (the Sandbox environment's credentials) as properties, or every call is blocked. Local runs disable the gatekeeper instead.

### HTTPS

- Self-signed PKCS12 per env: `keystores/yp-https-{env}.p12`, alias `yp-https`, valid 730 days, TLS 1.2/1.3 only.
- On CloudHub, **Last-Mile Security must be on**, otherwise you get 502s.
- **IP restriction (AC3) is open.** CloudHub 2.0 shared space has no static egress IPs, so the External Client App's IP policy is currently "Bypass".

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
- **Terminal**: `~/AnypointStudio/tools/yp-run.sh start [env]` | `stop` | `log`. It reads `MULE_KEY_<ENV>` from the environment.
- **Check**: `curl -k https://localhost:8081/api/health`

## Deploy (manual)

1. `mvn package`
2. In Runtime Manager, upload `target/*-mule-application.jar` to the app for that env (runtime 4.12.x).
3. Set properties: `mule.env=<env>`, plus protected `mule.key`, `anypoint.platform.client_id` and `anypoint.platform.client_secret`.
4. Turn on Last-Mile Security.

No Maven deploy: it would need an Anypoint connected app.

## Where the secrets live

All under `~/.yp-secrets/mulesoft/`, never in this folder or any repo:

| Item | What it holds |
|---|---|
| `mule-keys.env` | `mule.key` per env |
| `<env>/` | Keystore backups and certificates |
| `yp-integration-credentials.md` | Connection values per environment (consumer keys, API Manager client app, URLs) |
| `jwt-test.sh` | JWT login test script |

## Open items

- Applied Epic leg (after the AC6 designation).
- A Salesforce-side caller for the Named Credential (end-to-end round trip, AC7).
- IP restriction (AC3).
- Prod: integration user, key pair + certificate, External Client App, CloudHub app, API Manager instance.
- Object/field permissions + API Integration PSL for the integration user, once the field mapping is agreed.

Salesforce-side detail and deploy history: `deploy/stories/PAN-10404.md` and `docs/project/fs5-build-plan.md` in the YourPolicy Salesforce repo.
