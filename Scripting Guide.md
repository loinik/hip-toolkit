# HER Interactive Lua Scripting Engine Reference

This document is a comprehensive guide to the Lua-based scripting system used in HER Interactive's Nancy Drew adventure games. The engine uses a custom runtime where game logic, UI, puzzles, conversations, and navigation are all defined declaratively in Lua scripts processed by an internal **Assets Renderer** (`AR`).

> **Game analyzed:** *Nancy Drew: Ghost of Thornton Hall* (GTH), internal resolution 1024×768.

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [AR — The Assets Renderer](#ar--the-assets-renderer)
3. [Scenes and Scene Files](#scenes-and-scene-files)
4. [Coordinate System](#coordinate-system)
5. [Core Primitives](#core-primitives)
   - [Rect](#rect)
   - [Point](#point)
   - [Color](#color)
6. [AR Node Types](#ar-node-types)
   - [AR:Overlay](#aroverlay)
   - [AR:Hotspot](#arhotspot)
   - [AR:Button](#arbutton)
   - [AR:Movie](#armovie)
   - [AR:Sound](#arsound)
   - [AR:Timer](#artimer)
   - [AR:Override](#aroverride)
   - [AR:Transformer](#artransformer)
   - [AR:Sink](#arsink)
   - [AR:Summary](#arsummary)
7. [The `active` Pattern](#the-active-pattern)
8. [Lifecycle Callbacks](#lifecycle-callbacks)
9. [Flags (FL)](#flags-fl)
10. [Brain Variables (BR)](#brain-variables-br)
11. [Var Tables (VT)](#var-tables-vt)
12. [Autotext System](#autotext-system)
13. [Conversation System (MakeConvo)](#conversation-system-makeconvo)
14. [Inventory System](#inventory-system)
15. [Cursors](#cursors)
16. [Fonts and Text Rendering](#fonts-and-text-rendering)
17. [Scene Navigation and Streams](#scene-navigation-and-streams)
18. [Scene Naming Convention](#scene-naming-convention)
19. [Environment Codes](#environment-codes)
20. [Game API](#game-api)
21. [Persistence: Save/Load/Attic](#persistence-saveloadattic)
22. [Helper Functions and Utilities](#helper-functions-and-utilities)
23. [Messaging and Aliases](#messaging-and-aliases)
24. [Complete Scene Example Walkthrough](#complete-scene-example-walkthrough)

---

## Architecture Overview

```
┌─────────────────────────────────────────────┐
│           Native C++ Engine Core            │
│  (rendering, input, audio, file I/O, Lua)   │
├─────────────────────────────────────────────┤
│         AR — Assets Renderer (Lua API)      │
│  Scene graph, node lifecycle, z-ordering    │
├──────────┬──────────┬───────────────────────┤
│  Flags   │  Brain   │  VarTables            │
│  (FL)    │  (BR)    │  (VT)                 │
├──────────┴──────────┴───────────────────────┤
│              Scene Scripts                   │
│   S0.lua, S1000.lua, BUILD_SC.lua, etc.     │
├─────────────────────────────────────────────┤
│          Data Scripts                        │
│  AUTOTEXT, FONTS, CURSORS, FLAGS, BRAIN     │
└─────────────────────────────────────────────┘
```

The engine is a **node-based scene graph** running on Lua 5.1. Every visible element, interactive region, sound effect, timer, and logic gate is an **AR node**. The native C++ core handles low-level rendering, audio decoding, and input — but all game logic lives in Lua.

---

## AR — The Assets Renderer

`AR` is the central singleton exposed to Lua by the native engine. It is **not** defined in any Lua file — it is a C++ object bound into the Lua runtime. Think of it as a factory that creates scene-graph nodes:

```lua
local myOverlay = AR:Overlay({ ... })    -- creates a visual sprite node
local myHotspot = AR:Hotspot({ ... })    -- creates a clickable region
local mySound   = AR:Sound({ ... })      -- creates an audio playback node
```

Every `AR:Something()` call registers a new node in the current scene. The engine iterates all nodes each frame, calling their lifecycle hooks and rendering them according to z-order.

**Key principle:** AR nodes are declarative. You describe *what* they are and *when* they should be active, and the engine handles the rest.

---

## Scenes and Scene Files

A **scene** is the fundamental unit of game state. Each `.lua` file typically represents one scene or a reusable component.

### Scene file structure

Every scene script begins with a **summary**:

```lua
sum = AR:Summary({
  env = "GRA",          -- environment code (location)
  bg  = "GRA_WadeCAL_BG"  -- background image asset name
})
```

After the summary, the file declares AR nodes. The engine loads and processes them top-to-bottom.

### S0 — The Entry Point

`S0.lua` (or equivalently `s0_SC.lua`) is **the very first scene** loaded when the game starts. It handles:

1. Disabling UI overlays (`UIFrame`)
2. Initializing managers (messages, photos, themes)
3. Setting default options from persistent storage
4. Playing the logo sequence (HER Interactive → partner logos → Nancy Drew logo)
5. Fading into the main menu background
6. Transitioning to `TitleMenu_SC`

```lua
-- S0.lua excerpt — entry point
sum = AR:Summary({env = "UI", bg = "toast_BG"})

disableUI = AR:Override({
  Run = function(this)
    this:Send("UIFrame", "Disable")
    this:Send("UIFrame", "Hide")
    this:Done()
  end
})
```

After all logo animations and timers complete, it sets initial flags and brain values, then calls:
```lua
Scene:Change(Scene.streamName, "TitleMenu_SC")
```

### Skip logic

S0 also provides a full-screen `AR:Hotspot` that lets the user click to skip the logos:
```lua
skip_HS = AR:Hotspot({
  onScreen = Viewport.uiSize,
  cursor = "None",
  OnDone = function(this)
    Sound:Stop("FX4")
    Sound:Stop("FX5")
    Sound:Stop("FX6")
  end
})
```

And an override that triggers on skip or subsequent game restarts:
```lua
gotoScene1 = AR:Override({
  active = function(this)
    return skip_HS.done or Game.restarts > 0
  end,
  RunOnce = function(this)
    Initialize:Restart()
  end
})
```

---

## Coordinate System

The engine uses a **pixel-based 2D coordinate system**:

- **Origin (0, 0):** Top-left corner of the screen
- **X axis:** Increases to the right
- **Y axis:** Increases downward
- **Default resolution:** 1024 × 768 pixels

All positions are defined using `Rect` for rectangular areas and `Point` for single coordinates.

```
(0,0) ────────────────────── (1024,0)
  │                              │
  │          Game Area           │
  │                              │
  │    ┌──────────────┐          │
  │    │ source rect  │          │
  │    │ (sprite area │          │
  │    │  in texture) │          │
  │    └──────────────┘          │
  │                              │
(0,768) ──────────────────── (1024,768)
```

The `Viewport` object provides pre-calculated values:
- `Viewport.uiSize` — Full UI area rect (typically the whole 1024×768)
- `Viewport.size.centerV` — Center point for centering elements

---

## Core Primitives

### Rect

`Rect:New(left, top, right, bottom)` defines a rectangle by its **edges**, not by position + size.

```lua
Rect:New(135, 95, 866, 591)
--        │    │    │    │
--        │    │    │    └── bottom edge (y = 591)
--        │    │    └─────── right edge  (x = 866)
--        │    └──────────── top edge    (y = 95)
--        └───────────────── left edge   (x = 135)
-- Width  = 866 - 135 = 731
-- Height = 591 - 95  = 496
```

Methods:
- `Rect:New(l, t, r, b)` — Constructor
- `:CenterSet(point)` — Returns a new Rect centered at the given Point

### Point

`Point:New(x, y)` defines a single 2D coordinate.

```lua
Point:New(13, 11)  -- cursor active point at (13, 11) within the cursor image
```

### Color

`Color:New(alpha, red, green, blue)` — Note: **alpha comes first**, not last.

```lua
Color:New(255, 100, 160, 220)  -- fully opaque, R=100 G=160 B=220
Color:New(160, 0, 0, 0)        -- semi-transparent black (used for dimming)
```

---

## AR Node Types

### AR:Overlay

Displays a **static sprite** (or portion of a sprite sheet) on screen. This is the primary way to show 2D graphics.

```lua
myOverlay = AR:Overlay({
  ovl      = "CEL_TableCart_OVL",           -- asset name of the texture/sprite sheet
  source   = Rect:New(461, 2, 918, 385),   -- region to sample FROM the texture
  onScreen = Rect:New(567, 0, 1024, 383),  -- region to draw TO on screen
  z        = 5,                             -- z-order (higher = rendered on top)
  active   = function(this)                 -- visibility condition
    return someCondition
  end
})
```

**Key concept: source vs. onScreen**

Sprite sheets pack multiple images into one texture. `source` selects which sub-rectangle of the texture to use. `onScreen` controls where it appears on the game screen. The engine scales/stretches the source region to fit the onScreen region.

```
Sprite Sheet (OVL file)          Screen
┌──────────────────────┐         ┌────────────────┐
│  ┌────┐              │         │           ┌────┐
│  │src │              │   ───►  │           │dst │
│  └────┘              │         │           └────┘
│         ┌────┐       │         │                │
│         │    │       │         │                │
│         └────┘       │         └────────────────┘
└──────────────────────┘
```

Properties:
- `ovl` — Texture asset name (string)
- `source` — Source rectangle within the texture
- `onScreen` — Destination rectangle on screen
- `z` — Z-order layer (optional, default varies)
- `active` — Boolean or function returning boolean
- `localAlpha` — Runtime opacity (0.0 to 1.0), often manipulated by Transformers

### AR:Hotspot

Defines a **clickable/interactive screen region**. This is the engine's core input mechanism.

```lua
backNAV = AR:Hotspot({
  scene    = "s2400",                       -- optional: auto-navigate to this scene on click
  frame    = 5,                             -- optional: frame parameter for scene change
  onScreen = Rect:New(0, 620, 1024, 690),  -- clickable region
  cursor   = "Back",                        -- cursor to show when hovering
  tooltip  = "TTIP16",                      -- optional: tooltip autotext key
  OnDone   = function(this)                 -- callback when click interaction completes
    -- custom logic
  end,
  active   = function(this)
    return not sceneLocked
  end
})
```

Hotspot properties:
- `onScreen` — The clickable rectangle
- `cursor` — Cursor name (see [Cursors](#cursors))
- `scene` — If set, clicking navigates to this scene
- `frame` — Scene frame parameter for the navigation
- `tooltip` — Autotext key for hover tooltip
- `OnDone` — Callback after click is processed
- `active` — Activation condition
- `.done` — Boolean property, becomes `true` after the hotspot has been clicked
- `:Reset()` — Resets the hotspot so it can be clicked again
- `:Send(alias, action)` — Sends a message to another node by alias

### AR:Button

A **composite UI element** combining a Hotspot with visual feedback Overlays for hover and pressed states.

```lua
menuMag_Button = AR:Button({
  hs = AR:Hotspot({                         -- the clickable area
    onScreen = Rect:New(0, 669, 42, 755),
    cursor = "MenuHot"
  }),
  overOvl = AR:Overlay({                    -- shown on mouse hover
    ovl = "UI_Frame_OVL",
    source = Rect:New(596, 345, 633, 422),
    onScreen = Rect:New(0, 673, 37, 750)
  }),
  downOvl = AR:Overlay({                    -- shown when mouse button is held
    ovl = "UI_Frame_OVL",
    source = Rect:New(596, 345, 633, 422),
    onScreen = Rect:New(0, 673, 37, 750)
  }),
  OnUp = function(this)                     -- callback on mouse button release
    -- action
  end,
  active = function(this)
    return someCondition
  end
})
```

The `AR:Button` pattern is:
1. `hs` — The underlying Hotspot (defines click region and cursor)
2. `overOvl` — The "hover" state overlay (shown when mouse is over the hotspot)
3. `downOvl` — The "pressed" state overlay (shown while mouse button is held down)
4. `OnUp` — The action that fires when the button is clicked (mouse up)

### AR:Movie

Plays a **video/animation** file. Used for cutscenes, animated backgrounds, and logo sequences.

```lua
hiLogoANIM = AR:Movie({
  movie            = "HER_Logo_ANIM",              -- animation asset name
  source           = Rect:New(-1, -1, -1, -1),     -- (-1,-1,-1,-1) = use full asset size
  onScreen         = Rect:New(0, 0, 1024, 768),    -- fill the screen
  z                = 5,
  pauseOnLastFrame = false,                         -- if true, holds on last frame instead of ending
  active           = function(this)
    return partner2LogoANIM.done                    -- play after the previous movie ends
  end
})
```

Properties:
- `movie` — Asset name of the animation file
- `source` / `onScreen` — Same as Overlay
- `pauseOnLastFrame` — `true` = freeze on last frame; `false` = mark as done and disappear
- `.done` — Becomes `true` when the movie finishes playing
- `.frame` — Current frame number (can be used to trigger other events mid-movie)
- `z` — Z-order

### AR:Sound

Plays **audio**. Supports single sounds, random selection from a list, looping, and channels.

```lua
placeHandlesSFX = AR:Sound({
  sounds  = {"BuildHandlebars_SFX"},   -- asset name(s). Can be a string or array
  channel = "FX1",                     -- audio channel for mixing
  volume  = 0.85,                      -- 0.0 to 1.0
  loop    = false,                     -- optional: loop the sound
  active  = false                      -- initially inactive
})
```

Multiple sounds with random selection:
```lua
nancyHmmVO = AR:Sound({
  sounds = {
    "Hm_1_SFX", "Hm_2_SFX", "Hm_3_SFX",
    "Hm_4_SFX", "Hm_5_SFX", "Hm_6_SFX",
    "Hm_7_SFX", "Hm_8_SFX", "Hm_9_SFX",
    "Hm_10_SFX"
  },
  channel = "PlayerVoice",
  volume  = 0.85,
  active  = false
})
```

Audio channels control mixing. Known channels:
| Channel | Purpose |
|---------|---------|
| `PlayerVoice` | Nancy Drew's voice lines |
| `Theme` | Background music / theme |
| `FX1`, `FX2`, `FX3` | Sound effects (multiple channels for overlapping) |
| `UIFX` | UI interaction sounds |

Methods:
- `:Restart()` — Plays the sound from the beginning (used to trigger inactive sounds)
- Global `Sound:Stop("channel")` — Stops all sounds on a channel

### AR:Timer

A **countdown timer** that becomes `.done` after a specified duration.

```lua
oneSecond = AR:Timer({
  duration = 1,                        -- seconds
  active   = function(this)
    return hiLogoANIM.done             -- starts counting when condition is true
  end,
  OnDone   = function(this)            -- optional callback
    -- triggered when timer expires
  end
})
```

Timers are commonly used to:
- Sequence events (play A, wait 2 seconds, play B)
- Gate content (show menu after 4 seconds)
- Time puzzle mechanics

### AR:Override

The **general-purpose logic node**. Has no visual representation — it exists purely to run code during the scene lifecycle. This is the workhorse for game logic, state changes, and event handling.

```lua
wonLOG = AR:Override({
  RunOnce = function(this)
    Brain.Solved_Build_BR = true
    Scene:Change("s2496")
  end,
  active = function(this)
    return allPartsAdded
  end
})
```

Override also handles **keyboard input** and **rendering**:

```lua
-- Keyboard handling
menuKeyOpener = AR:Override({
  OnKeyDown = function(this, key)
    if key == Key.esc then
      menuMag_Button:OnUp()
      return true      -- consume the key event
    end
  end
})

-- Custom rendering
local grey = AR:Override({
  z = -20,
  Render = function(this)
    this:DrawRect(Viewport.uiSize, Color:New(160, 0, 0, 0))
  end
})

-- Exit handling
quitOvr = AR:Override({
  OnExitRequest = function()
    Scene:BeginStream({ ... })
  end
})
```

### AR:Transformer

Applies **visual transformations** (alpha blending, fading, etc.) to other nodes. You attach a transformer to one or more nodes, then manipulate its properties over time.

```lua
fadeInAnim_TRNS = AR:Transformer({z = 4})
fadeInAnim_TRNS:Attach(superToast_BG)         -- attach to a movie node

-- Set initial state
fadeInAnim_TRNS:PushAlpha("a", 1)             -- parameter name "a", initial value 1.0

-- Animate
fadeInAnim_TRNS:Blend("a", fadeTime1, 0)      -- blend "a" to 0 over fadeTime1 seconds
```

Methods:
- `:Attach(node, ...)` — Attach one or more nodes to this transformer
- `:PushAlpha(paramName, value)` — Set an alpha parameter
- `:Blend(paramName, duration, targetValue)` — Smoothly interpolate to a target value

### AR:Sink

A **full-screen input absorber**. Captures all mouse click events that pass through higher-z nodes. Used in popups and modal dialogs to prevent clicking through to the scene behind.

```lua
local sink = AR:Sink({
  cursor   = "Magglass",
  onScreen = Viewport.uiSize,
  z        = -10
})
```

---

## The `active` Pattern

Almost every AR node supports an `active` property, which is **the single most important pattern** in this scripting system.

- `active = true` (default) — Node is always active
- `active = false` — Node starts inactive (must be manually activated)
- `active = function(this) return condition end` — Node activates/deactivates dynamically

The engine evaluates `active` every frame. When a node becomes active:
- **Overlays** become visible
- **Hotspots** become clickable
- **Sounds** begin playing
- **Timers** start counting
- **Overrides** begin their lifecycle (`RunOnce` → `Run`)
- **Movies** start playing

This creates a powerful **reactive/declarative** system where complex sequences are built by chaining `active` conditions:

```lua
-- Play logo A
logoA = AR:Movie({ movie = "LogoA", ... })

-- Play logo B after A is done
logoB = AR:Movie({
  movie = "LogoB",
  active = function() return logoA.done end
})

-- Wait 2 seconds after B
wait = AR:Timer({
  duration = 2,
  active = function() return logoB.done end
})

-- Show menu after wait
menu = AR:Overlay({
  active = function() return wait.done end
})
```

---

## Lifecycle Callbacks

AR nodes follow a defined lifecycle:

| Callback | When | Called |
|----------|------|--------|
| `RunOnce` | When node first becomes active | Once |
| `Run` | Every frame while active | Every frame |
| `OnDone` | When the node completes its task | Once |
| `Render` | During the render phase | Every frame |
| `OnKeyDown` | When a key is pressed | Per event |
| `Receive` | When a message is received | Per message |
| `OnExitRequest` | When the user tries to quit | Per event |

Completion:
- `:Done()` — Marks the node as complete (triggers `OnDone`, sets `.done = true`)
- `:Restart()` — Resets and re-runs the node
- `:Reset()` — Resets state without re-running

---

## Flags (FL)

Flags are **boolean per-scene state variables**. They are defined in `FLAGS_SC.lua` and accessed via the global `Flags` table.

```lua
-- FLAGS_SC.lua
FlagsInit:Create({
  "CEL_Build_Added_Bolts_FL",
  "CEL_Build_Added_Handlebars_FL",
  "HAL_PackageOpen_FL",
  "Opening_Cine_FL",
  ...
})
```

Usage:
```lua
Flags.HAL_PackageOpen_FL = true              -- set a flag
if Flags.CEL_Build_Added_Wheel1_FL then ...  -- check a flag
```

### Naming convention
```
{ENV}_{Description}_FL
```
- `CEL_Build_Added_Bolts_FL` → Cellar environment, build puzzle, bolts added
- `HAL_DoorSlamStart_FL` → Hallway environment, door slam started
- `UI_SavePromptEnabled_FL` → UI system, save prompt enabled
- `THEME_GhostSpyStart_FL` → Theme music, ghost spy sequence started

Flags are used for **transient, scene-level state** — things like "is a sound currently playing," "has an animation started," or "has the player opened a package." They are saved with the game state.

---

## Brain Variables (BR)

Brain variables are **persistent game-progress booleans**. They track what the player has done, seen, and unlocked across the entire game. Defined in `BRAIN_SC.lua`.

```lua
-- Access
Brain.Met_WT_BR             -- has the player met Wade Thornton?
Brain.Solved_Build_BR       -- has the player solved the build puzzle?
Brain.Got_INV_Necklace_BR   -- has the player picked up the necklace?
```

### Brain entry structure

Each brain entry in `BRAIN_SC.lua` is an array with version history:

```lua
{
  "uuid-string",          -- unique ID
  true,                   -- enabled
  "Got_INV_Oranges_BR",   -- variable name
  "PAR",                  -- environment where it applies
  true,                   -- is a pickup flag
  false,                  -- persistent? 
  nil or function(),      -- condition function
  "Description/formula",  -- human-readable condition
  "date"                  -- timestamp of last edit
}
```

The condition strings use a shorthand notation:
- `+Variable_BR` means `Brain.Variable_BR == true`
- `-Variable_BR` means `Brain.Variable_BR == false`
- Combined with `and`, `or`

Example:
```
+Saw_Clara_Spy_Anim_BR and -Distract_Ready_BR and -Saw_Ghost_Spy_Anim_BR
```

### Common prefixes
| Prefix | Meaning |
|--------|---------|
| `Met_XX_` | Player has met character XX |
| `Got_INV_` | Player has obtained inventory item |
| `Show_INV_` | Inventory item should be visible in the world |
| `Solved_` | Puzzle or task has been completed |
| `XX_Said_` | Character XX has said a particular line |
| `Saw_` | Player has witnessed an event/animation |
| `XX_Available_` | Character XX is available to talk |

---

## Var Tables (VT)

Var Tables store **non-boolean variables** (integers, strings, etc.). Defined in `VARS_SC.lua`.

```lua
VarTableInit:Create({
  "PAR_Tea_AmountLemon_VT",    -- numeric: how much lemon in the tea
  "UI_Cellphone_Games_AggregationScore_VT",  -- numeric: game high score
  "GRA_BackToScene_VT",        -- string: which scene to return to
  "TUN_DigState_VT",           -- numeric: current digging progress
  ...
})
```

VarTables are for values that need more than true/false — puzzle states, scores, return-scene references, and counters.

---

## Autotext System

Autotext is the **text content database**. It maps string keys to displayed dialogue, UI text, and tooltips. Defined in `AUTOTEXT_SC.lua`.

```lua
AutotextInit:Create({
  WT03_SFX = "<c1>I hope Savannah understands the mess she dropped you in.",
  NWT03a_SFX = "<c0>What kind of mess?",
  NWT03b_SFX = "<c0>I can handle myself just fine.",
  ...
})
```

### Key naming convention

```
{Character}{ID}{variant}_{type}
```

- **Character prefix:**
  - `WT` = Wade Thornton (NPC dialogue)
  - `NWT` = Nancy (response to Wade Thornton)
  - `CT` = Clara Thornton
  - `HT` = Harper Thornton
  - `JT` = Jessalyn Thornton
  - `GTH` = Generic game-title voiceover (Nancy Drew monologue)
  - `Wade_` = Wade-specific named lines

- **Suffix `_SFX`:** Indicates this text is synchronized with a voice-acted audio file of the same name

### Inline formatting tags

| Tag | Meaning |
|-----|---------|
| `<c0>` | Set text color to color index 0 (Nancy's color — blue-ish) |
| `<c1>` | Set text color to color index 1 (NPC color — yellow) |
| `<i>` | Begin italic |
| `</i>` | End italic |

Color indices reference the `FontColorsInit:Create()` table in `FONTS_SC.lua`:
```lua
FontColorsInit:Create({
  [0] = Color:New(255, 100, 160, 220),   -- Nancy's text color
  [1] = Color:New(255, 235, 206, 84),    -- NPC text color (yellow)
  [2] = Color:New(255, 216, 63, 81),     -- Red
  [3] = Color:New(255, 255, 255, 255),   -- White
  [4] = Color:New(255, 0, 0, 0),         -- Black
  ...
})
```

---

## Conversation System (MakeConvo)

`MakeConvo` is a **high-level helper function** (not a raw AR node) that creates a complete conversation interaction: NPC greeting, player response choices, and branching outcomes.

```lua
FirstGreet = MakeConvo({
  stages = {"WT03_xs"},              -- conversation stages (autotext exchange scripts)
  responses = {                      -- player response buttons
    NWT03a_SFX = {                   -- key = autotext key for the response
      OnDone = function()
        Scene:Change("s1004")        -- navigate after this response
      end
    },
    NWT03b_SFX = {
      OnDone = function()
        Scene:Change("s1001")
      end
    }
  },
  fidget = WTConvoFidgetA,           -- idle animation for the NPC during convo
  active = function(this)
    return Brain.Met_WT_BR == false   -- only available if player hasn't met Wade yet
  end
})
```

### Full conversation features

```lua
DefaultGreet = MakeConvo({
  stages = table.random({             -- randomly pick one greeting
    "WT00a_xs", "WT00b_xs",
    "WT00c_xs", "WT00d_xs"
  }, 1),
  responseLists = {WTIC},            -- shared response lists (defined in WT_Global_SC)
  byeList = WTBye,                   -- goodbye responses
  fidget = WTConvoFidgetA,           -- NPC fidget animation
  active = function(this)
    return true
  end
})
```

Properties:
- `stages` — Array of stage script names. Each stage is an exchange of lines.
- `responses` — Table of specific response options with callbacks
- `responseLists` — References to shared response-list tables (reusable across conversations)
- `byeList` — The "goodbye" option(s)
- `fidget` — NPC idle animation during the conversation
- `default` — Default action when conversation ends without a specific response
- `active` — When this conversation should be available

### Conversation priority

When multiple `MakeConvo` nodes exist in a scene, the engine uses the **first active one** (top-to-bottom in the script). This creates a priority system:

```lua
-- S1000.lua — Wade Thornton conversation scene
FirstGreet  = MakeConvo({ ... active = Brain.Met_WT_BR == false })   -- highest priority
EVPGreet    = MakeConvo({ ... active = Brain.Met_WT_BR and not Brain.WT_Said_EVP_BR })
BackfastGreet = MakeConvo({ ... active = Brain.WT_Backfast_BR })
DefaultGreet  = MakeConvo({ ... active = true })                     -- fallback
```

### Scene:Include for shared conversation data

```lua
Scene:Include("WT_Global_SC")   -- loads Wade Thornton's shared conversation tables (WTIC, WTBye, etc.)
```

---

## Inventory System

The `Inventory` global manages items the player carries.

```lua
-- Giving an item to the player
Inventory:Add("INV_HANDLES")

-- Taking an item away
Inventory:Remove("INV_HANDLES")

-- Checking what item the player is trying to use
if Inventory.inHand == "INV_HANDLES" then
  -- player is using the handles on something
end

-- Clearing the held item
Inventory.inHand = nil
```

### Inventory + Hotspot pattern

The standard "use inventory item on something" pattern:

```lua
addIngredient = AR:Hotspot({
  onScreen = Rect:New(135, 95, 866, 591),
  cursor = "UseInventory",
  OnDone = function(this)
    if Inventory.inHand == "INV_HANDLES" then
      Inventory:Remove("INV_HANDLES")
      Flags.CEL_Build_Added_Handlebars_FL = true
      placeHandlesSFX:Restart()
      this:Reset()                           -- allow another interaction
    elseif Inventory.inHand == "INV_BOLTS" then
      -- only allow bolts after other parts are placed
      if allOtherPartsAdded then
        Inventory:Remove("INV_BOLTS")
        Flags.CEL_Build_Added_Bolts_FL = true
        placeBoltSFX:Restart()
        this:Reset()
      else
        Inventory.inHand = nil
        nancyHmmVO:Restart()                 -- "hmm" — wrong order
      end
    else
      Inventory.inHand = nil
      nancyHmmVO:Restart()                   -- "hmm" — wrong item
    end
  end
})
```

Inventory item names follow the pattern: `INV_{ITEM_NAME}` (e.g., `INV_HANDLES`, `INV_WHEEL1`, `INV_BOLTS`, `INV_NECKLACE`).

---

## Cursors

Cursors are defined in `CURSORS_SC.lua`. Each cursor is a sprite region from a shared cursor sprite sheet (`UI_Cursors_OVL`).

```lua
CursorInit:Create({
  default   = "MagGlass",     -- default cursor
  rightNode = "RightNode",    -- cursor for right-turning nodes
  leftNode  = "LeftNode",     -- cursor for left-turning nodes
  uturnNode = "UTurn",        -- cursor for U-turn navigation

  MagGlass = {
    ovl      = "UI_Cursors_OVL",
    source   = Rect:New(2, 130, 45, 174),
    activePt = Point:New(13, 11)           -- the "click point" within the cursor image
  },
  ...
})
```

### Cursor types and their purpose

| Cursor | Purpose |
|--------|---------|
| `MagGlass` / `MagGlassHot` | Default examination cursor (look at things) |
| `Manipulate` / `ManipulateHot` | Interact with mechanisms, switches |
| `Inventory` / `InventoryHot` | Pick up an item |
| `UseInventory` / `UseInventoryHot` | Use an inventory item on something |
| `Point` / `PointHot` | Point at / select something |
| `Grab` / `GrabHot` | Grab / drag something |
| `Convo` / `ConvoHot` | Talk to a character |
| `Up` / `Down` / `Left` / `Right` | Directional navigation |
| `Forward` / `ForwardLeft` / `ForwardRight` | Forward navigation variants |
| `Back` / `BackHot` | Go back / step away |
| `LeftCorner` / `RightCorner` | Corner navigation |
| `RotateLeft` / `RotateRight` | Rotate view |
| `LeftNode` / `RightNode` | Navigation node turning |
| `UTurn` | 180-degree turn |
| `Menu` / `MenuHot` | Menu interaction |
| `PuzRightRotate` | Puzzle-specific rotation |
| `None` | Invisible cursor (for skip zones, etc.) |

### Hot variants

Most cursors come in pairs: `CursorName` and `CursorNameHot`. The `Hot` variant is shown when the cursor is **over an active hotspot** (visual feedback that something is clickable). In practice, many games use the same sprite for both.

### activePt

The `activePt` is the pixel within the cursor image that represents the actual click/interaction point. For a magnifying glass cursor, it's the center of the lens. For an arrow, it's the tip.

---

## Fonts and Text Rendering

### Font definitions (FONTS_SC.lua)

```lua
FontsBoot:Init({
  {name = "Arial12",       number = 1,  file = "Arial_12_SC"},
  {name = "Arial18",       number = 2,  file = "Arial_18_SC"},
  {name = "Tahoma14",      number = 13, file = "Tahoma_14_SC"},
  {name = "CourierNew22",  number = 8,  file = "CourierNew_22_SC"},
  {name = "LucidaHand_20", number = 10, file = "LucidaHand_20_SC"},
  ...
})
```

Each font file (e.g., `ARIAL_12_SC.lua`) is a **bitmap font definition**. It specifies:

```lua
FontsInit:Create({
  regular = {
    ovl    = "Arial_12_Regular_OVL",    -- sprite sheet containing all glyphs
    height = 12,                         -- line height in pixels
    [65] = {                             -- ASCII code 65 = 'A'
      x        = 10,                     -- x position in the sprite sheet
      y        = 5,                      -- y position in the sprite sheet
      width    = 6,                      -- glyph width
      height   = 9,                      -- glyph height
      xoffset  = 0,                      -- horizontal offset when drawing
      yoffset  = 0,                      -- vertical offset when drawing
      xadvance = 6                       -- how far to advance the cursor after this glyph
    },
    ...
  },
  bold = { ... },
  italic = { ... },
  boldItalic = { ... }
})
```

Fonts use **BMFont-style bitmap rendering** — each character is a sprite in a texture atlas. The engine does not use system fonts.

---

## Scene Navigation and Streams

### Scene:Change

The primary navigation function. Changes the current scene.

```lua
Scene:Change("s1004")                          -- navigate to scene s1004
Scene:Change(Scene.streamName, "s1099e_SC")    -- change to a named scene in the current stream
```

### Scene:BeginStream / Scene:EndStream

Streams are **layered scene containers**. A stream runs on top of the current scene, typically for UI popups, menus, and overlays.

```lua
-- Open the menu as a stream on top of gameplay
Scene:BeginStream({
  stream       = "MainMenuPopup",     -- stream name
  scene        = "UI_Menu_SC",        -- scene to run in the stream
  captureInput = true,                -- block input from reaching scenes below
  inVP         = false,               -- not in the game viewport
  save         = false                -- don't save this as the current scene
})

-- Close a stream
Scene:EndStream(Scene.streamName)
```

### Scene:Include

Loads a shared script into the current scene context:

```lua
Scene:Include("WT_Global_SC")   -- loads Wade Thornton's shared conversation data
```

### Scene:IsStreamRunning

```lua
if Scene:IsStreamRunning("MainMenuPopup") then
  -- stream is already open
end
```

### Scene properties

- `Scene.streamName` — Name of the current stream
- `Scene.elapsedTime` — Time elapsed since last frame (delta time)

---

## Scene Naming Convention

Scene files follow a strict naming pattern:

### Gameplay scenes (numbered)

```
s{NNNN}.lua
```

- `s0` — Entry point / title screen
- `s1000` — Scene 1000 (Wade Thornton conversation, Graveyard)
- `s1001` — Scene 1001 (continuation of Wade conversation)
- `s1038` — Scene 1038 (Wade reaction scene)
- `s2400` — Scene 2400 (Cellar area)
- `s2496` — Scene 2496 (Cellar after puzzle solved)

The numbering groups scenes by **environment/area**:
- Scenes in the **1000s** → GRA (Graveyard) area
- Scenes in the **2000s** → CEL (Cellar) area / underground
- Scenes in the **3000s** → YAR (Yard) area

### Named scenes

```
{FUNCTION}_SC.lua
```

- `BUILD_SC.lua` — Cart build puzzle
- `TitleMenu_SC.lua` — Title menu
- `UI_Menu_SC.lua` — In-game menu popup
- `UI_Extras_SC.lua` — Extras menu (awards, credits, outtakes)
- `UI_Frame_SC.lua` — Persistent HUD frame
- `WT_Global_SC.lua` — Wade Thornton shared conversation data
- `Credits_SC.lua` — Credits scroll
- `Outtakes_SC.lua` — Outtakes video

### Data/config scripts

```
{TYPE}_SC.lua
```

- `FLAGS_SC.lua` — Flag definitions
- `BRAIN_SC.lua` — Brain variable definitions
- `VARS_SC.lua` — VarTable definitions
- `AUTOTEXT_SC.lua` — Text/dialogue content
- `FONTS_SC.lua` — Font registry
- `CURSORS_SC.lua` — Cursor definitions

---

## Environment Codes

The `env` field in `AR:Summary` identifies the game location/area:

| Code | Location |
|------|----------|
| `UI` | User interface (menus, title screen) |
| `GRA` | Graveyard |
| `CEL` | Cellar |
| `HAL` | Hallway |
| `PAR` | Parlor |
| `BED` | Bedroom |
| `DEC` | Deck |
| `TUN` | Tunnels |
| `YAR` | Yard |
| `RUI` | Ruins |
| `SHO` | Shoring / basement |
| `CRY` | Crypt |
| `GAR` | Garden |

Environment codes are used as prefixes in flag names, VarTable names, and asset names to organize resources by area.

---

## Game API

The `Game` global provides engine-level functionality:

```lua
-- Properties
Game.buildNumber           -- build version number
Game.cheatMode             -- whether cheats are enabled
Game.environment           -- current environment string
Game.isWindowed            -- whether running in windowed mode
Game.time                  -- elapsed game time
Game.needsSave             -- whether unsaved changes exist
Game.restarts              -- number of times the game has restarted (>0 means skip logos)

-- Methods
Game:Exit()                -- quit the game
Game:New()                 -- start a new game
Game:Save({name = "save1", useAutotext = true, isContinue = false})
Game:Load({name = "save1", useAutotext = true})
Game:AllSaves()            -- returns list of all save files
Game:SaveExists("name")   -- check if a save exists
Game:SetWindowed(true)     -- toggle windowed mode
Game:ShowLink("ref")       -- display a linked autotext entry
Game:GetScriptNameRange(lower, upper)   -- get scene script names in a range
Game:SetScriptNameFilter("filter")      -- filter script names
Game:IsContinue(...)       -- check if a save is a continue save
```

---

## Persistence: Save/Load/Attic

### Save/Load

```lua
Save:Attic("fastConvo", true)        -- persist a value to the "attic" (global storage)
local val = Load:Attic("fastConvo")  -- retrieve a persisted value
Load:Attic("BeatGame")              -- returns "WonNotMeta", "WonAllMeta", or nil
```

The **Attic** is a persistent key-value store that survives across game sessions. It's used for:
- Options (fast convo mode)
- Completion tracking (whether the game has been beaten)
- Unlockable content gating

---

## Helper Functions and Utilities

### MakeVideoFader

Creates a screen fade transition:

```lua
arriveFADE = MakeVideoFader({
  fade     = "in",          -- "in" or "out"
  duration = 1,             -- seconds
  RunOnce  = function(this)
    locked = true
  end,
  OnDone   = function(this)
    locked = false
  end,
  active   = function(this)
    return Flags.GAR_StartFade_FL
  end,
  z = 8
})
```

### table.random

Selects random elements from a table:

```lua
table.random({"WT00a_xs", "WT00b_xs", "WT00c_xs", "WT00d_xs"}, 1)
-- returns 1 random element from the array
```

### math.sinlerp2

Sinusoidal interpolation (smooth easing):

```lua
math.sinlerp2(fromValue, toValue, t)  -- t is 0.0 to 1.0
```

Used for smooth oscillating animations (e.g., button flash effects).

### Stringify

Converts a value to a printable string (used in error messages):

```lua
error(string.format("Could not register expected alias %s", Stringify(value)))
```

---

## Messaging and Aliases

Nodes can communicate via a **message-passing system**. A node registers an alias, then other nodes can send messages to it.

### Register an alias

```lua
menuFlashAnim = AR:Override({
  alias = "MenuButton",
  Receive = function(this, sender, action)
    if action == "Flash" then
      this:Restart()
    end
  end,
  ...
})

if not menuFlashAnim:RegisterAlias(menuFlashAnim.alias) then
  error("Could not register alias")
end
```

### Send a message

```lua
this:Send("UIFrame", "Disable")      -- send "Disable" action to node aliased "UIFrame"
this:Send("UIFrame", "Hide")
this:Send("MenuButton", "Flash")     -- trigger the menu button flash animation
this:Send("MessageManager", "CreateStore", "messages")
```

This decouples senders from receivers — a scene script can control the HUD frame without directly referencing its nodes.

---

## Complete Scene Example Walkthrough

Here's `BUILD_SC.lua` fully annotated — a puzzle where the player assembles a cart from parts:

```lua
-- 1. Scene Summary
sum = AR:Summary({
  env = "CEL",              -- Cellar
  bg = "CEL_TableCart_BG"   -- Background image: a table with cart parts
})

-- 2. Scene-local state
local sceneLocked = false    -- prevents interaction during animations/voiceovers

-- 3. Navigation: "Back" arrow at the bottom of the screen
backNAV = AR:Hotspot({
  scene = "s2400",                        -- navigate to cellar overview
  onScreen = Rect:New(0, 620, 1024, 690), -- bottom strip of the screen
  cursor = "Back",
  OnDone = function(this)
    -- When leaving, return parts to inventory
    if Flags.CEL_Build_Added_Handlebars_FL then
      Inventory:Add("INV_HANDLES")
    end
    -- ... etc.
  end,
  active = function(this)
    return not sceneLocked                 -- can't leave during VO playback
  end
})

-- 4. Main interaction hotspot: use inventory items on the cart
addIngredient = AR:Hotspot({
  onScreen = Rect:New(135, 95, 866, 591), -- the cart work area
  cursor = "UseInventory",
  OnDone = function(this)
    -- Branch on which item the player is holding
    if Inventory.inHand == "INV_HANDLES" then
      Inventory:Remove("INV_HANDLES")
      Flags.CEL_Build_Added_Handlebars_FL = true
      placeHandlesSFX:Restart()
      this:Reset()
    -- ... more branches for wheels, bolts
    end
  end,
  active = function(this) return not sceneLocked end
})

-- 5. Win condition: all parts added → mark solved, change scene
wonLOG = AR:Override({
  RunOnce = function(this)
    Brain.Solved_Build_BR = true
    Scene:Change("s2496")
  end,
  active = function(this)
    return Flags.CEL_Build_Added_Handlebars_FL
       and Flags.CEL_Build_Added_Wheel1_FL
       and Flags.CEL_Build_Added_Wheel2_FL
       and Flags.CEL_Build_Added_Bolts_FL
  end
})

-- 6. Visual overlays: show parts on the cart in their correct state
-- Each state (with/without bolts) has its own overlay
handleWithoutBoltsOVL = AR:Overlay({
  ovl = "CEL_TableCart_OVL",
  source = Rect:New(461, 2, 918, 385),    -- un-bolted handle sprite
  onScreen = Rect:New(567, 0, 1024, 383),
  active = function(this)
    return Flags.CEL_Build_Added_Handlebars_FL
       and not Flags.CEL_Build_Added_Bolts_FL
  end
})

-- 7. Sound effects - initially inactive, triggered by :Restart()
placeHandlesSFX = AR:Sound({
  sounds = {"BuildHandlebars_SFX"},
  channel = "FX1",
  volume = 0.85,
  active = false
})

-- 8. Initial Nancy voiceover: plays once when puzzle is first seen
BuildNDVO = AR:Sound({
  sounds = {"GTH071_sfx"},
  channel = "PlayerVoice",
  volume = 0.85,
  RunOnce = function(this)
    sceneLocked = true              -- lock interaction during VO
  end,
  OnDone = function(this)
    sceneLocked = false
    Brain.Tried_Build_BR = true     -- mark that player has seen the puzzle
  end,
  active = function(this)
    return not Brain.Tried_Build_BR
  end
})
```

This demonstrates how scenes combine all node types into a cohesive interactive experience: visuals (Overlay), input (Hotspot), logic (Override), audio (Sound), and state (Flags + Brain).

---

## Summary of Globals

| Global | Purpose |
|--------|---------|
| `AR` | Assets Renderer — factory for all scene nodes |
| `Flags` | Boolean per-scene state variables (FL) |
| `Brain` | Persistent game-progress booleans (BR) |
| `Inventory` | Player inventory management |
| `Scene` | Scene navigation and management |
| `Game` | Engine-level game functions |
| `Sound` | Global sound control |
| `Viewport` | Screen dimensions and helpers |
| `Save` / `Load` | Persistence (Attic, save files) |
| `Key` | Keyboard key constants (`.esc`, `.escape`, etc.) |
| `ThemeManager` | Background music management |
| `PhotoManager` | In-game camera/photo feature |
| `Initialize` | Game initialization control |

---

*This guide was reverse-engineered from decompiled Lua scripts of HER Interactive's game engine. Names, patterns, and behaviors are inferred from code analysis.*
