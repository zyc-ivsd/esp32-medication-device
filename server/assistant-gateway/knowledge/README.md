# Assistant reference knowledge

The app's reference content is maintained in [assistant_knowledge.dart](../../../mobile_app/lib/assistant/assistant_knowledge.dart). This directory documents that content rather than maintaining a second authoritative corpus.

The local assistant uses fixed rules to explain record counts and app behavior. Reference retrieval is a separate implementation feature retained alongside legacy online providers; local retrieval alone does not guarantee that a calling provider will keep its selected text on the phone.

## Content scope

Include device and app facts: synchronization, timestamps, file limits, connection errors, record interpretation, and privacy boundaries. Exclude diagnosis, medication selection, dosing instructions, patient records, credentials, and internal troubleshooting logs.

Reference chunks use stable identifiers, titles, text, and keywords. Retrieval uses local text matching and ranking rather than a hosted embedding service. Keep terminology consistent with the current app and firmware; update explanations when the protocol changes.

## Review

Check that answers distinguish recorded button actions from measured delivery or inhalation, explain duplicate handling consistently, and do not invent fields absent from timestamp records. Test synchronization and date-related questions against the current implementation. Historical online-request descriptions should be treated as legacy behavior, not the offline product specification.

Run the relevant Flutter tests from `mobile_app/`. See the [app README](../../../mobile_app/README.md) and [documentation guide](../../../docs/README.md).
