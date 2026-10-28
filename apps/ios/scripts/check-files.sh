#!/bin/sh
# Human-driven real-phone check. This script does not install, launch, or touch the host.
set -eu
cat <<'CHECK'
Use the root-coordinated signed app and phone; do not launch a competing display.
Record source commit and run:
  python3 apps/ios/scripts/check-file-provider.py --app /path/to/Caboose.app

1. With the signed app installed by the phone owner, open Caboose once with saved pairing.
   Open Computer settings. Files setup must finish; capture any Files setup failed error
   including its domain/code. Retry Files Setup must clear the error on success.
2. Open Files > Browse > More (…) > Edit. Record whether Caboose is listed and its switch
   state BEFORE changing anything. If listed but off, enable it. Missing from this list
   is a registration/discovery failure, not evidence that the user disabled the provider.
   Return to Browse: the location should use the computer name once Caboose receives it.
3. Open the location. Verify the computer's actual home folders, open an existing file,
   and download it. Compare its contents to the computer; do not accept an empty location
   as success. Create a disposable folder/file in Files; rename, edit and delete it.
4. Park the computer with its normal owner control; Files access should wake it and list
   home. With the host temporarily unreachable from this phone, foreground Caboose and
   Retry Files Setup: registration must not wait for wake. Files access should report
   unreachable. Restore phone connectivity; retry browsing without pairing again.
5. Background/foreground and relaunch Caboose repeatedly. Verify one location and no stale
   setup error; rename the computer with its normal settings and verify the location name.
6. With permission to forget/re-pair this phone, sign out during setup, then pair again.
   Verify the old domain does not reappear after its delayed registration completes.
   If testing another computer, verify its domain replaces the first and cached contents
   never cross between them. Do not delete user files as part of this test.
7. If discovery still fails, capture the settings registration error and device Console
   logs for Caboose / fileproviderd (registration NSError domain/code and extension load
   failures). Record Browse > Edit before toggling. Do not remove/reinstall Caboose as a
   workaround: that loses the lifecycle evidence being tested.
CHECK
