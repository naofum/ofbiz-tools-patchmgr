# Core diff inventory

This file tracks core OFBiz changes that are outside the normal plugin
boundary. Each bundle has a separate owner and must not be mixed into another
plugin's patch set.

| Bundle | Purpose | Files | Owner | Notes |
|---|---|---|---|---|
| `finance` | Fix payment-application removal consistency | `applications/accounting/src/main/groovy/org/apache/ofbiz/accounting/payment/PaymentServices.groovy` | `plugins/finance/patches/24.09.07/` | Implemented. Corrects `statustId` to `statusId`, clears `paidDate`, and propagates status-transition errors. Recorded in `plugins/finance/SPEC.md`. |
| `jp-localization` | Japanese postal-address widget and JPN address order | `applications/party/template/party/EditContactMech.ftl`<br>`applications/party/template/party/contactmechtemplates/PostalAddress_JPN.ftl`<br>`applications/party/template/party/contactmechtemplates/PostalAddress_JPN.fo.ftl`<br>`applications/party/widget/partymgr/PartyForms.xml` | `plugins/translate-jp/patches/24.09.07/` | Implemented. Changes field order, required fields, postal-code prefix, and JPN address order. This is a layout/business-rule change, not only a translation. Candidate for upstreaming. |
| `translate-jp` | UI label Japanese translations | `applications/**/config/*UiLabels.xml`<br>`framework/**/config/*UiLabels.xml`<br>`themes/**/config/*UiLabels.xml` | `plugins/translate-jp` | Prefer key-level merge or plugin label-resource override over full-file overwrite. |
| `efinance` | rest-api integration for efinance | `plugins/rest-api/src/main/java/org/apache/ofbiz/ws/rs/security/auth/EfAuthFilter.java` (new)<br>`plugins/rest-api/src/main/java/org/apache/ofbiz/ws/rs/security/auth/APIAuthFilter.java`<br>`plugins/rest-api/src/main/java/org/apache/ofbiz/ws/rs/process/ServiceRequestHandler.java` | `plugins/efinance/patches/24.09.07/` | Implemented. `EfAuthFilter` is new; the other two are diff patches against upstream rest-api `release24.09.07`. Baseline copies under the bundle are test fixtures only. |
| `casemgmt` | CASE WorkEffort type guards and generic screen exclusion | TBD in Phase 1 | `plugins/casemgmt` | Prefer Entity ECA first. Patch only the generic list/lookup/edit XML if the ECA guard cannot cover it. |

## Rules

- Do not put another plugin's core patch in `plugins/casemgmt/patches/`.
- Every bundle has its own `manifest.json` with target OFBiz version and
  `sha256Before` / `sha256After`.
- A future aggregate `patchmgr` should scan all plugin manifests, detect
  overlapping target files, and apply bundles in dependency order.
- A patch that can be upstreamed should be proposed to OFBiz rather than
  carried forever.
