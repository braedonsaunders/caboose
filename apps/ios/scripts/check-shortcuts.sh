#!/bin/sh
# Manual acceptance check with a signed app, paired phone and installed Craft apps.
set -eu
cat <<'CHECK'
1. Open Computer settings > Shortcuts. Verify browsing opens Caboose in Apple Shortcuts
   and Create a Shortcut opens the editor. Repeat with the computer unreachable.
2. Add Export Files. Select PhotoCraft, choose an image, and select png. Connect its
   output to Quick Look or Save File. Run it and inspect the returned image.
3. Change the app to FilmCraft. Verify the format choices become mp4 and mov. Select
   one .fcproj whose media exists on the computer, export it and inspect the video.
4. Set Files to Ask Each Time or a previous action's output and verify both work.
5. Supply an incompatible format through a variable and too many files for LightCraft.
   Verify an actionable error appears and no job files are staged on the computer.
6. Verify Export Files and Combine PDFs appear as advertised shortcuts. Individual
   Convert Images, Develop Photo and Export Film actions should not be advertised.
7. Run a previously saved shortcut using an individual Craft intent and verify it works.
8. Create an Open Linux App shortcut, choose an installed app and add it to Home Screen
   in Shortcuts. Verify the icon launches the selected app on the computer.
CHECK
