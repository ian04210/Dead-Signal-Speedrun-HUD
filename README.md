NOTE: This is a mod I made as the beginning of a practice course I'm doing to learn Unreal Engine Modding. This entire project is vibe coded. I had ChatGPT explain all the individual changes it would make each time it did in order to get fundamentals on modding. Future projects made by me will be written manually.

This is a mod for Dead Signal made with UE4SS. It adds a new Speedrun mode in the menu!

Once selected, it creates a RTA and IGT timer in the top right of the screen. It's designed to end when you go to sleep at the end of the 4am night.

## Installation:
-Download UE4SS v3.0.1. and extract the folder (any other version of UE4SS has yet to be tested.)
-Copy all the files in the extracted folder and paste them in steamapps\common\Dead Signal\DeadSignal\Binaries\Win64
-Make sure the folder this README file is in is extracted
-Open DeadSignalSpeedrun_v0.9.zip and copy the DeadSignalSpeedrun folder inside
-Paste the DeadSignalSpeedrun folder inside the Mods folder inside steamapps\common\Dead Signal\DeadSignal\Binaries\Win64
-Open the mods.txt file and add "DeadSignalSpeedrun : 1" written exactly like that (remove the quotes)
-Save the txt and run Dead Signal

## How to Use:
Simply select New Game, and click Speedrun! Time starts when you click "Begin Shift".

## Known limitations:
-The IGT is estimated continuously during gameplay, but its displayed value updates at checkpoints.
-The ending trigger has not been verified in a real world run.

## Credits:
-ian04 (Main Developer)
-UE4SS (Unreal Engine Mod Hoster)

Many more additions will come!
