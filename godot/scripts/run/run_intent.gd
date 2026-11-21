class_name RunIntent
extends RefCounted
## Intents: what the player wants, independent of the gesture that produced it (InputProfile maps mouse,
## keys and taps to these). The rules layer (RunState.apply) only ever sees intents.

const OPEN_MAP := "open_map"
const CLOSE_MAP := "close_map"
const LEAVE_CREW_CONFIRM := "leave_crew_confirm"  # {1 yes / 0 no}: "crew still aboard the enemy ship" window
const SELECT_BEACON := "select_beacon"  # {id}: potential target (hover on PC, tap on touch); -1 clears
const CONFIRM_JUMP := "confirm_jump"  # jump to the selected beacon
const NEXT_SECTOR := "next_sector"  # at the exit beacon: open the sector map (choice mode)
const SELECT_SECTOR := "select_sector"  # {id}: a neighbouring sector (hover on PC, tap on touch)
const CONFIRM_SECTOR := "confirm_sector"  # go to the selected sector
const CLOSE_SECTOR_MAP := "close_sector_map"
const HIGHLIGHT_CHOICE := "highlight_choice"  # {index}: touch first tap / PC hover (visual only)
const CHOOSE := "choose"  # {index}: apply an event choice
const CONTINUE := "continue"  # dismiss a message box
const WAIT := "wait"  # out of fuel: wait one turn (the fleet advances)
const TOGGLE_DISTRESS := "toggle_distress"  # out of fuel: distress beacon on / off
const OPEN_STORE := "open_store"  # STORE button at a store beacon
const CLOSE_STORE := "close_store"
const STORE_SELECT := "store_select"  # {box code}: selected box (touch: shows info, enables BUY)
const STORE_BUY := "store_buy"  # {box code}: buy (PC click / touch BUY or second tap)
const STORE_CONFIRM := "store_confirm"  # {1 yes / 0 no}: system purchase confirmation
const STORE_PAGE := "store_page"  # {0 / 1}
const STORE_TAB := "store_tab"  # {0 buy / 1 sell}
const STORE_SELL := "store_sell"  # {index into RunStore.sellable}
# Ship management (rules/ship_management.md, ShipManagement.apply; extra keys via ShipManagement.make)
const OPEN_SHIP_SCREEN := "open_ship_screen"  # {tab 0 upgrades / 1 crew / 2 equipment}
const SET_TAB := "set_ship_tab"  # {tab}
const CLOSE_SHIP_SCREEN := "close_ship_screen"  # Accept / Esc (commits the upgrades)
const UPGRADE_BUY := "upgrade_buy"  # sys: system id or "reactor"
const UPGRADE_REFUND := "upgrade_refund"  # sys
const UPGRADE_UNDO := "upgrade_undo"
const EQUIP_MOVE := "equip_move"  # src, dst: ShipInventory box refs (Vector2i)
const EQUIP_SELL := "equip_sell"  # src: box ref (store SELL tab)
const CREW_RENAME := "crew_rename"  # crew, text
const CREW_DISMISS := "crew_dismiss"  # crew: opens the confirmation
const CREW_DISMISS_CONFIRM := "crew_dismiss_confirm"  # {1 yes / 0 no}


static func make(type: String, arg := -1) -> Dictionary:
	return {"type": type, "arg": arg}
