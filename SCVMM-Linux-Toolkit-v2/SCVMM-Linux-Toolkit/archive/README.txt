SCVMM LINUX TOOLKIT
===================

CONTENTS

scripts/
  scvmm-linux-template-manager.sh
  scvmm-linux-template-creation.sh
  collect-diagnostics.sh

agent/
  scvmmguestagent.1.0.4.1032.x64.tar

launch.sh
  Starts the main interactive manager.

INSTALLATION PACKAGE

The original SCVMM Linux agent package is included.
Version: 1.0.4.1032
Architecture: x64

LAUNCHING

Extract the toolkit ZIP and run:

  bash launch.sh

PERMISSIONS

The launcher and management scripts require executable
permissions.

AGENT INSTALLATION

Do not reinstall or replace the existing agent until
Step 1 investigation and verification are complete.

The agent installation package is retained for later
controlled remediation.

WORKING DIRECTORY

All development and testing should be performed from
this toolkit directory.
