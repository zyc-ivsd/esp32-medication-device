# Documentation guide

The current product is **AeroEase for Android**, with **ESP32-S3** as the project hardware target. The retained firmware and CI still target the earlier ESP32-C3 prototype; see [firmware status](../firmware/README.md). The product direction uses local records and offline assistance. Legacy online code remains in the repository and is not removed by this documentation update.

## Development references

- [Android app](../mobile_app/README.md): installation, data behavior, and build commands.
- [Android roadmap](android-roadmap.md): development planning; check dated items against current code.
- [Member integration](member-ab-integration.md): app/firmware integration notes.
- [Member A handoff](member-a-handoff.md) and [validation](member-a-validation.md): earlier implementation evidence.
- [Local assistant rules](assistant-local-rules.md) and [data requirements](assistant-data-requirements.md): assistant behavior and record inputs.

## Historical plans

The following documents capture earlier decisions and may describe features outside the current product scope:

- [Model access](assistant-model-access.md)
- [Xiaozhi official cloud](xiaozhi-official-cloud.md)
- [Xiaozhi developer handoff](xiaozhi-developer-handoff.md)
- [Gateway experiment](../server/assistant-gateway/README.md)
- [Development plan](development-plan.md)
- [Continuation task](ai-continuation-task.md)
- [iOS readiness](ios-readiness.md)

Use the current implementation and build configuration to resolve discrepancies. Historical test results apply to their recorded board, software version, and conditions.
