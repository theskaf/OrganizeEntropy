# OrganizeEntropy
Delphi 12 app to read BagSync WoW addon data and suggest inventory consolidation. 
Will eventually report which items are moveable and suggest consolidation moves to free up bag/bank/tab space.

# The Project Is a Delphi 12 Win32 desktop application that:
# 1. Reads WoW **BagSync** SavedVariables (BagSync.lua)
# 2. Parses inventory data across all characters, guilds, and warband tabs
# 3. Stores it in a local **SQLite** database
# 4. Will eventually report which items are moveable and suggest consolidation moves to free up bag/bank/tab space
# 5. A companion WoW addon (**OrganizeItemsThroughBagSyncExport**) exports item metadata (name, bind type, quality tier, etc.) into its own SavedVariables file, which feeds the Items table.

TBD