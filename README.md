# OrganizeEntropy
Delphi 12 app to read BagSync WoW addon data and suggest inventory consolidation. 
Will eventually report which items are moveable and suggest consolidation moves to free up bag/bank/tab space.

The Project Is a Delphi 12 Win32 desktop application that:
1. Reads WoW **BagSync** SavedVariables (BagSync.lua)
2. Parses inventory data across all characters, guilds, and warband tabs
3. Stores it in a local **SQLite** database
4. Will eventually report which items are moveable and suggest consolidation moves to free up bag/bank/tab space
5. A companion WoW addon (**OrganizeItemsThroughBagSyncExport**) exports item metadata (name, bind type, quality tier, etc.) into its own SavedVariables file, which feeds the Items table.

My thoughts/notes, future TODOs: 
- Version in app's addon: should change automatically in file somehow: that OrganizeItemsThroughBagSyncExport.toc's "Interface" line refers to a specific version of the game, but that changes every few months and if its behind current version not sure the app's addon would work. 
- (new) Tab in app: 
items won't have to move to empty slots, can as well move to character's bags/guild tabs/whatever where the same item exists 
e.g. char A has 2 items B, bank C has 1 item B, char D has 5 items B, bank E has 12 items B => that means that item B from all sources can be moved not just to an empty slot but from/to either A, C, D, E.  
Tab should show that info like the sources of B and the possible destinations: Empty slot/A/C/D/E.  
- User should be able to pick which characters and guilds should participate in the calculations and everything! 
e.g. Player has 12 characters, which 3 of them belong to guilds A, B and C, 4 characters that each has/owns its own guild(s) D, E, F, G, and 5 guildess characters. 
Then, all possible item movements and combinations and everything should be computed with the player ticking D, E, F, G, char8, char9, char10, char11, char12, or whatever combo they think/want.  
- Need to list prerequisites and make some documentation (login to WoW, have BagSync addon installed, how to run my addon to produce item IDs, everything) 



eof