# Hardware — ESP32-S3 project target

This directory contains the hardware design assets for the parcel aerosol delivery project. AeroEase is the companion app name; existing design filenames retain the spelling used by their authors.

| Asset | File |
|---|---|
| Bill of materials | [BOM list.xlsx](<pcb/BOM list.xlsx>) |
| Manufacturing files | [Gerber_AeroEase.zip](pcb/Gerber_AeroEase.zip) |
| PCB drawing | [UCAS-China_AeroEase_PCB.pdf](pcb/UCAS-China_AeroEase_PCB.pdf) |
| Circuit schematic | [AeroEase-Schematic.pdf](schematic/AeroEase-Schematic.pdf) |

**ESP32-S3 is the project target.** Confirm the exact module and revision against the board and schematic before wiring or flashing. The retained firmware under `firmware/esp32-c3/` targets an earlier C3 prototype and needs a board-specific S3 port.

For a reproducible hardware handoff, record the board revision, fitted components, pin assignments, power requirements, programming connections, and measured behavior. Attach test evidence to the corresponding board revision rather than transferring C3 results to S3 by assumption.
