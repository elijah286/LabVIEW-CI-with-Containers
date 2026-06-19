# labview

labview provides shared utilities for building LabVIEW-based services:

- LabVIEW automation client (BSON/TCP protocol)
- Process management and health checks
- Platform-specific constants and utilities

## What it provides

- **LabVIEW Client**: Communicate with LabVIEW instances via the BSON/TCP automation protocol
- **Process Management**: Start, stop, and monitor LabVIEW processes
- **Platform Utilities**: Cross-platform process and system utilities using gopsutil
- **BSON Encoding**: BSON serialization via mongo-driver/bson (no database connectivity)

## Usage

See service implementations like `src/labview/vi-xml` for usage examples.
