# Hardware — ESP32-C3

This directory contains the hardware design assets for the parcel aerosol delivery project. AeroEase is the companion app name; existing design filenames retain the spelling used by their authors.

| Asset | File |
|---|---|
| Bill of materials | [BOM list.xlsx](<pcb/BOM list.xlsx>) |
| Manufacturing files | [Gerber_AeroEase.zip](pcb/Gerber_AeroEase.zip) |
| PCB drawing | [UCAS-China_AeroEase_PCB.pdf](pcb/UCAS-China_AeroEase_PCB.pdf) |
| Circuit schematic | [AeroEase-Schematic.pdf](schematic/AeroEase-Schematic.pdf) |

The project uses **ESP32-C3**, with Arduino firmware under `firmware/esp32-c3/`. Confirm the exact module and board revision against the schematic before wiring or flashing.

For a reproducible hardware handoff, record the board revision, fitted components, pin assignments, power requirements, programming connections, and measured behavior. Attach test evidence to the corresponding board revision.
