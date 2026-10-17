# Hardware — ESP32-C3

This directory contains the hardware design assets for the parcel aerosol delivery project. AeroEase is the companion app.

| Asset | File |
|---|---|
| Bill of materials | [BOM list.xlsx](<pcb/BOM list.xlsx>) |
| Manufacturing files | [Gerber_AeroEase.zip](pcb/Gerber_AeroEase.zip) |
| PCB drawing | [UCAS-China_AeroEase_PCB.pdf](pcb/UCAS-China_AeroEase_PCB.pdf) |
| Circuit schematic | [AeroEase-Schematic.pdf](schematic/AeroEase-Schematic.pdf) |

The project uses **ESP32-C3**, with Arduino firmware under `firmware/esp32-c3/`. Confirm the exact module and board revision against the schematic before wiring or flashing.

For assembly and integration, use the board revision, fitted components, pin assignments, power requirements, and programming connections specified for the board. Associate measurements with the corresponding board revision.
